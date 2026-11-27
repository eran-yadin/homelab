#!/usr/bin/env bash
# Stop and disable smbd and remove the shares. The samba package stays (other
# things may use it); --purge also removes the shares' config and puts
# Debian's own smb.conf back. The shared folders and their files are never
# touched.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
if ! [ -f /etc/samba/homelab.conf ] && ! systemctl is-active --quiet smbd.service 2>/dev/null; then
    ok "samba: nothing to delete"; exit $EX_NOOP
fi
log "samba: stopping and disabling smbd"
run $SUDO systemctl disable --now smbd.service
run $SUDO rm -f /etc/samba/homelab.conf
if $SUDO test -f /etc/samba/smb.conf.debian; then
    run $SUDO mv /etc/samba/smb.conf.debian /etc/samba/smb.conf
fi
if [ "${1:-}" = "--purge" ]; then
    run $SUDO rm -f "$HOMELAB_ETC/samba.conf"
    if [ -d "$APP_STATE" ]; then run $SUDO rm -rf "$APP_STATE"; fi
fi
ok "samba: removed (the shared folders are untouched)"
