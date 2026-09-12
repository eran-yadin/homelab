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
    # A per-host override, written by the app's download.sh when it finds
    # hardware or conditions the base file cannot express. Compose has no way
    # to make a `devices:` entry conditional, and a missing device is a hard
    # start failure, so it has to be decided at install time.
    if [ -f "$APP_STATE/compose.override.yml" ]; then
        DC_ARGS+=(-f "$APP_STATE/compose.override.yml")
    fi
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

# Services that do one job and exit (fixing volume ownership, running a
# migration). They are declared in app.conf as oneshot="name ..." and are
# excluded from the counts, because a completed init exiting 0 is success --
# counting it would leave every such app permanently "degraded".
_is_oneshot() {
    local svc="$1" o
    for o in ${APP_ONESHOT:-}; do [ "$o" = "$svc" ] && return 0; done
    return 1
}

# service|state|status, one line per container, one-shots removed
_containers() {
    if [ "${#DK[@]}" -eq 0 ]; then return 0; fi
    "${DK[@]}" ps -a --filter "label=com.docker.compose.project=$APP_NAME" \
        --format '{{.Label "com.docker.compose.service"}}|{{.State}}|{{.Status}}' \
        2>/dev/null | while IFS='|' read -r svc rest; do
            _is_oneshot "$svc" || printf '%s|%s\n' "$svc" "$rest"
        done
}

_service_count() {
    local n=0 svc
    while read -r svc; do
        [ -n "$svc" ] || continue
        _is_oneshot "$svc" || n=$((n+1))
    done < <(dc_ro config --services 2>/dev/null)
    printf '%s' "$n"
}
_running_count() { _containers | awk -F'|' '$2=="running"' | grep -c . || true; }
_has_build()     { grep -qE '^[[:space:]]+build:' "$COMPOSE_FILE"; }

# A volume declared in app.conf as bulk_volumes="name ..." holds media that no
# migration rewrites -- Immich's photo library, say. The pre-update backup
# skips those: they are what makes a backup slow and big, and the update does
# not touch them. `homelab backup` still archives everything.
_is_bulk() {
    local b
    for b in ${APP_BULK_VOLUMES:-}; do [ "$b" = "$1" ] && return 0; done
    return 1
}

_do_backup() {  # _do_backup <dest> <skip-bulk 0|1>
    local dest="$1" skip="${2:-0}" vols v short
    run mkdir -p "$dest"
    vols="$("${DK[@]}" volume ls -q 2>/dev/null | grep "^${APP_NAME}_" || true)"
    [ -n "$vols" ] || warn "$APP_NAME: no volumes found to back up"
    for v in $vols; do
        short="${v#"${APP_NAME}"_}"
        if [ "$skip" = 1 ] && _is_bulk "$short"; then
            log "$APP_NAME: skipping $v (bulk media, not touched by an update)"
            continue
        fi
        log "$APP_NAME: archiving volume $v"
        run_sh "${DK[*]} run --rm -v '$v':/src:ro -v '$dest':/out alpine tar -czf '/out/vol-$v.tar.gz' -C /src ."
    done
    if [ -f "$APP_STATE/.env" ]; then
        run_sh "cp '$APP_STATE/.env' '$dest/env'"
        warn "$dest/env contains this install's secrets - keep it as private as the data"
    fi
}

# The image a service will run after `up -d`, from the compose config, so a
# changed tag in the compose file (v3.2.0 -> release) is seen as a change too.
_service_images() {  # "service|image-ref" per line
    if have python3; then
        dc_ro config --format json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for name, svc in (d.get("services") or {}).items():
    if svc.get("image"):
        print("%s|%s" % (name, svc["image"]))' 2>/dev/null || true
    else
        # no python: fall back to the reference each container was created from
        "${DK[@]}" ps -a --filter "label=com.docker.compose.project=$APP_NAME" \
            --format '{{.Label "com.docker.compose.service"}}|{{.Image}}' 2>/dev/null || true
    fi
}

