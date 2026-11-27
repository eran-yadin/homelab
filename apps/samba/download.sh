#!/usr/bin/env bash
# Install Samba, write the shares from /etc/homelab/samba.conf, give the
# box owner a Samba password. Starting smbd is the kind's job.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host
ensure_state_dir
[ "$DET_FAMILY" = debian ] || die "the samba installer only knows apt-based systems (found: $DET_FAMILY)"

CONF="$HOMELAB_ETC/samba.conf"
OWNER="$(owner_user)"

log "installing samba"
run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq samba

# --- which folders are shared: decided once, then yours to edit ---------------
if ! $SUDO test -f "$CONF"; then
    shares="media=/srv/media share=/srv/share"
    if [ -d /srv/3dmodels ]; then shares="$shares 3dmodels=/srv/3dmodels"; fi
    run_write "$CONF" 0644 <<CONFIG
# homelab samba shares: name=/path, space-separated. After editing:
#   homelab update samba --apply
SHARES="$shares"
# Networks allowed in (Samba's own check, on top of the firewall app).
ALLOW="127. 10. 172.16.0.0/12 192.168. 100.64.0.0/10"
CONFIG
fi
if is_apply; then
    # shellcheck disable=SC1090
    . "$CONF"
else
    SHARES="media=/srv/media share=/srv/share"; ALLOW="127. 10. 192.168. 100.64.0.0/10"
fi

conf="[global]
   server string = %h (homelab)
   server min protocol = SMB2_10
   map to guest = never
   hosts allow = $ALLOW
   hosts deny = ALL
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
"
for s in $SHARES; do
    name="${s%%=*}"; path="${s#*=}"
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "share name not allowed: $name"
    [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ ]] && [[ "$path" != *..* ]] || die "share path not allowed: $path"
    case "$path" in /|/etc*|/root*|/var/lib/samba*|/boot*) die "will not share $path" ;; esac
    if ! [ -d "$path" ]; then
        run $SUDO mkdir -p "$path"
        run $SUDO chown "$OWNER:$(owner_group)" "$path"
    fi
    conf="$conf
[$name]
   path = $path
   valid users = $OWNER
   read only = no
   force user = $OWNER
   create mask = 0644
   directory mask = 0755
"
done
printf '%s' "$conf" | run_write /etc/samba/homelab.conf 0644
# smb.conf itself: ours is one include. Debian's default also shares every
# user's home directory ([homes]) and printer drivers ([print$]); it is kept
# as smb.conf.debian, not deleted. A smb.conf someone else wrote is left
# alone apart from the include.
if ! $SUDO grep -qs '^include = /etc/samba/homelab.conf' /etc/samba/smb.conf; then
    if $SUDO grep -qs 'This is the main Samba configuration file' /etc/samba/smb.conf; then
        run $SUDO mv /etc/samba/smb.conf /etc/samba/smb.conf.debian
        printf '# Written by homelab; Debian'"'"'s default is smb.conf.debian.\ninclude = /etc/samba/homelab.conf\n' \
            | run_write /etc/samba/smb.conf 0644
    else
        run_sh "printf '\n# homelab shares\ninclude = /etc/samba/homelab.conf\n' | $SUDO tee -a /etc/samba/smb.conf >/dev/null"
    fi
fi
if is_apply; then
    $SUDO testparm -s /etc/samba/smb.conf >/dev/null 2>&1 || die "the samba config does not parse (testparm); see /etc/samba/homelab.conf"
fi
# nmbd (NetBIOS names) is not needed for \\ip\share and SMB2+; keep it off.
run $SUDO systemctl disable --now nmbd.service 2>/dev/null || true

# --- the owner's Samba password -------------------------------------------------
env_file="$APP_STATE/.env"
# Set a new one whenever we hold none: a fresh install, or a reinstall after
# --purge removed the .env while Samba's own user database kept the account.
if is_apply && ! $SUDO grep -qs '^SAMBA_PASSWORD=.' "$env_file"; then
    pass="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)"
    printf '%s\n%s\n' "$pass" "$pass" | $SUDO smbpasswd -s -a "$OWNER" >/dev/null
    printf 'SAMBA_USER=%s\nSAMBA_PASSWORD=%s\n' "$OWNER" "$pass" | $SUDO tee "$env_file" >/dev/null
    $SUDO chmod 0600 "$env_file"
    $SUDO chown "$OWNER:$(owner_group)" "$env_file"
    ok "samba user $OWNER created; password in $env_file"
fi
run $SUDO systemctl reload smbd.service 2>/dev/null || true
ok "samba: shares $(for s in $SHARES; do printf '%s ' "${s%%=*}"; done)"
