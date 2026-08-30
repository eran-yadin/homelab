#!/usr/bin/env bash
# Deploy homelab onto nucserver.
#
# Run this ON the nuc:  ssh -t nucserver 'bash ~/homelab/deploy-nuc.sh'
# It needs sudo, so it will ask for a password once and reuse it.
#
# What it does NOT touch: paperless. Its containers were created from
# ~/paperless/docker-compose.yml, and the engine refuses to recreate
# containers built from a different compose file, so the running stack and its
# data are left exactly alone.

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_Z=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_Z"; }
ok()   { printf '%s  ok%s %s\n' "$C_G" "$C_Z" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_Y" "$C_Z" "$*"; }

BK="$HOME/backups/nuc-deploy-$(date +%Y%m%d-%H%M%S)"

step "sanity checks"
[ -f ./homelab ] || { echo "run this from the homelab checkout"; exit 1; }
command -v docker >/dev/null || { echo "docker missing"; exit 1; }
echo "  host: $(hostname)   user: $(id -un)"
sudo -v                       # prompt once, up front, not halfway through
ok "sudo available"

step "backing up what this will replace -> $BK"
mkdir -p "$BK"
sudo cp /etc/sudoers.d/homelab-hub          "$BK/sudoers.d_homelab-hub"   2>/dev/null && ok "old sudoers rule saved"   || warn "no existing sudoers rule"
sudo cp /etc/systemd/system/homelab-hub.service "$BK/homelab-hub.service" 2>/dev/null && ok "old unit saved"            || warn "no existing unit"
sudo tar czf "$BK/opt-homelab-hub.tar.gz" -C /opt homelab-hub 2>/dev/null && ok "old /opt/homelab-hub saved"            || warn "no existing hub dir"
systemctl is-enabled nginx > "$BK/nginx-was-enabled.txt" 2>&1 || true
sudo chown -R "$(id -un)" "$BK"
ls -1 "$BK" | sed 's/^/    /'

step "opting this host in to --apply"
sudo mkdir -p /etc/homelab
printf 'nucserver — deployed %s\n' "$(date -Iseconds)" | sudo tee /etc/homelab/allow-apply >/dev/null
ok "/etc/homelab/allow-apply written"

step "installing the hub (replaces the old one on :7070)"
./homelab install hub --apply

step "nginx -> caddy"
if systemctl is-active --quiet nginx; then
    echo "  nginx is serving only its stock default page and holds :80."
    sudo systemctl disable --now nginx
    ok "nginx stopped and disabled (package left installed, so this is reversible)"
else
    ok "nginx already inactive"
fi
./homelab install caddy --apply

step "adopting what was already running"
for a in amp cockpit feishin; do
    ./homelab download "$a" --apply || true
done

step "result"
./homelab status
echo
echo "  hub:    http://$(hostname -I | awk '{print $1}'):7070"
echo "  caddy:  http://$(hostname -I | awk '{print $1}'):80"
echo "  backup of what was replaced: $BK"
echo
warn "paperless was deliberately not touched. To bring it under homelab later:"
echo "      homelab backup paperless <dir> --apply"
echo "      docker compose -f ~/paperless/docker-compose.yml down"
echo "      homelab restore paperless <dir> --apply && homelab start paperless --apply"
