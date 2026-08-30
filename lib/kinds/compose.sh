#!/usr/bin/env bash
# Default lifecycle for kind="compose".
#
# An app that uses this ships only:  app.conf  files/compose.yml
# and optionally                     files/env.template
#
# Data lives in named docker volumes (project-scoped), which is what makes
# backup/restore and delete --purge uniform across every compose app.

set -euo pipefail

# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"

VERB="${1:-}"; [ -n "$VERB" ] || die "compose kind: verb required"
shift || true

COMPOSE_FILE="$APP_FILES/compose.yml"
[ -f "$COMPOSE_FILE" ] || die "$APP_NAME: missing $COMPOSE_FILE"

_dc_args() {
    DC_ARGS=("${DK[@]}" compose -p "$APP_NAME"
             --project-directory "$APP_FILES"
             -f "$COMPOSE_FILE")
    if [ -f "$APP_STATE/.env" ]; then DC_ARGS+=(--env-file "$APP_STATE/.env"); fi
}

dc()    { _dc_args; run "${DC_ARGS[@]}" "$@"; }
# read-only variant: must also work in dry-run, so it bypasses the gate
dc_ro() { _dc_args; "${DC_ARGS[@]}" "$@" 2>/dev/null; }

need_docker() {
    if dk_resolve; then return 0; fi
    # In a dry run the dependency has not actually been installed yet, so a
    # hard failure here would make it impossible to preview a full install
    # chain. Warn and keep going: every real change is gated anyway.
    if ! is_apply; then
        warn "$APP_NAME: docker is not present yet (a real run installs it first)"
        return 0
    fi
    die "$APP_NAME needs docker: $(dk_reason)"
}

_containers() {
    if [ "${#DK[@]}" -eq 0 ]; then return 0; fi
    "${DK[@]}" ps -a --filter "label=com.docker.compose.project=$APP_NAME" \
        --format '{{.State}}|{{.Status}}' 2>/dev/null || true
}

_service_count() { dc_ro config --services 2>/dev/null | grep -c . || echo 0; }
_running_count() { _containers | grep -c '^running|' || true; }
_has_build()     { grep -qE '^[[:space:]]+build:' "$COMPOSE_FILE"; }

case "$VERB" in

download)
    need_docker
    ensure_state_dir
    render_env
    log "$APP_NAME: pulling images"
    # A build-only service has no image to pull, so a non-zero here is normal.
    if ! dc pull --quiet; then
        warn "$APP_NAME: pull reported errors (expected for build-only services)"
    fi
    if _has_build; then
        log "$APP_NAME: building local image"
        dc build
    fi
    ok "$APP_NAME: images ready"
    ;;

start)
    need_docker
    ensure_state_dir
    render_env
    total="$(_service_count)"
    running="$(_running_count)"
    if [ "$running" -gt 0 ] && [ "$running" = "$total" ]; then
        ok "$APP_NAME: already running ($running/$total)"
        exit $EX_NOOP
    fi
    log "$APP_NAME: starting"
    dc up -d
    ok "$APP_NAME: started"
    ;;

stop)
    need_docker
    if [ "$(_running_count)" -eq 0 ]; then
        ok "$APP_NAME: already stopped"
        exit $EX_NOOP
    fi
    log "$APP_NAME: stopping"
    # `stop`, not `down`: down REMOVES the containers, so a merely-stopped app
    # then reports as absent. Tearing down is what `delete` is for.
    dc stop
    ok "$APP_NAME: stopped"
    ;;

update)
    need_docker
    log "$APP_NAME: pulling newer images"
    if ! dc pull; then
        warn "$APP_NAME: pull reported errors (expected for build-only services)"
    fi
    if _has_build; then dc build --pull; fi
    if [ "$(_running_count)" -gt 0 ]; then
        log "$APP_NAME: recreating containers"
        dc up -d
        ok "$APP_NAME: updated"
    else
        ok "$APP_NAME: images updated (app is stopped, leaving it stopped)"
    fi
    ;;

