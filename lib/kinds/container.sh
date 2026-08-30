#!/usr/bin/env bash
# Default lifecycle for kind="container".
#
# For a plain `docker run` container that already exists on the host and was
# not created from a compose file. This is the adopt path: it lets the hub see
# and control something predating this catalog, without pretending homelab
# installed it.
#
# app.conf declares:  container="name"  and usually adopted=1

set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"

VERB="${1:-}"; [ -n "$VERB" ] || die "container kind: verb required"
shift || true

CNAME="${APP_CONTAINER:-$APP_NAME}"

need_docker() {
    if dk_resolve; then return 0; fi
    if ! is_apply; then
        warn "$APP_NAME: docker is not present yet"
        return 0
    fi
    die "$APP_NAME needs docker: $(dk_reason)"
}

exists()  { [ "${#DK[@]}" -gt 0 ] && "${DK[@]}" inspect "$CNAME" >/dev/null 2>&1; }
running() { [ "$("${DK[@]}" inspect -f '{{.State.Running}}' "$CNAME" 2>/dev/null)" = true ]; }

case "$VERB" in

download)
    need_docker
    if [ "${APP_ADOPTED:-0}" = 1 ]; then
        if exists; then
            ok "$APP_NAME: adopting the existing container '$CNAME'"
            exit $EX_NOOP
        fi
        die "$APP_NAME is an adopt-only entry, but no container named '$CNAME' exists here"
    fi
    die "$APP_NAME: kind=container has no generic download; supply download.sh"
    ;;

start)
    need_docker
    exists || die "$APP_NAME: no container named '$CNAME' on this host"
    if running; then ok "$APP_NAME: already running"; exit $EX_NOOP; fi
    preflight_conflicts
    preflight_ports ${APP_PORTS:-}
    log "$APP_NAME: starting container '$CNAME'"
    run "${DK[@]}" start "$CNAME"
    ok "$APP_NAME: started"
    ;;

stop)
    need_docker
    exists || { ok "$APP_NAME: not present"; exit $EX_NOOP; }
    running || { ok "$APP_NAME: already stopped"; exit $EX_NOOP; }
    log "$APP_NAME: stopping '$CNAME'"
    run "${DK[@]}" stop "$CNAME"
    ok "$APP_NAME: stopped"
    ;;

update)
    need_docker
    exists || die "$APP_NAME: not present"
    # Docker does not record the arguments a container was created with, so
    # there is no safe way to recreate an adopted one from its image. Pull the
    # newer image and say plainly that applying it is a manual step.
    img="$("${DK[@]}" inspect -f '{{.Config.Image}}' "$CNAME" 2>/dev/null)"
    log "$APP_NAME: pulling $img"
    run "${DK[@]}" pull "$img"
    warn "$APP_NAME was not created by homelab, and docker does not record the"
    warn "  original 'docker run' arguments, so it cannot be recreated safely."
    warn "  The new image is pulled; recreating the container is yours to do."
    exit $EX_NOOP
    ;;

delete)
    need_docker
    if [ "${APP_ADOPTED:-0}" = 1 ]; then
        err "$APP_NAME is an adopt-only entry: homelab did not create '$CNAME'"
        err "    and will not remove it."
        exit 1
    fi
    exists || { ok "$APP_NAME: nothing to delete"; exit $EX_NOOP; }
    run "${DK[@]}" rm -f "$CNAME"
    ok "$APP_NAME: removed"
    ;;

status)
    if ! dk_resolve; then emit_status absent false detail="$(dk_reason)"; exit 0; fi
    if ! exists; then emit_status absent false; exit 0; fi
    st="$("${DK[@]}" inspect -f '{{.State.Status}}' "$CNAME" 2>/dev/null)"
    hl="$("${DK[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CNAME" 2>/dev/null)"
    case "$st" in
        running)            state=running ;;
        exited|created)     state=stopped ;;
        restarting|paused)  state=degraded ;;
        *)                  state=degraded ;;
    esac
    health="${hl:-none}"
    if [ "$state" = running ] && [ "$health" = none ] && [ -n "${APP_HEALTH_URL:-}" ]; then
        if have curl && curl -fsS -o /dev/null --max-time 3 "$APP_HEALTH_URL" 2>/dev/null; then
            health=healthy
        else
            health=unhealthy
        fi
    fi
    emit_status "$state" true containers="1/1" health="$health" \
        adopted="${APP_ADOPTED:-0}" ports="${APP_PORTS:-}"
    ;;

backup|restore)
    die "$APP_NAME: kind=container has no generic $VERB. An adopted container's data lives wherever it was originally mounted; back that path up directly."
    ;;

*)
    die "container kind: unknown verb '$VERB'"
    ;;
esac
