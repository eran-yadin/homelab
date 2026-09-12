#!/usr/bin/env bash
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
set -euo pipefail
detect_host

# `docker compose build` needs buildx >= 0.17. Debian ships docker-buildx
# 0.13, which satisfies "is buildx present?" and then fails the build with
# "compose build requires buildx 0.17.0 or later" -- long after the install
# reported success.
buildx_ok() {
    local v
    v="$(docker buildx version 2>/dev/null \
         | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [ -n "$v" ] || return 1
    [ "$(printf '%s\n0.17.0\n' "$v" | sort -V | head -1)" = "0.17.0" ]
}

if have docker && docker compose version >/dev/null 2>&1; then
    if buildx_ok; then
        ok "docker + compose plugin already present"
        exit $EX_NOOP
    fi
    warn "docker is present but buildx is $(docker buildx version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo missing)"
    warn "  compose needs 0.17.0 or later to build an image from a Dockerfile."
    if [ "$DET_FAMILY" = debian ]; then
        # Debian's docker-buildx and docker-ce's docker-buildx-plugin both own
        # /usr/libexec/docker/cli-plugins/docker-buildx, so dpkg refuses to
        # install the second while the first is present. Nothing depends on the
        # Debian one -- it is only the plugin binary -- so it goes first.
        if dpkg -s docker-buildx >/dev/null 2>&1; then
            warn "Debian's docker-buildx package owns the same file and is the"
            warn "  reason the newer plugin cannot install. Removing it."
            run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq docker-buildx
        fi
        log "installing docker-buildx-plugin from the docker repository"
        run $SUDO apt-get update -qq
        run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-buildx-plugin
        if is_apply && ! buildx_ok; then
            err "buildx is still too old. Debian's 'docker-buildx' package can"
            err "    shadow the docker-ce plugin -- remove it and retry:"
            err "        sudo apt-get remove docker-buildx"
            exit 1
        fi
        ok "buildx updated"
        exit $EX_OK
    fi
    die "buildx is too old and this host is not debian-family; upgrade it by hand"
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
