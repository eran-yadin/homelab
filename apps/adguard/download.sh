#!/usr/bin/env bash
# Port 53 is the one port on a Linux box that is usually already spoken for.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host
ensure_state_dir

env_file="$APP_STATE/.env"
if ! $SUDO test -f "$env_file"; then
    bind="0.0.0.0"
    if ss -tulnH 2>/dev/null | grep -qE '127\.0\.0\.5[34]:53'; then
        if [ -n "${DET_IP:-}" ]; then
            bind="$DET_IP"
            warn "systemd-resolved already holds :53 on loopback"
            ok   "binding AdGuard's DNS to $bind instead, leaving resolved alone"
        else
            warn "systemd-resolved holds :53 and no LAN address was detected."
            warn "If start fails, either set DNS_BIND_IP in $env_file, or"
            warn "disable the stub listener: DNSStubListener=no in"
            warn "/etc/systemd/resolved.conf, then restart systemd-resolved."
        fi
    fi
    sed -e "s|^DNS_BIND_IP=.*|DNS_BIND_IP=$bind|" "$APP_FILES/env.template" \
        | run_write "$env_file" 0600
    run $SUDO chown "$(owner_user):$(owner_group)" "$env_file"
fi

exec bash "$HOMELAB_ROOT/lib/kinds/compose.sh" download "$@"
