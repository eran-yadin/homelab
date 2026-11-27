#!/usr/bin/env bash
# `homelab jellyfin ...`: family accounts and guest shares. The work is in
# files/jfctl.py (Jellyfin's API); this script makes the API key it needs and
# keeps the dry-run rule: anything that changes Jellyfin needs --apply.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"

KEY="$APP_STATE/api.key"
SHARES="$APP_STATE/shares.json"
PORT="$($SUDO sed -n 's/^JELLYFIN_PORT=//p' "$APP_STATE/.env" 2>/dev/null || true)"; PORT="${PORT:-8096}"
API="http://127.0.0.1:$PORT"
sub="${1:-help}"; [ $# -gt 0 ] && shift

usage() {
cat <<'U'
homelab jellyfin user list
homelab jellyfin user add NAME [--kid AGE]   family account (Movies, Shows, Music); --kid: Movies + Shows,
                                             ratings up to AGE, no downloads. Prints a password once.
homelab jellyfin user password NAME          a new password, printed once
homelab jellyfin user remove NAME            (never an admin)
homelab jellyfin share NAME [--hours 24]     a guest account that ends by itself: Movies + Shows,
                                             no downloads, no deleting, 2 streams. Prints how to log in.
homelab jellyfin share list
homelab jellyfin share stop NAME | stop all
Everything except list needs --apply.
U
}

# The API key: made once, straight into Jellyfin's database (no admin login
# needed), kept in the app's state dir, root only. Jellyfin is stopped for
# the write -- it caches keys -- and started again.
ensure_key() {
    if $SUDO test -s "$KEY"; then return 0; fi
    is_apply || { warn "jellyfin: would create an API key for homelab (needs --apply)"; return 1; }
    dk_resolve || die "jellyfin: docker is not reachable"
    local vol db tok
    vol="$("${DK[@]}" volume inspect -f '{{.Mountpoint}}' jellyfin_config 2>/dev/null || true)"
    db="$vol/data/jellyfin.db"
    $SUDO test -f "$db" || die "jellyfin: finish Jellyfin's own setup wizard first (no database yet)"
    tok="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    log "jellyfin: creating an API key for homelab (Jellyfin restarts, ~15 s)"
    run "${DK[@]}" stop jellyfin >/dev/null
    $SUDO python3 - "$db" "$tok" <<'PY'
import sqlite3, sys, datetime
db, tok = sys.argv[1], sys.argv[2]
now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S.%f0")
c = sqlite3.connect(db)
c.execute('INSERT INTO ApiKeys (DateCreated, DateLastActivity, Name, AccessToken) VALUES (?,?,?,?)', (now, now, "homelab", tok))
c.commit(); c.close()
PY
    printf '%s\n' "$tok" | $SUDO tee "$KEY" >/dev/null
    $SUDO chmod 0600 "$KEY"
    run "${DK[@]}" start jellyfin >/dev/null
    for _ in $(seq 1 60); do curl -fsS -o /dev/null "$API/health" 2>/dev/null && break; sleep 1; done
}

jf() {  # jf <args...>: run jfctl.py with the key on stdin (never on the command line)
    $SUDO cat "$KEY" | $SUDO env JF_API="$API" JF_SHARES="$SHARES" JF_APPLY="${HOMELAB_APPLY:-0}" \
        JF_LAN="${PUBLISHED:-}" python3 "$APP_DIR/files/jfctl.py" "$@"
}

PUBLISHED="$($SUDO sed -n 's/^PUBLISHED_URL=//p' "$APP_STATE/.env" 2>/dev/null || true)"
export PUBLISHED

case "$sub" in
    help|-h|--help) usage ;;
    user|share)
        what="${1:-list}"
        if [ "$what" != list ] && [ "$what" != expire ] && ! is_apply; then
            warn "jellyfin: dry run - '$sub $*' would change Jellyfin; add --apply"
            exit 0
        fi
        if [ "$what" = expire ] && ! $SUDO test -s "$KEY"; then exit 0; fi   # never set up: nothing to end
        ensure_key || exit 0
        jf "$sub" "$@" ;;
    *) usage; exit 1 ;;
esac
