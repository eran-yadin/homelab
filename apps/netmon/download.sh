#!/usr/bin/env bash
# netmon is a plain python service, so it supplies its own download; the rest
# of the lifecycle is inherited from kind=systemd.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host

INSTALL_DIR=/opt/netmon
DATA_DIR=/var/lib/netmon
LOG_DIR=/var/log/netmon

if [ "$DET_FAMILY" != debian ]; then
    die "netmon's installer currently only knows apt-based systems (found: $DET_FAMILY)"
fi

log "installing runtime dependencies"
run $SUDO apt-get update -qq
run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iputils-ping mtr-tiny python3-venv

if id netmon >/dev/null 2>&1; then
    ok "system user 'netmon' already exists"
else
    log "creating system user 'netmon'"
    run $SUDO useradd --system --no-create-home --shell /usr/sbin/nologin netmon
fi

log "installing to $INSTALL_DIR"
run $SUDO mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$LOG_DIR"
run $SUDO cp "$APP_FILES/netmon.py" "$APP_FILES/netmon-report.py" "$INSTALL_DIR/"
run $SUDO chmod 0755 "$INSTALL_DIR/netmon.py" "$INSTALL_DIR/netmon-report.py"
run $SUDO chown netmon:netmon "$DATA_DIR" "$LOG_DIR"
run $SUDO chmod 0750 "$DATA_DIR" "$LOG_DIR"

if $SUDO test -d "$INSTALL_DIR/venv"; then
    ok "venv already present"
else
    log "creating venv (stdlib only today, but keeps room for future deps)"
    run $SUDO python3 -m venv "$INSTALL_DIR/venv"
fi

log "installing the netmon-report wrapper"
printf '%s\n' '#!/bin/sh' "exec $INSTALL_DIR/venv/bin/python $INSTALL_DIR/netmon-report.py \"\$@\"" \
    | run_write /usr/local/bin/netmon-report 0755

# The original unit hardcoded this network's router. Detect it instead, so the
# same app.conf works on a machine that has never seen this LAN.
GW="${DET_GATEWAY:-}"
if [ -z "$GW" ]; then
    warn "no default gateway found; leaving the gateway target out"
    TARGETS="google_dns=8.8.8.8,cloudflare=1.1.1.1"
else
    ok "detected gateway: $GW"
    TARGETS="gateway=$GW,google_dns=8.8.8.8,cloudflare=1.1.1.1"
fi

log "installing netmon.service"
sed "s|^Environment=NETMON_TARGETS=.*|Environment=NETMON_TARGETS=$TARGETS|" \
    "$APP_FILES/netmon.service" \
    | run_write /etc/systemd/system/netmon.service 0644
run $SUDO systemctl daemon-reload
ok "netmon installed (targets: $TARGETS)"
