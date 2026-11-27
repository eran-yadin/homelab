#!/usr/bin/env bash
# Start, then let caddy (home-assistant.nuc) in. Home Assistant answers a
# proxied request with 400 unless its configuration.yaml trusts the proxy;
# caddy runs on the host network, so it connects from 127.0.0.1. Added once,
# only when configuration.yaml has no http: section of its own.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"

set +e; bash "$HOMELAB_ROOT/lib/kinds/compose.sh" start; rc=$?; set -e
[ "$rc" = 0 ] || [ "$rc" = "$EX_NOOP" ] || exit "$rc"
dk_resolve || exit "$rc"

vol="$("${DK[@]}" volume inspect -f '{{.Mountpoint}}' home-assistant_config 2>/dev/null || true)"
cfg="$vol/configuration.yaml"
# The file appears on the first start; give it a moment.
for _ in $(seq 1 30); do
    if [ -z "$vol" ] || $SUDO test -f "$cfg"; then break; fi
    is_apply || break
    sleep 2
done
if [ -n "$vol" ] && $SUDO test -f "$cfg" && ! $SUDO grep -qE '^http:' "$cfg"; then
    log "home-assistant: trusting caddy (127.0.0.1) as its reverse proxy"
    run_sh "printf '\n# Added by homelab: caddy proxies home-assistant.<domain> from this host.\nhttp:\n  use_x_forwarded_for: true\n  trusted_proxies:\n    - 127.0.0.1\n    - ::1\n' | $SUDO tee -a '$cfg' >/dev/null"
    run "${DK[@]}" restart home-assistant >/dev/null
fi
exit "$rc"
