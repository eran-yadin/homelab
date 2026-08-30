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
    unit=""; backup_paths=""; purge_paths=""; purge_users=""

    # shellcheck disable=SC1090
    . "$APP_DIR/app.conf"

    APP_KIND="$kind"; APP_TITLE="$title"; APP_CATEGORY="$category"
    APP_DESC="$desc"; APP_PORTS="$ports"; APP_RAM="$needs_ram_mb"
    APP_DISK="$needs_disk_mb"; APP_STATEFUL="$stateful"
    APP_DETECT="$detect"; APP_REQUIRES="$requires"
    APP_HOMEPAGE="$homepage"; APP_NOTES="$notes"
    APP_UNIT="$unit"; APP_BACKUP_PATHS="$backup_paths"; APP_PURGE_PATHS="$purge_paths"
    APP_PURGE_USERS="$purge_users"
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

app_run_verb() {
    local name="$1" verb="$2"; shift 2
    app_load "$name"
    app_verb_impl "$name" "$verb" \
        || die "app '$name' (kind=$APP_KIND) has no implementation for '$verb'"
    dbg "dispatch $name/$verb -> $IMPL $IMPL_ARG"
    HOMELAB_ROOT="$HOMELAB_ROOT" HOMELAB_APPLY="${HOMELAB_APPLY:-0}" \
    HOMELAB_DEBUG="${HOMELAB_DEBUG:-0}" \
    APP_NAME="$APP_NAME" APP_DIR="$APP_DIR" APP_STATE="$APP_STATE" \
    APP_KIND="$APP_KIND" APP_TITLE="$APP_TITLE" APP_PORTS="$APP_PORTS" \
    APP_STATEFUL="$APP_STATEFUL" APP_UNIT="$APP_UNIT" \
    APP_BACKUP_PATHS="$APP_BACKUP_PATHS" APP_PURGE_PATHS="$APP_PURGE_PATHS" \
    APP_PURGE_USERS="$APP_PURGE_USERS" \
        bash "$IMPL" $IMPL_ARG "$@"
}
