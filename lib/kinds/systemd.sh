#!/usr/bin/env bash
# Default lifecycle for kind="systemd".
#
# For apps that are a service on the host rather than a container. The app
# declares  unit="foo.service"  in app.conf and usually supplies its own
# download.sh (to fetch/build/place files); start, stop, status, update and
# delete are inherited from here.

set -euo pipefail

# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"

VERB="${1:-}"; [ -n "$VERB" ] || die "systemd kind: verb required"
shift || true

UNIT="${APP_UNIT:-$APP_NAME.service}"

need_systemd() {
    have systemctl || die "$APP_NAME needs systemd, which this host does not use"
}

unit_exists()  { $SUDO systemctl cat "$UNIT" >/dev/null 2>&1; }
unit_active()  { $SUDO systemctl is-active  --quiet "$UNIT" 2>/dev/null; }
unit_enabled() { $SUDO systemctl is-enabled --quiet "$UNIT" 2>/dev/null; }

case "$VERB" in

download)
    die "$APP_NAME: kind=systemd has no generic download; the app must supply download.sh"
    ;;

start)
    need_systemd
    unit_exists || die "$APP_NAME: $UNIT is not installed (run: homelab install $APP_NAME)"
    if unit_active; then
        ok "$APP_NAME: already running"
        exit $EX_NOOP
    fi
    log "$APP_NAME: starting $UNIT"
    run $SUDO systemctl enable --now "$UNIT"
    ok "$APP_NAME: started"
    ;;

stop)
    need_systemd
    if ! unit_exists; then ok "$APP_NAME: not installed"; exit $EX_NOOP; fi
    if ! unit_active; then ok "$APP_NAME: already stopped"; exit $EX_NOOP; fi
    log "$APP_NAME: stopping $UNIT"
    run $SUDO systemctl stop "$UNIT"
    ok "$APP_NAME: stopped"
    ;;

update)
    need_systemd
    unit_exists || die "$APP_NAME: not installed"
    log "$APP_NAME: reloading unit and restarting"
    run $SUDO systemctl daemon-reload
    if unit_active; then
        run $SUDO systemctl restart "$UNIT"
        ok "$APP_NAME: restarted"
    else
        ok "$APP_NAME: unit reloaded (app is stopped, leaving it stopped)"
    fi
    ;;

delete)
    need_systemd
    purge=0
    if [ "${1:-}" = "--purge" ]; then purge=1; fi
    if ! unit_exists; then ok "$APP_NAME: nothing to delete"; exit $EX_NOOP; fi
    log "$APP_NAME: removing $UNIT"
    run $SUDO systemctl disable --now "$UNIT"
    run $SUDO rm -f "/etc/systemd/system/$UNIT"
    run $SUDO systemctl daemon-reload
    if [ "$purge" -eq 1 ]; then
        warn "$APP_NAME: --purge removes its data directories too"
        for d in ${APP_PURGE_PATHS:-}; do
            run $SUDO rm -rf "$d"
        done
        for u in ${APP_PURGE_USERS:-}; do
            if id "$u" >/dev/null 2>&1; then
                log "$APP_NAME: removing system user $u"
                run $SUDO userdel "$u"
            fi
        done
        if [ -d "$APP_STATE" ]; then run $SUDO rm -rf "$APP_STATE"; fi
    fi
    ok "$APP_NAME: removed"
    ;;

status)
    if ! have systemctl; then emit_status absent false detail="no systemd"; exit 0; fi
    if ! unit_exists; then emit_status absent false; exit 0; fi
    sub="$($SUDO systemctl show -p SubState --value "$UNIT" 2>/dev/null || echo unknown)"
    res="$($SUDO systemctl show -p Result   --value "$UNIT" 2>/dev/null || echo unknown)"
    enabled=false; if unit_enabled; then enabled=true; fi
    if unit_active; then
        state=running
        health=healthy
    elif [ "$res" != success ] && [ "$res" != unknown ]; then
        state=degraded
        health="$res"
    else
        state=stopped
        health=none
    fi
    emit_status "$state" true \
        unit="$UNIT" enabled="$enabled" substate="$sub" health="$health" \
        ports="${APP_PORTS:-}"
    ;;

backup)
    dest="${1:-}"; [ -n "$dest" ] || die "backup needs a destination directory"
    run mkdir -p "$dest"
    paths="${APP_BACKUP_PATHS:-}"
    [ -n "$paths" ] || die "$APP_NAME declares no backup_paths in app.conf"
    for p in $paths; do
        [ -e "$p" ] || { warn "$APP_NAME: $p does not exist, skipping"; continue; }
        n="$(printf '%s' "$p" | tr '/' '_' | sed 's/^_//')"
        log "$APP_NAME: archiving $p"
        run_sh "$SUDO tar -czf '$dest/path-$n.tar.gz' -C '$(dirname "$p")' '$(basename "$p")'"
    done
    if unit_exists; then
        run_sh "$SUDO systemctl cat '$UNIT' > '$dest/$UNIT' 2>/dev/null || true"
    fi
    ok "$APP_NAME: backed up to $dest"
    ;;

restore)
    src="${1:-}"; [ -n "$src" ] || die "restore needs a source directory"
    [ -d "$src" ] || die "no such directory: $src"
    found=0
    for f in "$src"/path-*.tar.gz; do
        [ -f "$f" ] || continue
        found=1
        n="$(basename "$f" .tar.gz)"; n="${n#path-}"
        target="/$(printf '%s' "$n" | tr '_' '/')"
        log "$APP_NAME: restoring $target"
        run_sh "$SUDO tar -xzf '$f' -C '$(dirname "$target")'"
    done
    [ "$found" = 1 ] || die "no path-*.tar.gz archives in $src"
    ok "$APP_NAME: restored from $src"
    ;;

*)
    die "systemd kind: unknown verb '$VERB'"
    ;;
esac
