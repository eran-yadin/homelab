#!/usr/bin/env bash
# Run this on the machine that keeps the OFFSITE copy (not on the server).
# As your normal user, no sudo:
#
#     bash install-puller.sh <server-address> [dest-dir]
#     e.g. bash install-puller.sh 100.90.182.50 ~/backups/nucserver
#
# It makes a key just for this, prints the one command to run on the server to
# allow it, and installs a systemd *user* timer that pulls the server's nightly
# backups once a day and a few minutes after this machine starts (a machine
# that is often off still gets a copy whenever it is on). After each pull it
# checks that the newest night's archives are not corrupt.
#
# The server only lets this key READ the backup folder (rrsync -ro), so the
# key on this machine cannot change anything on the server.
#
# Remove:  systemctl --user disable --now homelab-pull.timer
#          rm ~/.config/systemd/user/homelab-pull.* ~/.local/bin/homelab-pull
set -euo pipefail

HOST="${1:?usage: install-puller.sh <server-address> [dest-dir]}"
DEST="${2:-$HOME/backups/$HOST}"
KEY="$HOME/.ssh/id_homelab_pull"
BIN="$HOME/.local/bin/homelab-pull"
UNITS="$HOME/.config/systemd/user"

command -v rsync >/dev/null || { echo "install rsync first (pacman -S rsync / apt install rsync)" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "needs systemd" >&2; exit 1; }

mkdir -p "$HOME/.ssh" "$DEST" "$(dirname "$BIN")" "$UNITS"
chmod 0700 "$HOME/.ssh" "$DEST"
if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "homelab-pull@$(hostname)" -f "$KEY"
fi

cat > "$BIN" <<EOF
#!/usr/bin/env bash
# Pull the server's nightly backups, then check the newest night.
set -euo pipefail
DEST="$DEST"
# --delete: the copy mirrors the server's own retention (7 days + 4 Sundays).
rsync -a --delete --partial \\
    -e "ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new" \\
    "homelab-offsite@$HOST:./" "\$DEST/"
newest="\$(readlink "\$DEST/latest" || true)"
[ -n "\$newest" ] && [ -d "\$DEST/\$newest" ] || { echo "no latest night in \$DEST" >&2; exit 1; }
bad=0
while IFS= read -r -d '' f; do
    gzip -t "\$f" 2>/dev/null || { echo "CORRUPT: \$f" >&2; bad=1; }
done < <(find "\$DEST/\$newest" -name '*.tar.gz' -print0)
[ "\$bad" = 0 ] || exit 1
date '+%F %T' > "\$DEST/.last-pull-ok"
echo "pulled and checked \$newest"
EOF
chmod 0755 "$BIN"

cat > "$UNITS/homelab-pull.service" <<EOF
[Unit]
Description=Pull the homelab nightly backups from $HOST
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN
Nice=10
EOF

cat > "$UNITS/homelab-pull.timer" <<EOF
[Unit]
Description=Pull the homelab backups daily, and soon after this machine starts

[Timer]
OnStartupSec=10min
OnCalendar=*-*-* 09:00:00
Persistent=true
RandomizedDelaySec=10min

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now homelab-pull.timer >/dev/null

echo
echo "Installed. Now allow this machine on the server (one line, run it there):"
echo
echo "    sudo /opt/homelab/homelab offsite allow \"$(cat "$KEY.pub")\" --apply"
echo
echo "Then test a pull right away:   systemctl --user start homelab-pull.service"
echo "and see how it went:           journalctl --user -u homelab-pull.service -n 20"
