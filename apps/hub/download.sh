#!/usr/bin/env bash
# The hub is the one app that also deploys the engine it drives.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host

DEST=/opt/homelab-hub
ENGINE=/opt/homelab
HUB_USER="$(owner_user)"
SYSTEMCTL="$(command -v systemctl || echo /usr/bin/systemctl)"

if [ "$DET_FAMILY" != debian ]; then
    die "the hub installer currently only knows apt-based systems (found: $DET_FAMILY)"
fi

log "installing python + flask"
# From apt, not pip: no --break-system-packages, and it stays patched with the
# rest of the system.
run $SUDO apt-get update -qq
run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-flask

# --- deploy the engine ------------------------------------------------------
if [ "$HOMELAB_ROOT" = "$ENGINE" ]; then
    ok "engine already running from $ENGINE"
else
    log "deploying the homelab engine to $ENGINE"
    run $SUDO mkdir -p "$ENGINE"
    run_sh "$SUDO tar -cf - -C '$HOMELAB_ROOT' --exclude=.git --exclude=testenv/golden --exclude=testenv/run . | $SUDO tar -xf - -C '$ENGINE'"
    run $SUDO chown -R root:root "$ENGINE"
    run $SUDO chmod 0755 "$ENGINE/homelab"
    run $SUDO ln -sfn "$ENGINE/homelab" /usr/local/bin/homelab
    ok "engine at $ENGINE (also on PATH as 'homelab')"
fi

# --- deploy the hub ---------------------------------------------------------
log "installing the hub to $DEST"
run $SUDO mkdir -p "$DEST"
run $SUDO cp "$APP_FILES/server.py" "$APP_FILES/index.html" "$APP_FILES/docs.html" "$APP_FILES/update.html" "$DEST/"
run $SUDO chown -R "$HUB_USER" "$DEST"

# Custom filters are written here at runtime, so it must be writable by the
# hub user -- and separate from $DEST, which `update` overwrites.
run $SUDO mkdir -p /var/lib/homelab-hub
run $SUDO chown "$HUB_USER" /var/lib/homelab-hub
run $SUDO chmod 0750 /var/lib/homelab-hub

# --- sudoers ----------------------------------------------------------------
# Written to a temp file and validated before being put in place: a malformed
# file in /etc/sudoers.d breaks sudo for everyone, including the shell you
# would need to fix it.
log "installing sudoers rule for $HUB_USER"
tmp="$(mktemp)"
sed -e "s|@@USER@@|$HUB_USER|g" -e "s|@@SYSTEMCTL@@|$SYSTEMCTL|g" \
    "$APP_FILES/sudoers.tmpl" > "$tmp"
if is_apply; then
    if $SUDO visudo -cqf "$tmp"; then
        $SUDO install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/homelab-hub
        ok "sudoers rule validated and installed"
    else
        rm -f "$tmp"
        die "generated sudoers file is invalid; refusing to install it"
    fi
else
    printf '     would install: /etc/sudoers.d/homelab-hub (after visudo -c)\n' >&2
    sed 's/^/       /' "$tmp" >&2
fi
rm -f "$tmp"

# --- unit -------------------------------------------------------------------
log "installing homelab-hub.service"
sed "s|@@USER@@|$HUB_USER|g" "$APP_FILES/homelab-hub.service" \
    | run_write /etc/systemd/system/homelab-hub.service 0644
run $SUDO systemctl daemon-reload
ok "hub installed (will listen on :7070 as $HUB_USER)"