_img_ver() {  # a human version for an image id: its OCI version label, else the short id
    local v
    v="$("${DK[@]}" image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null || true)"
    if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "${1#sha256:}" | cut -c1-12; fi
}

# "service|old-version|new-version" for every running service whose image
# would change on `up -d`. Empty means the update would recreate nothing.
_image_changes() {
    local svc ref cid old new
    _service_images | while IFS='|' read -r svc ref; do
        ref="${ref%$'\r'}"      # python on Windows ends lines with CRLF
        [ -n "$svc" ] || continue
        _is_oneshot "$svc" && continue
        cid="$("${DK[@]}" ps -a --filter "label=com.docker.compose.project=$APP_NAME" \
               --filter "label=com.docker.compose.service=$svc" -q 2>/dev/null | head -1)"
        [ -n "$cid" ] || continue
        old="$("${DK[@]}" inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
        new="$("${DK[@]}" image inspect -f '{{.Id}}' "$ref" 2>/dev/null || true)"
        [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ] || continue
        printf '%s|%s|%s\n' "$svc" "$(_img_ver "$old")" "$(_img_ver "$new")"
    done
}

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
    preflight_conflicts
    # A container_name in the compose file is a global namespace. If a
    # container by that name already exists and is not ours -- the classic
    # case being a `docker run` container predating this catalog -- compose
    # would fail with "name is already in use", or worse, we would adopt
    # something we did not create.
    for cn in $(sed -n 's/^[[:space:]]*container_name:[[:space:]]*//p' "$COMPOSE_FILE"); do
        if "${DK[@]}" inspect "$cn" >/dev/null 2>&1; then
            owner="$("${DK[@]}" inspect "$cn" \
                --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
            if [ "$owner" != "$APP_NAME" ]; then
                err "a container named '$cn' already exists on this host and was not"
                err "    created by homelab${owner:+ (it belongs to compose project '$owner')}."
                err "    Starting $APP_NAME would clash with it. Inspect it first:"
                err "        docker inspect $cn"
                exit 1
            fi
        fi
    done
    # Containers can already exist under this project name without having been
    # created from THIS compose file -- nucserver runs paperless as project
    # "paperless" from its own docker-compose.yml. Recreating those from our
    # file would hand a running database a freshly generated password and a
    # different volume layout. Compose records the file it was created from;
    # compare it.
    existing_cfg="$("${DK[@]}" ps -a --filter "label=com.docker.compose.project=$APP_NAME" \
        --format '{{.Label "com.docker.compose.project.config_files"}}' 2>/dev/null | head -1)"
    if [ -n "$existing_cfg" ] && [ "$existing_cfg" != "$COMPOSE_FILE" ]; then
        err "$APP_NAME already has containers on this host, but they were created"
        err "    from a different compose file:"
        err "        theirs: $existing_cfg"
        err "        ours:   $COMPOSE_FILE"
        err "    Starting would recreate them from ours -- new environment, new"
        err "    generated secrets, possibly different volumes. Refusing."
        err ""
        err "    To take it over deliberately, back it up first, then:"
        err "        homelab backup $APP_NAME <dir> --apply"
        err "        docker compose -f $existing_cfg down"
        err "        homelab restore $APP_NAME <dir> --apply && homelab start $APP_NAME --apply"
        exit 1
    fi
    preflight_ports ${APP_PORTS:-}
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
    ensure_state_dir
    if ! is_apply; then
        log "$APP_NAME: would pull newer images, show what changes, then recreate"
        if [ "$APP_STATEFUL" = 1 ]; then
            log "$APP_NAME: holds data, so it would back up its volumes first${APP_BULK_VOLUMES:+ (skipping bulk: $APP_BULK_VOLUMES)} and ask"
        fi
        dc pull --quiet
        exit 0
    fi
    log "$APP_NAME: pulling newer images"
    if ! dc pull --quiet; then
        warn "$APP_NAME: pull reported errors (expected for build-only services)"
    fi
    if _has_build; then dc build --pull; fi
    if [ "$(_running_count)" -eq 0 ]; then
        ok "$APP_NAME: images updated (app is stopped, leaving it stopped)"
        exit 0
    fi

    # Pulling changed nothing that runs. Before recreating, say what the
    # jump is -- and for an app that holds data, back up and ask. Floating
    # tags (latest, stable, release) are the default in this catalog, so a
    # routine update can be a major version; this is where that gets seen.
    changes="$(_image_changes)"
    if [ -z "$changes" ]; then
        ok "$APP_NAME: already on the newest images"
        exit $EX_NOOP
    fi
    log "$APP_NAME: this update changes:"
    printf '%s\n' "$changes" | while IFS='|' read -r svc o n; do
        printf '     %-28s %s  ->  %s\n' "$svc" "$o" "$n" >&2
    done

    if [ "$APP_STATEFUL" = 1 ]; then
        if [ "${HOMELAB_YES:-0}" != 1 ]; then
            if { exec 3</dev/tty; } 2>/dev/null; then
                printf '%s holds data. Back it up and update? [y/N] ' "$APP_NAME" >&2
                IFS= read -r yn <&3 || true; exec 3<&-
                case "$yn" in [yY]*) ;; *) log "$APP_NAME: cancelled, nothing changed (the pulled images stay cached)"; exit $EX_CONFIRM ;; esac
            else
                err "$APP_NAME holds data. The update would back it up, then recreate it on the"
                err "    new version. Nothing has changed yet. Confirm with:"
                err "        homelab update $APP_NAME --apply --yes"
                exit $EX_CONFIRM
            fi
        fi
        bk="$HOMELAB_DATA/backups/$APP_NAME/pre-update-$(date +%Y%m%d-%H%M%S)"
        log "$APP_NAME: backing up before the update -> $bk"
        _do_backup "$bk" 1
        run $SUDO chmod 0700 "$bk"
        ok "$APP_NAME: backup done. If the new version misbehaves:"
        ok "    homelab stop $APP_NAME --apply && homelab restore $APP_NAME $bk --apply && homelab start $APP_NAME --apply"
    fi
    log "$APP_NAME: recreating containers"
    dc up -d
    ok "$APP_NAME: updated"
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
    running="$(printf '%s\n' "$lines" | awk -F'|' '$2=="running"' | grep -c . || true)"
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

    # Distroless images have no shell, so docker's own healthcheck cannot run
    # in them at all -- it fails with "stat /bin/sh: no such file". When an app
    # declares health_url, probe the published port from the host instead.
    if [ "$health" = none ] && [ -n "${APP_HEALTH_URL:-}" ] && [ "$state" = running ]; then
        if have curl && curl -fsS -o /dev/null --max-time 3 "$APP_HEALTH_URL" 2>/dev/null; then
            health=healthy
        else
            health=unhealthy
        fi
    fi
    emit_status "$state" true \
        containers="$running/$total" health="$health" ports="${APP_PORTS:-}"
    ;;

backup)
    need_docker
    dest="${1:-}"; [ -n "$dest" ] || die "backup needs a destination directory"
    ensure_state_dir
    _do_backup "$dest" 0
    ok "$APP_NAME: backed up to $dest"
    ;;

restore)
    need_docker
    src="${1:-}"; [ -n "$src" ] || die "restore needs a source directory"
    [ -d "$src" ] || die "no such directory: $src"
    # Restoring underneath a running app is destructive in a way that is hard
    # to see: postgres has already initialised a fresh cluster in the volume
    # and holds it open, so the archive lands on top of live files. The right
    # order is download -> restore -> start, and the engine should enforce it
    # rather than document it.
    if [ "$(_running_count)" -gt 0 ]; then
        err "$APP_NAME is running. Restoring into live volumes would corrupt them."
        err "    Stop it first:   homelab stop $APP_NAME --apply"
        err "    Then:            homelab restore $APP_NAME $src --apply"
        err "    On a new machine the order is: download, restore, start."
        exit 1
    fi
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
