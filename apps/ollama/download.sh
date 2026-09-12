#!/usr/bin/env bash
# Whether ollama is worth running comes down to the GPU, and everything about
# that is knowable before installing. Say it now, not after the first prompt
# takes ninety seconds.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host
ensure_state_dir

override="$APP_STATE/compose.override.yml"
gpu_enabled=0

case "$DET_GPU" in
    *nvidia*)
        if [ "${DET_NVIDIA_RUNTIME:-no}" = yes ]; then
            ok "NVIDIA GPU with the container toolkit: ${DET_GPU_NAME:-unknown}"
            cat <<'YML' | run_write "$override" 0644
# Generated at install time: this host has an NVIDIA GPU and docker can reach it.
services:
  ollama:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
YML
            gpu_enabled=1
        else
            warn "an NVIDIA GPU is present (${DET_GPU_NAME:-unknown}) but docker cannot use it."
            warn "  The driver alone is not enough -- docker needs the NVIDIA container"
            warn "  toolkit to pass a GPU into a container. Until then this runs on CPU."
            warn "  Install it, then re-run: homelab install ollama --apply"
            warn "      https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/"
            if [ -f "$override" ]; then run $SUDO rm -f "$override"; fi
        fi
        ;;
    *)
        if [ -f "$override" ]; then run $SUDO rm -f "$override"; fi
        warn "no NVIDIA GPU on this host - ollama will run on the CPU."
        if [ "${DET_CPUS:-0}" -le 2 ]; then
            warn "  With ${DET_CPUS} cores, a 7B model answers at roughly a word per"
            warn "  second. Usable for a batch job overnight; not for a conversation."
        fi
        ;;
esac

# VRAM is what decides which models fit, and it is worth being concrete.
if [ "$gpu_enabled" = 1 ] && [ "${DET_VRAM_MB:-0}" -gt 0 ]; then
    v="$DET_VRAM_MB"
    log "${v} MB of VRAM. Roughly what fits, at 4-bit quantisation:"
    if   [ "$v" -lt 4096 ];  then log "   1B-3B models. Anything larger will spill to system RAM and crawl."
    elif [ "$v" -lt 9000 ];  then log "   up to 8B (about 5 GB). A 13B will not fit alongside anything else."
    elif [ "$v" -lt 17000 ]; then log "   8B comfortably, 13B-14B with little headroom."
    else                          log "   13B-14B comfortably, and 30B-class models quantised."
    fi
    if [ "$v" -le 8192 ]; then
        warn "  On ${v} MB, nothing else GPU-heavy can be resident at the same time."
        warn "  OLLAMA_KEEP_ALIVE is set to 5m so the VRAM is released between uses."
    fi
fi

# Weights are the real disk cost and they accumulate quietly.
free_mb="$(df -Pm /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "$free_mb" ]; then
    log "${free_mb} MB free where docker keeps its data; one 8B model is about 5 GB"
fi

render_env
exec bash "$HOMELAB_ROOT/lib/kinds/compose.sh" download "$@"
