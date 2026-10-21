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
run $SUDO mkdir -p "$INSTALL_DIR/web" "$DATA_DIR" "$LOG_DIR"
run $SUDO cp "$APP_FILES/netmon.py" "$APP_FILES/netmon-report.py" "$APP_FILES/netmon-control" "$INSTALL_DIR/"
run $SUDO chmod 0755 "$INSTALL_DIR/netmon.py" "$INSTALL_DIR/netmon-report.py" "$INSTALL_DIR/netmon-control"
run $SUDO cp "$APP_FILES/web/server.py" "$APP_FILES/web/index.html" "$INSTALL_DIR/web/"
run $SUDO chmod 0644 "$INSTALL_DIR/web/server.py" "$INSTALL_DIR/web/index.html"
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

SETTINGS="$DATA_DIR/settings.env"
SETTING_KEYS="NETMON_TARGETS NETMON_INTERVAL NETMON_TIMEOUT NETMON_RETENTION_DAYS"

# What the web UI saves lives in settings.env, which overrides the unit's own
# Environment= lines. Before this file existed, the targets were edited into
# the unit by hand -- so on a box that already runs netmon, carry the unit's
# current values over before the unit is replaced, or an update would quietly
# reset them. Read-only, so no sudo (CLAUDE.md rule 5).
MIGRATE=""
if ! $SUDO test -e "$SETTINGS" && systemctl cat netmon.service >/dev/null 2>&1; then
    env_now="$(systemctl show -p Environment --value netmon.service 2>/dev/null || true)"
    for k in $SETTING_KEYS; do
        v="$(printf '%s\n' $env_now | sed -n "s/^$k=//p" | head -1)"
        if [ -n "$v" ]; then MIGRATE="$MIGRATE$k=$v
"; fi
    done
fi

# The original unit hardcoded this network's router. Detect it instead, so the
# same app.conf works on a machine that has never seen this LAN.
GW="${DET_GATEWAY:-}"
if [ -z "$GW" ]; then
    warn "no default gateway found; leaving the gateway target out"
    TARGETS="google_dns=8.8.8.8,cloudflare=1.1.1.1"
else
    ok "detected gateway: $GW"
    TARGETS="gateway=$GW,google_dns=8.8.8.8,cloudflare=1.1.1.1"
    # isp_edge: the first router past ours that answers. Behind CGNAT the hop
    # right after the gateway is often silent, so take the first that replies.
    # Only on a fresh install: an existing box keeps what it has.
    if [ -z "$MIGRATE" ] && ! $SUDO test -e "$SETTINGS" && have mtr; then
        edge="$(mtr -n -r -c 2 -4 8.8.8.8 2>/dev/null \
                | awk -v gw="$GW" '$1 ~ /^[0-9]+\.\|--$/ && $2 != "???" && $2 != gw && $3+0 < 100 {print $2; exit}')"
        if [ -n "$edge" ] && [ "$edge" != 8.8.8.8 ]; then
            ok "detected ISP edge: $edge"
            TARGETS="gateway=$GW,isp_edge=$edge,google_dns=8.8.8.8,cloudflare=1.1.1.1"
        fi
    fi
fi

if [ -n "$MIGRATE" ]; then
    log "keeping this box's current netmon settings in $SETTINGS"
    printf '# Carried over from the netmon.service this box ran before netmon web.\n# Edit from the web UI; values here override the unit.\n%s' "$MIGRATE" \
        | run_write "$SETTINGS" 0640
    run $SUDO chown netmon:netmon "$SETTINGS"
fi

log "installing netmon.service, netmon-web.service, netmon-control.path"
sed "s|^Environment=NETMON_TARGETS=.*|Environment=NETMON_TARGETS=$TARGETS|" \
    "$APP_FILES/netmon.service" \
    | run_write /etc/systemd/system/netmon.service 0644
for u in netmon-web.service netmon-control.path netmon-control.service; do
    run_write "/etc/systemd/system/$u" 0644 < "$APP_FILES/$u"
done
run $SUDO systemctl daemon-reload
if [ -n "$MIGRATE" ]; then
    ok "netmon installed (settings carried over: $(printf '%s' "$MIGRATE" | sed -n 's/^NETMON_TARGETS=//p'))"
else
    ok "netmon installed (targets: $TARGETS)"
fi
ok "web UI: http://${DET_IP:-<server-ip>}:8095 once started"
