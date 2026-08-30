#!/usr/bin/env bash
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
set -euo pipefail
have docker || { ok "docker not installed"; exit $EX_NOOP; }
docker info >/dev/null 2>&1 || { ok "docker already stopped"; exit $EX_NOOP; }
warn "stopping docker stops every container on this machine"
run $SUDO systemctl stop docker.socket docker.service
ok "docker stopped"
