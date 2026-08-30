# shellcheck shell=bash
# Host detection. Read-only: safe to run anywhere, changes nothing.

detect_host() {
    # --- os -------------------------------------------------------------
    DET_OS_ID=unknown; DET_OS_VER=; DET_OS_NAME=unknown; DET_FAMILY=unknown
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DET_OS_ID="${ID:-unknown}"
        DET_OS_VER="${VERSION_ID:-}"
        DET_OS_NAME="${PRETTY_NAME:-$DET_OS_ID}"
        case " ${ID:-} ${ID_LIKE:-} " in
            *" debian "*|*" ubuntu "*) DET_FAMILY=debian ;;
            *" rhel "*|*" fedora "*|*" centos "*) DET_FAMILY=rhel ;;
            *" arch "*) DET_FAMILY=arch ;;
        esac
    fi

    case "$DET_FAMILY" in
        debian) DET_PKG=apt ;;
        rhel)   DET_PKG=$(have dnf && echo dnf || echo yum) ;;
        arch)   DET_PKG=pacman ;;
        *)      DET_PKG=none ;;
    esac

    # --- hardware -------------------------------------------------------
    DET_ARCH="$(uname -m)"
    DET_KERNEL="$(uname -r)"
    DET_CPUS="$(nproc 2>/dev/null || echo 1)"
    DET_RAM_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
    DET_DISK_FREE_MB="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
    DET_VIRT="$(systemd-detect-virt 2>/dev/null || echo unknown)"

    # --- gpu ------------------------------------------------------------
    DET_GPU=none
    if [ -e /dev/dri/renderD128 ]; then DET_GPU=intel-quicksync; fi
    if have lspci && lspci 2>/dev/null | grep -qi 'vga.*nvidia\|3d.*nvidia'; then
        DET_GPU="${DET_GPU/none/}nvidia"
    fi
    [ -z "$DET_GPU" ] && DET_GPU=none

    # --- privilege / network -------------------------------------------
    if [ "$(id -u)" -eq 0 ]; then DET_ROOT=yes
    elif sudo -n true 2>/dev/null; then DET_ROOT=sudo-nopasswd
    elif have sudo; then DET_ROOT=sudo-password
    else DET_ROOT=no; fi

    DET_GATEWAY="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
    DET_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"

    DET_INIT=none
    [ -d /run/systemd/system ] && DET_INIT=systemd

    # --- container runtime ---------------------------------------------
    DET_DOCKER=absent
    if have docker; then
        if docker info >/dev/null 2>&1; then DET_DOCKER=running
        elif [ -n "$SUDO" ] && $SUDO -n docker info >/dev/null 2>&1; then DET_DOCKER="running (via sudo)"
        else DET_DOCKER=installed; fi
    fi
    DET_COMPOSE=absent
    if have docker && docker compose version >/dev/null 2>&1; then
        DET_COMPOSE=plugin
    elif have docker-compose; then
        DET_COMPOSE=standalone
    fi

    # --- mesh -----------------------------------------------------------
    DET_MESH=none
    have tailscale && DET_MESH=tailscale
    have headscale && DET_MESH="${DET_MESH/none/}headscale"
    [ -z "$DET_MESH" ] && DET_MESH=none

    DET_TESTENV=no
    [ -f "$HOMELAB_ETC/testenv" ] && DET_TESTENV=yes
    DET_APPLY_ALLOWED=no
    [ -f "$HOMELAB_APPLY_MARKER" ] && DET_APPLY_ALLOWED=yes
}

detect_print() {
    detect_host
    printf '%shost%s\n' "$C_B" "$C_RST"
    printf '  os          %s (%s / family %s / pkg %s)\n' "$DET_OS_NAME" "$DET_OS_ID" "$DET_FAMILY" "$DET_PKG"
    printf '  kernel      %s  %s\n' "$DET_KERNEL" "$DET_ARCH"
    printf '  init        %s\n' "$DET_INIT"
    printf '  virt        %s\n' "$DET_VIRT"
    printf '\n%sresources%s\n' "$C_B" "$C_RST"
    printf '  cpus        %s\n' "$DET_CPUS"
    printf '  ram         %s MB\n' "$DET_RAM_MB"
    printf '  disk free   %s MB (on /)\n' "$DET_DISK_FREE_MB"
    printf '  gpu         %s\n' "$DET_GPU"
    printf '\n%sruntime%s\n' "$C_B" "$C_RST"
    printf '  docker      %s\n' "$DET_DOCKER"
    printf '  compose     %s\n' "$DET_COMPOSE"
    printf '  mesh        %s\n' "$DET_MESH"
    printf '\n%saccess%s\n' "$C_B" "$C_RST"
    printf '  privilege   %s\n' "$DET_ROOT"
    printf '  ip          %s   gateway %s\n' "${DET_IP:-?}" "${DET_GATEWAY:-?}"
    printf '  test env    %s\n' "$DET_TESTENV"
    if [ "$DET_APPLY_ALLOWED" = yes ]; then
        printf '  --apply     %sallowed%s (marker present)\n' "$C_GRN" "$C_RST"
    else
        printf '  --apply     %sblocked%s (no %s)\n' "$C_YEL" "$C_RST" "$HOMELAB_APPLY_MARKER"
    fi
}

detect_json() {
    detect_host
    printf '{'
    printf '"os_id":"%s","os_version":"%s","os_name":"%s","family":"%s","pkg":"%s",' \
        "$DET_OS_ID" "$DET_OS_VER" "$(json_escape "$DET_OS_NAME")" "$DET_FAMILY" "$DET_PKG"
    printf '"arch":"%s","kernel":"%s","init":"%s","virt":"%s",' \
        "$DET_ARCH" "$DET_KERNEL" "$DET_INIT" "$DET_VIRT"
    printf '"cpus":%s,"ram_mb":%s,"disk_free_mb":%s,"gpu":"%s",' \
        "$DET_CPUS" "$DET_RAM_MB" "${DET_DISK_FREE_MB:-0}" "$DET_GPU"
    printf '"docker":"%s","compose":"%s","mesh":"%s",' \
        "$DET_DOCKER" "$DET_COMPOSE" "$DET_MESH"
    printf '"privilege":"%s","ip":"%s","gateway":"%s",' \
        "$DET_ROOT" "${DET_IP:-}" "${DET_GATEWAY:-}"
    printf '"testenv":"%s","apply_allowed":"%s"' "$DET_TESTENV" "$DET_APPLY_ALLOWED"
    printf '}\n'
}
