# shellcheck shell=bash
# Shared helpers. Sourced by the CLI and by every app script.

set -o pipefail

# ---------------------------------------------------------------- output

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RST=$'\033[0m'; C_DIM=$'\033[2m';  C_B=$'\033[1m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
else
    C_RST=; C_DIM=; C_B=; C_RED=; C_GRN=; C_YEL=; C_BLU=
fi

log()  { printf '%s==>%s %s\n'   "$C_BLU" "$C_RST" "$*" >&2; }
ok()   { printf '%s  ok%s %s\n'  "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%swarn%s %s\n'  "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s err%s %s\n'  "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }
dbg()  { [ "${HOMELAB_DEBUG:-0}" = 1 ] && printf '%s dbg%s %s\n' "$C_DIM" "$C_RST" "$*" >&2 || true; }

# Exit codes that the contract assigns meaning to.
readonly EX_OK=0        # did the thing
readonly EX_NOOP=2      # already in the desired state, nothing to do
readonly EX_CONFIRM=3   # stopped before changing anything: needs --yes (or a person at a tty)

# ---------------------------------------------------------------- paths

# Works both from a git checkout and from /opt/homelab.
HOMELAB_ROOT="${HOMELAB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOMELAB_APPS="$HOMELAB_ROOT/apps"
HOMELAB_LIB="$HOMELAB_ROOT/lib"
HOMELAB_DATA="${HOMELAB_DATA:-/var/lib/homelab}"
HOMELAB_ETC="${HOMELAB_ETC:-/etc/homelab}"
HOMELAB_APPLY_MARKER="$HOMELAB_ETC/allow-apply"

app_state_dir() { printf '%s/apps/%s' "$HOMELAB_DATA" "$1"; }

# ---------------------------------------------------------------- privilege

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# Who should own the files we create? When the hub runs us as
# `sudo homelab ...`, id -u is 0, and chowning state to root would make the
# generated .env unreadable to the human who later runs the CLI directly --
# and to `docker compose`, which reads it as the calling user.
owner_user()  { printf '%s' "${SUDO_USER:-$(id -un)}"; }
owner_group() { id -gn "$(owner_user)" 2>/dev/null || printf '%s' "$(owner_user)"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------- the dry-run gate
#
# Nothing in this project calls docker/systemctl/apt directly. Everything goes
# through run(), so --dry-run is a property of the engine rather than something
# each app script has to remember to honour.

_shq() {  # shell-quote args for display
    local out= a
    for a in "$@"; do
        case "$a" in
            *[!A-Za-z0-9_/.:=@%+-]*) out+=" '${a//\'/\'\\\'\'}'" ;;
            *) out+=" $a" ;;
        esac
    done
    printf '%s' "${out# }"
}

run() {
    if [ "${HOMELAB_APPLY:-0}" = 1 ]; then
        dbg "run: $(_shq "$@")"
        "$@"
    else
        printf '%s     would run:%s %s\n' "$C_DIM" "$C_RST" "$(_shq "$@")" >&2
        return 0
    fi
}

# Same gate, but for a shell snippet (pipes, redirection).
run_sh() {
    if [ "${HOMELAB_APPLY:-0}" = 1 ]; then
        dbg "run_sh: $1"
        bash -c "$1"
    else
        printf '%s     would run:%s %s\n' "$C_DIM" "$C_RST" "$1" >&2
        return 0
    fi
}

# Write a file through the gate.
run_write() {  # run_write <path> <mode>  (content on stdin)
    local path="$1" mode="${2:-0644}" content
    content="$(cat)"
    if [ "${HOMELAB_APPLY:-0}" = 1 ]; then
        $SUDO mkdir -p "$(dirname "$path")"
        printf '%s\n' "$content" | $SUDO tee "$path" >/dev/null
        $SUDO chmod "$mode" "$path"
    else
        printf '%s     would write:%s %s (%s, %d lines)\n' \
            "$C_DIM" "$C_RST" "$path" "$mode" "$(printf '%s\n' "$content" | wc -l)" >&2
    fi
}

# --apply is refused unless the host is explicitly marked as a machine we are
# allowed to change. The test VM has this; a random production box does not.
require_apply_allowed() {
    [ "${HOMELAB_APPLY:-0}" = 1 ] || return 0
    [ -f "$HOMELAB_APPLY_MARKER" ] && return 0
    err "refusing --apply: $HOMELAB_APPLY_MARKER does not exist."
    err ""
    err "This guard exists so an --apply typed in the wrong terminal cannot"
    err "change a machine that never opted in. To allow this host:"
    err "    sudo mkdir -p $HOMELAB_ETC && echo yes | sudo tee $HOMELAB_APPLY_MARKER"
    exit 1
}

is_apply() { [ "${HOMELAB_APPLY:-0}" = 1 ]; }

# ---------------------------------------------------------------- docker access
#
# `usermod -aG docker` does not affect an already-running shell, so immediately
# after installing docker the current process still cannot reach the socket.
# Falling back to sudo keeps a fresh install working end to end instead of
# failing halfway with a confusing error.

DK=()
dk_resolve() {
    DK=()
    have docker || return 1
    if docker info >/dev/null 2>&1; then DK=(docker); return 0; fi
    if [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then DK=($SUDO docker); return 0; fi
    return 1
}

# Why can't we talk to it? Used for error messages that actually help.
dk_reason() {
    if ! have docker; then
        echo "docker is not installed"
    elif have systemctl && ! systemctl is-active --quiet docker 2>/dev/null; then
        echo "the docker daemon is installed but not running"
    else
        echo "cannot reach the docker socket - you were just added to the 'docker' group, which needs a new login session"
    fi
}

# ---------------------------------------------------------------- json

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"
    printf '%s' "$s"
}
