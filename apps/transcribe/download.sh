#!/usr/bin/env bash
# Wraps the inherited compose download to size the thread count to this box.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host

ensure_state_dir
env_file="$APP_STATE/.env"
if ! $SUDO test -f "$env_file"; then
    # Leave one core for everything else; never go below 1.
    threads=$(( DET_CPUS > 1 ? DET_CPUS - 1 : 1 ))
    log "sizing whisper to $threads threads ($DET_CPUS cores detected)"
    sed "s|@@CORES_MINUS_ONE@@|$threads|" "$APP_FILES/env.template" \
        | run_write "$env_file" 0600
    run $SUDO chown "$(owner_user):$(owner_group)" "$env_file"
fi

# hand off to the compose default for the actual pull/build
exec bash "$HOMELAB_ROOT/lib/kinds/compose.sh" download "$@"