delete)
    need_docker
    purge=0
    if [ "${1:-}" = "--purge" ]; then purge=1; fi
    if [ -z "$(_containers)" ] && [ "$purge" -eq 0 ]; then
        ok "$APP_NAME: nothing to delete"
        exit $EX_NOOP
    fi
    if [ "$purge" -eq 1 ]; then
        warn "$APP_NAME: --purge will DESTROY its data volumes"
        dc down --volumes --remove-orphans
        if [ -d "$APP_STATE" ]; then run $SUDO rm -rf "$APP_STATE"; fi
        ok "$APP_NAME: removed, data destroyed"
    else
        dc down --remove-orphans
        ok "$APP_NAME: removed (data volumes kept; --purge to destroy them)"
    fi
    ;;

status)
    if ! dk_resolve; then
        emit_status absent false detail="$(dk_reason)"
        exit 0
    fi
    total="$(_service_count)"
    lines="$(_containers)"
    if [ -z "$lines" ]; then
        # `compose images` only lists images belonging to EXISTING containers,
        # so after a `down` it is empty even though every image is still
        # present locally. Ask the daemon about the images themselves.
        have_img=0
        for i in $(dc_ro config --images 2>/dev/null || true); do
            if "${DK[@]}" image inspect "$i" >/dev/null 2>&1; then have_img=1; break; fi
        done
        if [ "$have_img" = 1 ]; then
            emit_status downloaded false containers="0/$total"
        else
            emit_status absent false containers="0/$total"
        fi
        exit 0
    fi
    running="$(printf '%s\n' "$lines" | grep -c '^running|' || true)"
    unhealthy="$(printf '%s\n' "$lines" | grep -c 'unhealthy' || true)"
    healthy="$(printf '%s\n' "$lines" | grep -c '(healthy)' || true)"
    starting="$(printf '%s\n' "$lines" | grep -c 'health: starting' || true)"
    if   [ "$unhealthy" -gt 0 ];      then state=degraded
    elif [ "$running" -eq 0 ];        then state=stopped
    elif [ "$running" -eq "$total" ]; then state=running
    else                                   state=degraded
    fi
    health=none
    if [ "$starting"  -gt 0 ]; then health=starting; fi
    if [ "$healthy"   -gt 0 ]; then health=healthy;  fi
    if [ "$unhealthy" -gt 0 ]; then health=unhealthy; fi
    emit_status "$state" true \
        containers="$running/$total" health="$health" ports="${APP_PORTS:-}"
    ;;

backup)
    need_docker
    dest="${1:-}"; [ -n "$dest" ] || die "backup needs a destination directory"
    ensure_state_dir
    run mkdir -p "$dest"
    vols="$("${DK[@]}" volume ls -q 2>/dev/null | grep "^${APP_NAME}_" || true)"
    [ -n "$vols" ] || warn "$APP_NAME: no volumes found to back up"
    for v in $vols; do
        log "$APP_NAME: archiving volume $v"
        run_sh "${DK[*]} run --rm -v '$v':/src:ro -v '$dest':/out alpine tar -czf '/out/vol-$v.tar.gz' -C /src ."
    done
    if [ -f "$APP_STATE/.env" ]; then
        run_sh "cp '$APP_STATE/.env' '$dest/env'"
        warn "$dest/env contains this install's secrets - keep it as private as the data"
    fi
    ok "$APP_NAME: backed up to $dest"
    ;;

restore)
    need_docker
    src="${1:-}"; [ -n "$src" ] || die "restore needs a source directory"
    [ -d "$src" ] || die "no such directory: $src"
    found=0
    for f in "$src"/vol-*.tar.gz; do
        [ -f "$f" ] || continue
        found=1
        v="$(basename "$f" .tar.gz)"; v="${v#vol-}"
        log "$APP_NAME: restoring volume $v"
        run "${DK[@]}" volume create "$v"
        run_sh "${DK[*]} run --rm -v '$v':/dst -v '$src':/in alpine tar -xzf '/in/$(basename "$f")' -C /dst"
    done
    [ "$found" = 1 ] || die "no vol-*.tar.gz archives in $src"
    if [ -f "$src/env" ]; then
        ensure_state_dir
        run_sh "cp '$src/env' '$APP_STATE/.env'"
    fi
    ok "$APP_NAME: restored from $src"
    ;;

*)
    die "compose kind: unknown verb '$VERB'"
    ;;
esac
