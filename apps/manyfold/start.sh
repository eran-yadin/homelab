#!/usr/bin/env bash
# Start, after making sure the library folder exists and belongs to the user
# Manyfold runs as (MANYFOLD_PUID). Docker creates a missing bind-mount source
# as root, and Manyfold then refuses it as a library ("must be writable") --
# and the samba share of the same folder cannot be written either. In
# Manyfold's own settings the folder is /models, not the host path.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"

env_file="$APP_STATE/.env"
dir="$($SUDO sed -n 's/^MODELS_DIR=//p' "$env_file" 2>/dev/null || true)"; dir="${dir:-/srv/3dmodels}"
uid="$($SUDO sed -n 's/^MANYFOLD_PUID=//p' "$env_file" 2>/dev/null || true)"; uid="${uid:-1000}"
gid="$($SUDO sed -n 's/^MANYFOLD_PGID=//p' "$env_file" 2>/dev/null || true)"; gid="${gid:-$uid}"
if ! [ -d "$dir" ]; then run $SUDO mkdir -p "$dir"; fi
if [ "$(stat -c %u "$dir" 2>/dev/null || echo "$uid")" != "$uid" ]; then
    log "manyfold: $dir is not owned by uid $uid; giving it to Manyfold's user so it can be a library"
    run $SUDO chown "$uid:$gid" "$dir"
fi
exec bash "$HOMELAB_ROOT/lib/kinds/compose.sh" start "$@"
