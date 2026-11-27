#!/usr/bin/env bash
# The backup app is two unit files: a oneshot service that runs
# `homelab backup --all`, and the timer that fires it. Nothing to download.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"

ROOT=/var/lib/homelab/backups/nightly
WHEN="*-*-* 03:30:00"

log "installing homelab-backup.service and .timer"
run_write /etc/systemd/system/homelab-backup.service 0644 <<UNIT
[Unit]
Description=homelab nightly backup of every app that holds data
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=$HOMELAB_ROOT/homelab backup --all $ROOT --keep-daily 7 --keep-weekly 4 --apply
Nice=10
IOSchedulingClass=idle
Environment=NO_COLOR=1
UNIT

run_write /etc/systemd/system/homelab-backup.timer 0644 <<UNIT
[Unit]
Description=homelab nightly backup at 03:30

[Timer]
OnCalendar=$WHEN
# A night the box was off is made up at the next boot.
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
UNIT

run $SUDO systemctl daemon-reload
ok "backup: runs $WHEN into $ROOT (start it to arm the timer)"
