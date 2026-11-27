#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$APP_DIR/rollback.sh"
set +e; bash "$HOMELAB_ROOT/lib/kinds/systemd.sh" start; rc=$?; set -e
if [ "$rc" = 0 ]; then arm_rollback; fi
exit "$rc"
