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
    # An adopt-only entry does not install anything: it puts a service that
    # already exists on this host into the catalog so the hub can see and
    # control it.
    if [ "${APP_ADOPTED:-0}" = 1 ]; then
        if unit_exists; then
            ok "$APP_NAME: adopting the existing $UNIT"
            exit $EX_NOOP
        fi
        die "$APP_NAME is an adopt-only entry, but $UNIT does not exist on this host"
    fi
    die "$APP_NAME: kind=systemd has no generic download; the app must supply download.sh"
    ;;

start)
    need_systemd
    if ! unit_exists; then
        # During a dry run download.sh has not actually written the unit, so a
        # hard failure here would make it impossible to preview a full install.
        if ! is_apply; then
            warn "$APP_NAME: $UNIT does not exist yet (a real run installs it first)"
            exit $EX_NOOP
        fi
        die "$APP_NAME: $UNIT is not installed (run: homelab install $APP_NAME)"
    fi
    if unit_active; then
        ok "$APP_NAME: already running"
        exit $EX_NOOP
    fi
    preflight_conflicts
    preflight_ports ${APP_PORTS:-}
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
    # For these apps "update" means redeploy: download.sh is what places the
    # files, so reloading the unit without re-running it would restart the
    # service on the exact same code it was already running.
    if [ -x "$APP_DIR/download.sh" ]; then
        log "$APP_NAME: re-running download to refresh installed files"
        bash "$APP_DIR/download.sh"
    fi
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
    if [ "${APP_ADOPTED:-0}" = 1 ]; then
        err "$APP_NAME is an adopt-only entry: homelab did not install it and"
        err "    will not remove it. Remove it the way it was installed."
        exit 1
    fi
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
    if unit_active; then
        err "$APP_NAME is running. Restoring over files it has open is not safe."
        err "    Stop it first:  homelab stop $APP_NAME --apply"
        exit 1
    fi
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
