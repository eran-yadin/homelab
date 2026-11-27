#!/usr/bin/env bash
# The kind's status, plus: a firewall waiting for its confirm is degraded, so
# the hub shows that it will switch itself off.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
line="$(bash "$HOMELAB_ROOT/lib/kinds/systemd.sh" status)"
if systemctl is-active --quiet homelab-firewall-rollback.timer 2>/dev/null \
   && printf '%s' "$line" | grep -q '"state":"running"'; then
    line="$(printf '%s' "$line" | sed -e 's/"state":"running"/"state":"degraded"/' \
        -e 's/"health":"[^"]*"/"health":"not confirmed: turns itself off soon (homelab confirm firewall --apply)"/')"
fi
printf '%s\n' "$line"
