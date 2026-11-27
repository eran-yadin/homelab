#!/usr/bin/env bash
# Start the container, then do the setup wizard's job once, so `*.nuc` names
# work without anyone clicking through it:
#   - an admin account, its password generated here and kept only in the
#     app's .env (root, 0600): sudo grep ADGUARD_ADMIN /var/lib/homelab/apps/adguard/.env
#   - one rule per network for *.<domain>: home devices get the LAN address,
#     tailnet devices get the tailscale address (so hub.nuc also works away
#     from home). AdGuard picks by the asking client's address.
# Every lookup below may legitimately find nothing (no caddy, no tailscale):
# each ends in `|| true`, because under set -e a failed one would end the
# script with no message (CLAUDE.md, gotchas).
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host

set +e; bash "$HOMELAB_ROOT/lib/kinds/compose.sh" start; rc=$?; set -e
[ "$rc" = 0 ] || [ "$rc" = "$EX_NOOP" ] || exit "$rc"
is_apply || exit "$rc"

env_file="$APP_STATE/.env"
port="$($SUDO sed -n 's/^ADGUARD_PORT=//p' "$env_file" 2>/dev/null || true)"; port="${port:-3080}"
api="http://127.0.0.1:$port"
domain="$($SUDO sed -n 's/^CADDY_DOMAIN=//p' "$(app_state_dir caddy)/.env" 2>/dev/null || true)"; domain="${domain:-nuc}"
lan_ip="${DET_IP:-}"
ts_ip="$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
lan_net="$(ip -4 route show dev "$(ip route | awk '/^default/{print $5; exit}')" proto kernel scope link 2>/dev/null | awk '{print $1; exit}' || true)"

have curl || { warn "adguard: curl is missing, finish the setup at $api"; exit "$rc"; }
for _ in $(seq 1 30); do curl -fsS -o /dev/null "$api/" 2>/dev/null && break; sleep 1; done

# --- first run: the wizard ---------------------------------------------------
if curl -fsS "$api/control/install/get_addresses" >/dev/null 2>&1; then
    pass="$($SUDO sed -n 's/^ADGUARD_ADMIN_PASSWORD=//p' "$env_file" || true)"
    if [ -z "$pass" ]; then
        pass="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)"
        printf 'ADGUARD_ADMIN_USER=admin\nADGUARD_ADMIN_PASSWORD=%s\n' "$pass" | $SUDO tee -a "$env_file" >/dev/null
    fi
    log "adguard: first-run setup (admin account; password in $env_file)"
    body="$(printf '{"web":{"ip":"0.0.0.0","port":3000},"dns":{"ip":"0.0.0.0","port":53},"username":"admin","password":"%s"}' "$pass")"
    curl -fsS -X POST -H 'Content-Type: application/json' -d "$body" "$api/control/install/configure" >/dev/null \
        || die "adguard: the setup call failed; finish it by hand at $api"
    for _ in $(seq 1 20); do curl -fsS -o /dev/null "$api/login.html" 2>/dev/null && break; sleep 1; done
fi

# --- *.domain rules (every start: the addresses may have changed) -------------
pass="$($SUDO sed -n 's/^ADGUARD_ADMIN_PASSWORD=//p' "$env_file" || true)"
if [ -z "$pass" ]; then
    warn "adguard: no admin password in $env_file (set up by hand?); not touching its rules"
    exit "$rc"
fi
rules=()
[ -n "$lan_ip" ] && [ -n "$lan_net" ] && rules+=("||$domain^\$dnsrewrite=NOERROR;A;$lan_ip,client=$lan_net")
[ -n "$ts_ip" ] && rules+=("||$domain^\$dnsrewrite=NOERROR;A;$ts_ip,client=100.64.0.0/10")
[ "${#rules[@]}" -gt 0 ] || { warn "adguard: no LAN or tailscale address found; no *.$domain rules"; exit "$rc"; }
json="$(printf '"%s",' "${rules[@]}")"
# Wait for the API proper (not just the web server) before reading rules.
for _ in $(seq 1 30); do
    curl -fsS -o /dev/null -u "admin:$pass" "$api/control/status" 2>/dev/null && break
    sleep 1
done
# Keep whatever rules were added by hand; replace only ours (the *.domain ones).
current="$(curl -fsS -u "admin:$pass" "$api/control/filtering/status" 2>/dev/null \
    | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("user_rules") or []))' 2>/dev/null || true)"
keep="$(printf '%s\n' "$current" | grep -v "^||$domain^\\\$dnsrewrite=" | grep . | python3 -c 'import json,sys; print(",".join(json.dumps(l.rstrip("\n")) for l in sys.stdin))' || true)"
# Right after a (re)start the web server answers before the API routes are
# registered, and set_rules gets a 404. Retry for a while.
written=0
for _ in $(seq 1 30); do
    if curl -fsS -u "admin:$pass" -X POST -H 'Content-Type: application/json' \
        -d "{\"rules\":[${json%,}${keep:+,$keep}]}" "$api/control/filtering/set_rules" >/dev/null 2>&1; then
        written=1; break
    fi
    sleep 1
done
[ "$written" = 1 ] || die "adguard: could not write the *.$domain rules (API not answering at $api)"
ok "adguard: *.$domain -> $lan_ip for $lan_net${ts_ip:+, $ts_ip for the tailnet}"
exit "$rc"
