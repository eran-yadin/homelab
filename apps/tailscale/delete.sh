#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host
have tailscale || { ok "not installed"; exit $EX_NOOP; }
warn "removing tailscale drops remote access to this machine"
run $SUDO systemctl disable --now tailscaled
case "$DET_FAMILY" in
debian) run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq tailscale ;;
arch)   run $SUDO pacman -Rns --noconfirm tailscale ;;
rhel)   run $SUDO "$DET_PKG" -y remove tailscale ;;
esac
if [ "${1:-}" = "--purge" ]; then run $SUDO rm -rf /var/lib/tailscale; fi
ok "tailscale removed"
