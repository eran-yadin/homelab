#!/usr/bin/env bash
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
set -euo pipefail
detect_host
have docker || die "docker is not installed"
case "$DET_FAMILY" in
debian) run $SUDO apt-get update -qq
        run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            --only-upgrade docker-ce docker-ce-cli containerd.io docker-compose-plugin ;;
arch)   run $SUDO pacman -Syu --noconfirm docker docker-compose ;;
rhel)   run $SUDO "$DET_PKG" -y update docker-ce docker-ce-cli containerd.io docker-compose-plugin ;;
*)      die "unsupported family: $DET_FAMILY" ;;
esac
ok "docker updated"
