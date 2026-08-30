#!/usr/bin/env bash
# AMP's own uninstall is known to leave remnants, and /home/amp holds every
# game server it manages. Stopping it is ours to do; deleting worlds is not.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"

if ! systemctl cat ampinstmgr.service >/dev/null 2>&1; then
    ok "AMP is not installed"
    exit $EX_NOOP
fi

log "stopping and disabling AMP"
run $SUDO systemctl disable --now ampinstmgr.service

if [ "${1:-}" = "--purge" ]; then
    warn "refusing to purge AMP's data directory."
    warn "  /home/amp/.ampdata holds every instance AMP manages -- worlds,"
    warn "  saves, configs. Nothing here knows which of those you still want."
    warn "  To remove AMP completely, use CubeCoders' own uninstaller, then"
    warn "  delete /home/amp and the 'amp' system user by hand:"
    warn "      sudo ampinstmgr --help   # see its uninstall options"
    warn "      https://github.com/CubeCoders/AMP/issues/1024"
fi
ok "AMP stopped and disabled (data left in place)"
