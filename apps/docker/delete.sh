#!/usr/bin/env bash
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
set -euo pipefail
detect_host
have docker || { ok "docker not installed"; exit $EX_NOOP; }
purge=0; [ "${1:-}" = "--purge" ] && purge=1
warn "removing docker will take every container on this machine with it"
run $SUDO systemctl disable --now docker.socket docker.service
case "$DET_FAMILY" in
debian) run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ;;
arch)   run $SUDO pacman -Rns --noconfirm docker docker-compose ;;
rhel)   run $SUDO "$DET_PKG" -y remove docker-ce docker-ce-cli containerd.io docker-compose-plugin ;;
esac
if [ "$purge" = 1 ]; then
    warn "--purge: deleting /var/lib/docker (all images and volumes)"
    run $SUDO rm -rf /var/lib/docker /var/lib/containerd
fi
ok "docker removed"
