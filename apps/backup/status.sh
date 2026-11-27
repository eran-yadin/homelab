#!/usr/bin/env bash
# The kind's status (timer armed? last run ok?), plus one more way to be
# degraded: a machine is allowed to pull the backups offsite but has not done
# so for 3 days. A copy that silently stopped leaving the box is the failure
# this app exists to catch.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"

line="$(bash "$HOMELAB_ROOT/lib/kinds/systemd.sh" status)"
keys=/var/lib/homelab-offsite/.ssh/authorized_keys
stamp=/var/lib/homelab-offsite/last-pull
max_age=$((3*24*3600))

# Unreadable without root (the hub runs status as root): say nothing then.
if [ -r "$keys" ] && grep -q . "$keys" 2>/dev/null; then
    now=$(date +%s)
    last="$(cat "$stamp" 2>/dev/null || echo 0)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    age=$((now - last))
    if [ "$last" = 0 ]; then msg="offsite copy: never pulled yet"; else msg="offsite copy is $((age/86400)) days old"; fi
    line="${line%\}},\"offsite_last\":$last}"
    if [ "$age" -gt "$max_age" ] && printf '%s' "$line" | grep -q '"state":"running"'; then
        line="$(printf '%s' "$line" | sed -e 's/"state":"running"/"state":"degraded"/' \
                                         -e "s/\"health\":\"[^\"]*\"/\"health\":\"$msg\"/")"
    fi
fi
printf '%s\n' "$line"
