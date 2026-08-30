#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
if ! have tailscale; then emit_status absent false; exit 0; fi
if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    emit_status stopped true detail="daemon not running"; exit 0
fi
ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
if [ -n "$ip" ]; then
    emit_status running true ip="$ip" health=healthy
else
    emit_status degraded true detail="daemon up but not joined - run: sudo tailscale up"
fi
