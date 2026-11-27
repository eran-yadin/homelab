#!/usr/bin/env bash
# smbd's unit stays on the box with the samba package after `delete`, so the
# app counts as installed only while its share config exists.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
if ! [ -f /etc/samba/homelab.conf ]; then emit_status absent false; exit 0; fi
exec bash "$HOMELAB_ROOT/lib/kinds/systemd.sh" status
