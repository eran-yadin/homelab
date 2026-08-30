#!/usr/bin/env bash
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
set -euo pipefail
detect_host

if have docker && docker compose version >/dev/null 2>&1; then
    ok "docker + compose plugin already present"
    exit $EX_NOOP
fi

case "$DET_FAMILY" in
debian)
    # A minimal cloud image has neither curl nor gnupg. Rather than pull in
    # gnupg just to dearmor a key, keep the key ASCII-armored -- apt reads
    # .asc directly, so the dependency disappears.
    log "installing apt prerequisites"
    run $SUDO apt-get update -qq
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates curl

    log "adding Docker's apt repository"
    run $SUDO install -m0755 -d /etc/apt/keyrings
    run $SUDO curl -fsSL "https://download.docker.com/linux/$DET_OS_ID/gpg" \
        -o /etc/apt/keyrings/docker.asc
    run $SUDO chmod a+r /etc/apt/keyrings/docker.asc
    codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"
    run_write /etc/apt/sources.list.d/docker.list 0644 <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$DET_OS_ID $codename stable
EOF
    log "installing docker packages"
    run $SUDO apt-get update -qq
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ;;
arch)
    run $SUDO pacman -S --needed --noconfirm docker docker-compose
    ;;
rhel)
    run $SUDO "$DET_PKG" -y install dnf-plugins-core
    run $SUDO "$DET_PKG" config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    run $SUDO "$DET_PKG" -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    ;;
*)
    die "don't know how to install docker on family '$DET_FAMILY'"
    ;;
esac
ok "docker packages installed"
