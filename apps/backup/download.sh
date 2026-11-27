#!/usr/bin/env bash
# The backup app is two unit files: a oneshot service that runs
# `homelab backup --all`, and the timer that fires it. Nothing to download.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"

ROOT=/var/lib/homelab/backups/nightly
# The time and how much to keep come from the settings page
# ($HOMELAB_ETC/backup.conf), defaulting to 03:30, 7 days, 4 Sundays.
t="$(sed -n 's/^BACKUP_TIME=//p' "$HOMELAB_ETC/backup.conf" 2>/dev/null | tail -1 || true)"
[[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || t="03:30"
WHEN="*-*-* $t:00"

log "installing homelab-backup.service and .timer"
run_write /etc/systemd/system/homelab-backup.service 0644 <<UNIT
[Unit]
Description=homelab nightly backup of every app that holds data
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=$HOMELAB_ROOT/homelab backup --all $ROOT --apply
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

# --- offsite: another machine pulls the nightly folder --------------------
# The NUC does not push: the other machine (the rig) is often off at 03:30.
# It pulls instead, whenever it is on, as a user that can only READ this one
# folder: its key is forced through rrsync -ro, so it cannot run commands,
# write, or see anything outside $ROOT. Keys are added with
# `homelab offsite allow "<ssh public key>"`.
OFF_USER=homelab-offsite
OFF_HOME=/var/lib/homelab-offsite
log "installing rsync (for the offsite pull)"
run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync
if id "$OFF_USER" >/dev/null 2>&1; then
    ok "user $OFF_USER already exists"
else
    log "creating $OFF_USER (read-only access to the backups, for the offsite pull)"
    # A real shell: sshd runs the forced command through it. The account has
    # no password, and authorized_keys forces every login into the pull.
    run $SUDO useradd --system --home-dir "$OFF_HOME" --create-home --shell /bin/sh "$OFF_USER"
fi
run $SUDO install -d -m 0750 -o "$OFF_USER" -g "$OFF_USER" "$OFF_HOME" "$OFF_HOME/.ssh"
run_write /usr/local/lib/homelab/offsite-pull 0755 <<PULL
#!/bin/sh
# Forced command for $OFF_USER (see authorized_keys). Read-only rsync of the
# nightly backups, then a timestamp the backup app's status reads.
/usr/bin/rrsync -ro $ROOT
rc=\$?
if [ "\$rc" = 0 ]; then date +%s > $OFF_HOME/last-pull; fi
exit "\$rc"
PULL
# The backup root itself: root writes, the offsite group reads.
run $SUDO mkdir -p "$ROOT"
run $SUDO chgrp "$OFF_USER" "$ROOT"
run $SUDO chmod 0750 "$ROOT"

ok "backup: runs $WHEN into $ROOT (start it to arm the timer)"
