#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
have tailscale || die "tailscale is not installed"

if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    log "enabling tailscaled"
    run $SUDO systemctl enable --now tailscaled
fi

if tailscale status >/dev/null 2>&1; then
    ok "already joined: $(tailscale ip -4 2>/dev/null | head -1)"
    exit $EX_NOOP
fi

# Joining needs an interactive browser login unless an auth key is supplied.
if [ -n "${TS_AUTHKEY:-}" ]; then
    log "joining with the supplied auth key"
    run $SUDO tailscale up --authkey "$TS_AUTHKEY" --ssh
    ok "joined: $(tailscale ip -4 2>/dev/null | head -1)"
else
    warn "tailscaled is running but this machine has not joined a network."
    warn "That step needs a browser login, so it has to be you:"
    warn "    sudo tailscale up"
    warn "Or re-run with TS_AUTHKEY=tskey-... to do it unattended."
    exit $EX_NOOP
fi
