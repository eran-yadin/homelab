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

# Guest shares end on time: a timer runs `homelab jellyfin share expire`.
run_write /etc/systemd/system/homelab-jellyfin-shares.service 0644 <<UNIT
[Unit]
Description=homelab: end expired Jellyfin guest shares

[Service]
Type=oneshot
ExecStart=$HOMELAB_ROOT/homelab jellyfin share expire --apply
UNIT
run_write /etc/systemd/system/homelab-jellyfin-shares.timer 0644 <<UNIT
[Unit]
Description=homelab: end expired Jellyfin guest shares, every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
run $SUDO systemctl daemon-reload
run $SUDO systemctl enable --now homelab-jellyfin-shares.timer

rc=0; bash "$HOMELAB_ROOT/lib/kinds/compose.sh" download "$@" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = "$EX_NOOP" ] || exit "$rc"

# The address discovery answers with (see compose.yml). Filled in once: an
# install from before this existed gets the line added; a value set by hand
# is left alone.
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host
if [ -n "${DET_IP:-}" ] && $SUDO test -f "$APP_STATE/.env"; then
    if ! $SUDO grep -q '^PUBLISHED_URL=' "$APP_STATE/.env"; then
        run_sh "echo 'PUBLISHED_URL=http://$DET_IP:8096' | $SUDO tee -a '$APP_STATE/.env' >/dev/null"
    elif $SUDO grep -q '^PUBLISHED_URL=$' "$APP_STATE/.env"; then
        run_sh "$SUDO sed -i 's|^PUBLISHED_URL=$|PUBLISHED_URL=http://$DET_IP:8096|' '$APP_STATE/.env'"
    fi
fi
exit "$rc"
