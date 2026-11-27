#!/usr/bin/env bash
# The kind's delete, plus the guest-share timer download.sh installed.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
for u in homelab-jellyfin-shares.timer homelab-jellyfin-shares.service; do
    if systemctl cat "$u" >/dev/null 2>&1; then
        case "$u" in *.timer) run $SUDO systemctl disable --now "$u" ;; esac
        run $SUDO rm -f "/etc/systemd/system/$u"
    fi
done
run $SUDO systemctl daemon-reload
exec bash "$HOMELAB_ROOT/lib/kinds/compose.sh" delete "$@"
