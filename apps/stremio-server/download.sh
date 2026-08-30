#!/usr/bin/env bash
# Enable hardware transcoding only where the hardware exists.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host
ensure_state_dir

override="$APP_STATE/compose.override.yml"
if [ -e /dev/dri/renderD128 ]; then
    ok "found /dev/dri - exposing it for hardware transcoding"
    cat <<'YML' | run_write "$override" 0644
# Generated at install time because this host has /dev/dri.
services:
  stremio-server:
    devices:
      - /dev/dri:/dev/dri
YML
else
    warn "no /dev/dri here - transcoding will be software only"
    if [ -f "$override" ]; then run $SUDO rm -f "$override"; fi
fi

# A 2-core box transcoding while paperless OCRs and whisper transcribes is the
# realistic contention on nucserver, so say it once at install time.
if [ "${DET_CPUS:-0}" -le 2 ]; then
    warn "this host has ${DET_CPUS} cores; transcoding will compete with"
    warn "  anything else CPU-heavy already running here"
fi

exec bash "$HOMELAB_ROOT/lib/kinds/compose.sh" download "$@"
