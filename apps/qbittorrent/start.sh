#!/usr/bin/env bash
# Start, after making sure the downloads folder exists inside the media folder
# and belongs to the owner (docker would create a missing one as root).
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
media="$($SUDO sed -n 's/^MEDIA_DIR=//p' "$APP_STATE/.env" 2>/dev/null || true)"; media="${media:-/srv/media}"
for d in "$media" "$media/downloads"; do
    if ! [ -d "$d" ]; then
        run $SUDO mkdir -p "$d"
        run $SUDO chown "$(owner_user):$(owner_group)" "$d"
    fi
done
exec bash "$HOMELAB_ROOT/lib/kinds/compose.sh" start "$@"
