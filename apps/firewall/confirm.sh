#!/usr/bin/env bash
# Keep the firewall: disarm the rollback that start/update armed.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$APP_DIR/rollback.sh"
if ! systemctl is-active --quiet "$ROLLBACK_UNIT.timer" 2>/dev/null; then
    if systemctl is-active --quiet homelab-firewall.service 2>/dev/null; then
        ok "firewall: nothing to confirm, it is already kept"
    else
        warn "firewall: not running (if it was on, the rollback already turned it off)"
    fi
    exit $EX_NOOP
fi
run $SUDO systemctl stop "$ROLLBACK_UNIT.timer"
ok "firewall: confirmed, it stays on (and comes back after a reboot)"
