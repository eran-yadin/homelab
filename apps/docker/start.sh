#!/usr/bin/env bash
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
set -euo pipefail

if have docker && docker info >/dev/null 2>&1; then
    # still make sure the invoking user can talk to it without sudo
    if ! id -nG "$(id -un)" | tr ' ' '\n' | grep -qx docker && [ "$(id -u)" -ne 0 ]; then
        log "adding $(id -un) to the docker group"
        run $SUDO usermod -aG docker "$(id -un)"
        warn "log out and back in (or: newgrp docker) for that to take effect"
    fi
    ok "docker already running"
    exit $EX_NOOP
fi
log "enabling and starting docker"
run $SUDO systemctl enable --now docker
if [ "$(id -u)" -ne 0 ]; then
    run $SUDO usermod -aG docker "$(id -un)"
    warn "added $(id -un) to the docker group - log out and back in for it to apply"
fi
ok "docker running"
