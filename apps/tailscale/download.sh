#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host

if have tailscale; then ok "tailscale already installed"; exit $EX_NOOP; fi

case "$DET_FAMILY" in
debian)
    log "adding the tailscale apt repository"
    run $SUDO apt-get update -qq
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl
    run $SUDO mkdir -p /usr/share/keyrings
    codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"
    run $SUDO curl -fsSL "https://pkgs.tailscale.com/stable/$DET_OS_ID/$codename.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    run_write /etc/apt/sources.list.d/tailscale.list 0644 <<EOF
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/$DET_OS_ID $codename main
EOF
    run $SUDO apt-get update -qq
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale
    ;;
arch) run $SUDO pacman -S --needed --noconfirm tailscale ;;
rhel)
    run $SUDO "$DET_PKG" config-manager --add-repo "https://pkgs.tailscale.com/stable/centos/9/tailscale.repo"
    run $SUDO "$DET_PKG" -y install tailscale ;;
*) die "don't know how to install tailscale on family '$DET_FAMILY'" ;;
esac
ok "tailscale installed"
