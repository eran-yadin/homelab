#!/usr/bin/env bash
# The kind's delete, plus the rollback timer a recent start may have armed.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
if systemctl is-active --quiet homelab-firewall-rollback.timer 2>/dev/null; then
    run $SUDO systemctl stop homelab-firewall-rollback.timer
fi
exec bash "$HOMELAB_ROOT/lib/kinds/systemd.sh" delete "$@"
