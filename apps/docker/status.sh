#!/usr/bin/env bash
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
set -euo pipefail
if ! have docker; then emit_status absent false; exit 0; fi
ver="$(docker --version 2>/dev/null | sed 's/^Docker version //; s/,.*//')"
if dk_resolve; then
    n="$("${DK[@]}" ps -q 2>/dev/null | grep -c . || true)"
    comp=none; "${DK[@]}" compose version >/dev/null 2>&1 && comp=plugin
    via=direct; [ "${DK[0]}" = "$SUDO" ] && [ -n "$SUDO" ] && via=sudo
    emit_status running true version="$ver" compose="$comp" containers_running="$n" via="$via"
else
    emit_status stopped true version="$ver" detail="$(dk_reason)"
fi
