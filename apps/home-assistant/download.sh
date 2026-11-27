#!/usr/bin/env bash
# Home Assistant talks to Bluetooth through the HOST's BlueZ over D-Bus
# (/run/dbus is mounted in). Without bluez on the host it shows "Failed to
# start Bluetooth: org.bluez was not provided by any .service files" for
# every adapter. So when this box has an adapter, install and start bluez.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host

if compgen -G "/sys/class/bluetooth/hci*" >/dev/null; then
    if [ "$DET_FAMILY" = debian ]; then
        if ! dpkg -s bluez >/dev/null 2>&1; then
            log "home-assistant: this box has a Bluetooth adapter; installing bluez for it"
            run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bluez
        fi
        if ! systemctl is-active --quiet bluetooth.service 2>/dev/null; then
            run $SUDO systemctl enable --now bluetooth.service
        fi
    else
        warn "home-assistant: install bluez yourself for Bluetooth ($DET_FAMILY is not apt-based)"
    fi
fi

exec bash "$HOMELAB_ROOT/lib/kinds/compose.sh" download "$@"
