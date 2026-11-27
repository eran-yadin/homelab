# shellcheck shell=bash
# The catalog is just the apps/ directory. No registry, no index file.

catalog_names() {
    local d
    for d in "$HOMELAB_APPS"/*/; do
        [ -f "$d/app.conf" ] || continue
        basename "$d"
    done | sort
}

catalog_exists() { [ -f "$HOMELAB_APPS/$1/app.conf" ]; }

# Load apps/<name>/app.conf into APP_* variables.
app_load() {
    local name="$1"
    catalog_exists "$name" || die "no such app: $name  (try: homelab list)"

    APP_NAME="$name"
    APP_DIR="$HOMELAB_APPS/$name"
    APP_STATE="$(app_state_dir "$name")"

    # defaults, so app.conf only declares what differs
    kind=compose; title="$name"; category=misc; desc=""
    ports=""; needs_ram_mb=0; needs_disk_mb=0; stateful=0
    detect=""; requires=""; homepage=""; notes=""
    unit=""; extra_units=""; backup_paths=""; purge_paths=""; purge_users=""; oneshot=""; health_url=""
    conflicts=""; adopted=0; container=""; bulk_volumes=""; cache_volumes=""; nightly=1

    # shellcheck disable=SC1090
    . "$APP_DIR/app.conf"

    APP_KIND="$kind"; APP_TITLE="$title"; APP_CATEGORY="$category"
    APP_DESC="$desc"; APP_PORTS="$ports"; APP_RAM="$needs_ram_mb"
    APP_DISK="$needs_disk_mb"; APP_STATEFUL="$stateful"
    APP_DETECT="$detect"; APP_REQUIRES="$requires"
    APP_HOMEPAGE="$homepage"; APP_NOTES="$notes"
    APP_UNIT="$unit"; APP_EXTRA_UNITS="$extra_units"; APP_BACKUP_PATHS="$backup_paths"; APP_PURGE_PATHS="$purge_paths"
    APP_PURGE_USERS="$purge_users"; APP_ONESHOT="$oneshot"; APP_HEALTH_URL="$health_url"
    APP_CONFLICTS="$conflicts"; APP_ADOPTED="$adopted"; APP_CONTAINER="$container"
    APP_BULK_VOLUMES="$bulk_volumes"; APP_CACHE_VOLUMES="$cache_volumes"; APP_NIGHTLY="$nightly"
}

# ---------------------------------------------------------------- probes
#
# "Is this already here?" answered without running any app code, so `list` is
# fast and safe on a machine we know nothing about.
#
#   container:<name>   a docker container by that name exists
#   unit:<name>        a systemd unit is enabled or active
#   bin:<name>         a binary is on PATH
#   path:<abs>         a file or directory exists
#   port:<n>           something is listening on that port

probe_one() {
    local spec="$1" kind="${1%%:*}" val="${1#*:}"
    case "$kind" in
        container) have docker && docker ps -a --format '{{.Names}}' 2>/dev/null \
                       | grep -qx "$val" ;;
        unit)      have systemctl && { systemctl is-active --quiet "$val" 2>/dev/null \
                       || systemctl is-enabled --quiet "$val" 2>/dev/null; } ;;
        bin)       have "$val" ;;
        path)      [ -e "$val" ] ;;
        port)      { have ss && ss -tlnH 2>/dev/null | grep -qE "[:.]${val}\b"; } ;;
        *)         return 1 ;;
    esac
}

# installed | partial | absent
app_probe() {
    local spec total=0 hit=0
    for spec in $APP_DETECT; do
        total=$((total+1))
        probe_one "$spec" && hit=$((hit+1))
    done
    if   [ "$total" -eq 0 ]; then echo unknown
    elif [ "$hit" -eq 0 ];   then echo absent
    elif [ "$hit" -eq "$total" ]; then echo installed
    else echo partial; fi
}

# ---------------------------------------------------------------- dispatch
#
# An app may implement a verb itself; otherwise it inherits the default for its
# kind. This is what lets most apps ship only an app.conf and a compose file.

app_verb_impl() {  # -> path of script, and sets VERB_ARGV
    local name="$1" verb="$2"
    if [ -x "$HOMELAB_APPS/$name/$verb.sh" ]; then
        IMPL="$HOMELAB_APPS/$name/$verb.sh"; IMPL_ARG=""
    elif [ -f "$HOMELAB_LIB/kinds/$APP_KIND.sh" ]; then
        IMPL="$HOMELAB_LIB/kinds/$APP_KIND.sh"; IMPL_ARG="$verb"
    else
        return 1
    fi
}

# One command per app at a time. Two `docker compose up` for the same project
# race for the same container names: on nucserver a hub Install of manyfold
# was still pulling when Start was pressed, and the install died on "container
# name already in use". The nightly backup must not pause an app mid-install
# either. So every verb that can change an app holds a per-app lock; a second
# one waits for the first (and then usually finds nothing left to do). Only
# with --apply: a dry run changes nothing and status is read-only.
HOMELAB_LOCKS="${HOMELAB_LOCKS:-/run/homelab/locks}"
HOMELAB_LOCK_WAIT="${HOMELAB_LOCK_WAIT:-900}"

_lock_needed() {  # _lock_needed <verb>
    [ "${HOMELAB_APPLY:-0}" = 1 ] || return 1
    case "$1" in status) return 1 ;; esac
    have flock || return 1
    return 0
}

app_run_verb() {
    local name="$1" verb="$2"; shift 2
    app_load "$name"
    app_verb_impl "$name" "$verb" \
        || die "app '$name' (kind=$APP_KIND) has no implementation for '$verb'"
    if _lock_needed "$verb"; then
        local lock="$HOMELAB_LOCKS/$name.lock" rc errexit=0
        case "$-" in *e*) errexit=1 ;; esac
        $SUDO mkdir -p "$HOMELAB_LOCKS" 2>/dev/null || true
        set +e
        (
            exec 9>>"$lock" || { warn "$name: cannot open $lock, running without a lock"; exec 9>/dev/null; }
            if ! flock -n 9; then
                log "$name is busy: $(cat "$lock.who" 2>/dev/null || echo 'another command'). waiting (up to ${HOMELAB_LOCK_WAIT}s)"
                flock -w "$HOMELAB_LOCK_WAIT" 9 || die "$name is still busy after ${HOMELAB_LOCK_WAIT}s: $(cat "$lock.who" 2>/dev/null || echo 'another command'). try again later"
            fi
            printf '%s since %s (pid %s)\n' "$verb" "$(date +%H:%M:%S)" "$$" > "$lock.who" 2>/dev/null || true
            _app_exec_verb "$verb" "$@"
        )
        rc=$?
        # Put errexit back the way the caller had it. Callers turn it off to
        # read a verb's exit code (2 = nothing to do); forcing it back on
        # here would make that 2 kill them.
        if [ "$errexit" = 1 ]; then set -e; fi
        return $rc
    fi
    _app_exec_verb "$verb" "$@"
}

_app_exec_verb() {
    local verb="$1"; shift
    dbg "dispatch $APP_NAME/$verb -> $IMPL $IMPL_ARG"
    HOMELAB_ROOT="$HOMELAB_ROOT" HOMELAB_APPLY="${HOMELAB_APPLY:-0}" \
    HOMELAB_DEBUG="${HOMELAB_DEBUG:-0}" \
    APP_NAME="$APP_NAME" APP_DIR="$APP_DIR" APP_STATE="$APP_STATE" \
    APP_KIND="$APP_KIND" APP_TITLE="$APP_TITLE" APP_PORTS="$APP_PORTS" \
    APP_STATEFUL="$APP_STATEFUL" APP_UNIT="$APP_UNIT" APP_EXTRA_UNITS="$APP_EXTRA_UNITS" \
    APP_BACKUP_PATHS="$APP_BACKUP_PATHS" APP_PURGE_PATHS="$APP_PURGE_PATHS" \
    APP_PURGE_USERS="$APP_PURGE_USERS" APP_ONESHOT="$APP_ONESHOT" APP_HEALTH_URL="$APP_HEALTH_URL" \
    APP_CONFLICTS="$APP_CONFLICTS" APP_ADOPTED="$APP_ADOPTED" \
    APP_CONTAINER="$APP_CONTAINER" APP_BULK_VOLUMES="$APP_BULK_VOLUMES" \
    APP_CACHE_VOLUMES="$APP_CACHE_VOLUMES" HOMELAB_BACKUP_SKIP_CACHE="${HOMELAB_BACKUP_SKIP_CACHE:-0}" \
    HOMELAB_YES="${HOMELAB_YES:-0}" \
        bash "$IMPL" $IMPL_ARG "$@"
}
