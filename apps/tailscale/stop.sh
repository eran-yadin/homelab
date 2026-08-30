#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
have tailscale || { ok "not installed"; exit $EX_NOOP; }
$SUDO systemctl is-active --quiet tailscaled 2>/dev/null || { ok "already stopped"; exit $EX_NOOP; }
warn "stopping tailscaled drops any remote access that depends on it"
run $SUDO tailscale down
run $SUDO systemctl stop tailscaled
ok "tailscale stopped"
