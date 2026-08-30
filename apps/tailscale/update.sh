#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host
have tailscale || die "not installed"
case "$DET_FAMILY" in
debian) run $SUDO apt-get update -qq
        run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade tailscale ;;
arch)   run $SUDO pacman -Syu --noconfirm tailscale ;;
rhel)   run $SUDO "$DET_PKG" -y update tailscale ;;
esac
ok "tailscale updated"
