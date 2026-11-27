#!/usr/bin/env bash
# Start, then let caddy (home-assistant.<domain>) in. Home Assistant answers a
# proxied request with 400 unless it trusts the proxy; caddy runs on the host
# network, so it connects from 127.0.0.1.
#
# Where that setting lives depends on the version. Current ones keep the HTTP
# settings in .storage/http, copied from configuration.yaml exactly once on the
# first start ("yaml_migration_done") and ignore the YAML after that -- so a
# line added to configuration.yaml later does nothing (seen on nucserver,
# 2026-11-27). Older ones read configuration.yaml. Handle both, once.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"

set +e; bash "$HOMELAB_ROOT/lib/kinds/compose.sh" start; rc=$?; set -e
[ "$rc" = 0 ] || [ "$rc" = "$EX_NOOP" ] || exit "$rc"
dk_resolve || exit "$rc"
is_apply || exit "$rc"

vol="$("${DK[@]}" volume inspect -f '{{.Mountpoint}}' home-assistant_config 2>/dev/null || true)"
[ -n "$vol" ] || exit "$rc"
store="$vol/.storage/http"
cfg="$vol/configuration.yaml"
# Both files appear during the first start.
for _ in $(seq 1 45); do
    if $SUDO test -f "$store" || $SUDO test -f "$cfg"; then break; fi
    sleep 2
done

if $SUDO test -f "$store"; then
    if ! $SUDO grep -q '"use_x_forwarded_for": *true' "$store"; then
        log "home-assistant: trusting caddy (127.0.0.1) as its reverse proxy"
        # Edited while it is stopped: Home Assistant rewrites .storage files
        # from memory and would put the old value back.
        run "${DK[@]}" stop home-assistant >/dev/null
        $SUDO python3 - "$store" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
st = d.setdefault("data", {}).setdefault("stable", {})
st["use_x_forwarded_for"] = True
st["trusted_proxies"] = sorted(set(st.get("trusted_proxies") or []) | {"127.0.0.1", "::1"})
json.dump(d, open(p, "w"), indent=2)
PY
        run "${DK[@]}" start home-assistant >/dev/null
    fi
elif $SUDO test -f "$cfg" && ! $SUDO grep -qE '^http:' "$cfg"; then
    log "home-assistant: trusting caddy (127.0.0.1) as its reverse proxy"
    printf '\n# Added by homelab: caddy proxies home-assistant.<domain> from this host.\nhttp:\n  use_x_forwarded_for: true\n  trusted_proxies:\n    - 127.0.0.1\n    - ::1\n' \
        | $SUDO tee -a "$cfg" >/dev/null
    run "${DK[@]}" restart home-assistant >/dev/null
fi
exit "$rc"
