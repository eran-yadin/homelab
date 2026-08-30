# shellcheck shell=bash
# Sourced at the top of every app script and every kind default.
#
# The contract:
#   verbs     download start stop update delete status  (+ backup restore)
#   exit      0 = did it   2 = already in that state, nothing to do   * = failed
#   status    prints exactly one line of JSON on stdout, nothing else
#   changes   only ever through run() / run_sh() / run_write()
#   idempotent: running any verb twice must be safe

# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/common.sh"

: "${APP_NAME:?contract.sh sourced outside an app context}"
: "${APP_DIR:?}"
: "${APP_STATE:?}"

APP_FILES="$APP_DIR/files"

ensure_state_dir() {
    if [ -d "$APP_STATE" ]; then return 0; fi
    run $SUDO mkdir -p "$APP_STATE"
    # Owned by whoever drives the CLI, not root: `docker compose --env-file`
    # reads .env as the calling user, so a root-owned 0600 file is unreadable
    # to it and compose silently falls back to empty values.
    run $SUDO chown "$(id -u):$(id -g)" "$APP_STATE"
    run $SUDO chmod 0700 "$APP_STATE"
}

# One JSON line. This is the hub's entire parsing surface, so keep it stable.
emit_status() {  # emit_status <state> <installed:true|false> [k=v ...]
    local state="$1" installed="$2"; shift 2
    local extra="" kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        # Emit bare only for real JSON literals. A glob like [0-9]* also
        # matches "3/3", which produces invalid JSON that every consumer then
        # fails to parse.
        if [ "$v" = true ] || [ "$v" = false ]; then
            extra+=",\"$k\":$v"
        elif [ -n "$v" ] && [ -z "${v//[0-9]/}" ]; then
            extra+=",\"$k\":$v"
        else
            extra+=",\"$k\":\"$(json_escape "$v")\""
        fi
    done
    printf '{"app":"%s","kind":"%s","state":"%s","installed":%s%s}\n' \
        "$APP_NAME" "${APP_KIND:-unknown}" "$state" "$installed" "$extra"
}

# N random alphanumeric characters.
#
# Deliberately NOT `tr -dc ... </dev/urandom | head -c N`: head exits as soon as
# it has N bytes, tr is killed by SIGPIPE, and with `set -o pipefail` the whole
# pipeline returns 141 -- which under `set -e` aborts the script silently, with
# no error message at all. Reading a bounded chunk instead means nothing ever
# gets a broken pipe.
gen_secret() {
    local n="$1" s=""
    while [ "${#s}" -lt "$n" ]; do
        s+="$(head -c $((n * 8)) /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' || true)"
    done
    printf '%s' "${s:0:n}"
}

# Render files/env.template -> $APP_STATE/.env, generating secrets ONCE.
# Never overwritten, so an update cannot rotate a password out from under a
# running database.
render_env() {
    local tpl="$APP_FILES/env.template" out="$APP_STATE/.env"
    [ -f "$tpl" ] || return 0
    if $SUDO test -f "$out"; then
        dbg "env already rendered: $out"
        return 0
    fi
    local content; content="$(cat "$tpl")"
    # @@SECRET:N@@ -> N random alphanumeric characters
    while [[ "$content" =~ @@SECRET:([0-9]+)@@ ]]; do
        local n="${BASH_REMATCH[1]}" s
        s="$(gen_secret "$n")"
        content="${content/@@SECRET:$n@@/$s}"
    done
    log "generating $out (secrets are created once and kept)"
    printf '%s\n' "$content" | run_write "$out" 0600
    run $SUDO chown "$(id -u):$(id -g)" "$out"
}

compose_env_file() { printf '%s/.env' "$APP_STATE"; }
