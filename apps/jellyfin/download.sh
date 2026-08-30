#!/usr/bin/env bash
# Adds the GPU to the container only when this host actually has one.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
ensure_state_dir

override="$APP_STATE/compose.override.yml"
if [ -e /dev/dri/renderD128 ]; then
    ok "found /dev/dri - enabling hardware transcoding"
    cat <<'YML' | run_write "$override" 0644
# Generated at install time because this host has /dev/dri.
services:
  jellyfin:
    devices:
      - /dev/dri:/dev/dri
YML
else
    warn "no /dev/dri on this host - Jellyfin will transcode in software"
    if [ -f "$override" ]; then run $SUDO rm -f "$override"; fi
fi

exec bash "$HOMELAB_ROOT/lib/kinds/compose.sh" download "$@"
