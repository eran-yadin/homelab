#!/usr/bin/env bash
# Regenerate the rules from firewall.conf and reload them. Changed rules can
# lock you out just like the first start, so a running firewall gets the same
# safety net.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$APP_DIR/rollback.sh"
was_active=0
if systemctl is-active --quiet homelab-firewall.service 2>/dev/null; then was_active=1; fi
bash "$HOMELAB_ROOT/lib/kinds/systemd.sh" update
if [ "$was_active" = 1 ]; then arm_rollback; fi
