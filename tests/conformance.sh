#!/usr/bin/env bash
# Contract conformance suite.
#
# Drives every app through its full lifecycle and asserts the rules that let
# the hub treat all apps identically:
#
#   * every verb is idempotent (running it twice is safe; the second run
#     reports EX_NOOP=2 rather than failing or doing the work again)
#   * `status` prints exactly ONE line of valid JSON, with the required keys
#   * the reported state matches what actually just happened
#   * a dry run changes nothing
#
# DESTRUCTIVE: it ends by purging each app. Refuses to run outside the test VM.

set -uo pipefail
cd "$(dirname "$0")/.."
HL=./homelab

if [ ! -f /etc/homelab/testenv ]; then
    echo "refusing to run: this is not the homelab test VM (/etc/homelab/testenv missing)" >&2
    echo "the suite purges every app it touches." >&2
    exit 1
fi

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; Z=$'\033[0m'
else G=; R=; Y=; D=; Z=; fi

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()

pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$Z" "$1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  %sFAIL%s %s\n' "$R" "$Z" "$1"
         [ $# -gt 1 ] && printf '       %s%s%s\n' "$D" "$2" "$Z"; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s %s\n' "$Y" "$Z" "$1"; }

# Run a verb; leaves its exit code in $RC and its output in $OUT.
# Deliberately NOT `rc="$(verb ...)"`: command substitution runs in a subshell,
# so anything the function assigns is lost the moment it returns.
RC=0; OUT=""
verb() {
    local app="$1" v="$2"; shift 2
    set +e
    OUT="$("$HL" "$v" "$app" "$@" --apply 2>&1)"
    RC=$?
    set -e
}

# assert the verb succeeded or was a legitimate no-op
expect_ok() {  # expect_ok <label>
    if [ "$RC" = 0 ] || [ "$RC" = 2 ]; then pass "$1 rc=$RC"
    else fail "$1 rc=$RC" "$(printf '%s' "$OUT" | tail -3)"; fi
}

# assert the verb reported "nothing to do"
expect_noop() {  # expect_noop <label>
    if [ "$RC" = 2 ]; then pass "$1 is idempotent (rc=2)"
    elif [ "$RC" = 0 ]; then fail "$1 re-ran instead of reporting no-op (rc=0)" "$(printf '%s' "$OUT" | tail -3)"
    else fail "$1 rc=$RC on second run" "$(printf '%s' "$OUT" | tail -3)"; fi
}

status_json() { "$HL" status "$1" --json 2>/dev/null; }

assert_json() {  # assert_json <label> <json> <expected-state-regex>
    local label="$1" json="$2" want="$3"
    local n; n="$(printf '%s\n' "$json" | grep -c . )"
    if [ "$n" -ne 1 ]; then
        fail "$label: status must be exactly one line, got $n"; return
    fi
    if ! printf '%s' "$json" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
        fail "$label: status is not valid JSON" "$json"; return
    fi
    local missing
    missing="$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
print(" ".join(k for k in ("app","kind","state","installed") if k not in d))')"
    if [ -n "$missing" ]; then
        fail "$label: status missing required keys: $missing" "$json"; return
    fi
    local st; st="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["state"])')"
    if [[ "$st" =~ $want ]]; then
        pass "$label: state=$st"
    else
        fail "$label: state=$st, expected to match /$want/" "$json"
    fi
}

test_app() {
    local app="$1"
    printf '\n%s=== %s ===%s\n' "$D" "$app" "$Z"

    # --- dry run must change nothing -----------------------------------
    local before after
    before="$(status_json "$app")"
    "$HL" install "$app" >/dev/null 2>&1
    after="$(status_json "$app")"
    if [ "$before" = "$after" ]; then pass "dry run changed nothing"
    else fail "dry run changed state" "before=$before after=$after"; fi

    # --- download -------------------------------------------------------
    verb "$app" download;              expect_ok "download"

    # --- start ----------------------------------------------------------
    verb "$app" start;                 expect_ok "start"
    sleep 3
    assert_json "after start" "$(status_json "$app")" '^(running|degraded)$'

    # --- start again must be a no-op ------------------------------------
    verb "$app" start;                 expect_noop "start"

    # --- stop -----------------------------------------------------------
    verb "$app" stop;                  expect_ok "stop"
    assert_json "after stop" "$(status_json "$app")" '^(stopped|absent|downloaded)$'

    # --- stop again must be a no-op -------------------------------------
    verb "$app" stop;                  expect_noop "stop"

    # --- restart + update ------------------------------------------------
    verb "$app" start;                 expect_ok "restart"
    verb "$app" update;                expect_ok "update"

    # --- delete --purge --------------------------------------------------
    if [ "$app" = docker ]; then
        skip "delete: refusing to uninstall docker mid-suite (other apps need it)"
        return 0
    fi
    set +e
    OUT="$(printf '%s\n' "$app" | "$HL" delete "$app" --purge --apply 2>&1)"; RC=$?
    set -e
    expect_ok "delete --purge"
    assert_json "after purge" "$(status_json "$app")" '^(absent|downloaded)$'

    # --- delete again must be a no-op ------------------------------------
    verb "$app" delete;                expect_noop "delete"
}

# --- per-host override regression -------------------------------------------
# Reproduces the v1.2.1 bug (now guarded by the single-source-of-truth refactor
# in lib/kinds/compose.sh). The test VM has no /dev/dri, so no app generates a
# compose.override.yml here -- which is exactly why the original suite never
# caught it. Synthesize a harmless override (bind /dev/null, present on every
# host) to recreate the base+override shape, then assert the app starts AND
# that starting it again is a no-op, not the false "different compose file"
# refusal.
OVERRIDE_APPS="stremio-server:stremio-server jellyfin:jellyfin"   # app:service

_dk() { if docker info >/dev/null 2>&1; then docker "$@"; else sudo docker "$@"; fi; }

test_override_restart() {
    local app="$1" svc="$2" state="/var/lib/homelab/apps/$1"
    printf '\n%s=== %s (override restart guard) ===%s\n' "$D" "$app" "$Z"

    verb "$app" download;              expect_ok "override: download"

    sudo mkdir -p "$state"
    printf 'services:\n  %s:\n    devices:\n      - /dev/null:/dev/null\n' "$svc" \
        | sudo tee "$state/compose.override.yml" >/dev/null

    verb "$app" start;                 expect_ok "override: start with override present"
    sleep 3

    local cf
    cf="$(_dk ps -a --filter "label=com.docker.compose.project=$app" \
        --format '{{.Label "com.docker.compose.project.config_files"}}' | head -1)"
    if printf '%s' "$cf" | grep -q 'compose\.override\.yml'; then
        pass "override: container built from base+override"
    else
        fail "override: container did not include the override" "$cf"
    fi

    verb "$app" start;                 expect_noop "override: start again (the v1.2.1 regression)"

    printf '%s\n' "$app" | "$HL" delete "$app" --purge --apply >/dev/null 2>&1 || true
    sudo rm -f "$state/compose.override.yml"
}

# A container records the ABSOLUTE paths it was created from. The real
# deployment creates them from ~/homelab (what `deploy --from` ships) and then
# manages them from /opt/homelab, so those paths never match on the NUC even
# though the files are byte-identical. Before v1.2.3 the guard compared the
# recorded path string and refused every restart afterwards.
#
# Reproduce it honestly: start the app from here, copy the whole engine to a
# second root, and drive the SAME app from there. Nothing about the app
# changed, so the second root must see a no-op, not a refusal.
test_moved_root_restart() {
    local app="$1" moved="$HOME/homelab-moved"
    printf '\n%s=== %s (restart from a second engine root) ===%s\n' "$D" "$app" "$Z"

    verb "$app" download;              expect_ok "moved: download"
    verb "$app" start;                 expect_ok "moved: start from the original root"
    sleep 3

    rm -rf "$moved"
    cp -a "$PWD" "$moved"

    local rc out
    set +e
    out="$(cd "$moved" && ./homelab start "$app" --apply 2>&1)"
    rc=$?
    set -e
    case "$rc" in
        2) pass "moved: start from the second root is a no-op (rc=2)" ;;
        0) fail "moved: second root recreated the containers instead of no-op (rc=0)" \
                "$(printf '%s' "$out" | tail -3)" ;;
        *) fail "moved: second root refused the app it already owns (rc=$rc)" \
                "$(printf '%s' "$out" | tail -4)" ;;
    esac

    rm -rf "$moved"
    printf '%s\n' "$app" | "$HL" delete "$app" --purge --apply >/dev/null 2>&1 || true
}

# v1.2.3 LOOSENS the guard above (path no longer counts, content does), so the
# thing it exists for has to be proven still to work: a stack that is genuinely
# not ours must still be refused. This is the paperless case -- containers under
# our project name, created from someone else's compose file. Recreating those
# would hand a running database new generated secrets.
test_foreign_stack_refused() {
    local app="$1" dir="/tmp/foreign-$1" img rc out
    printf '\n%s=== %s (a foreign stack is still refused) ===%s\n' "$D" "$app" "$Z"

    verb "$app" download;              expect_ok "foreign: download"

    # reuse the app's own image so this needs no extra pull
    img="$(grep -m1 -E '^\s*image:' "apps/$app/files/compose.yml" | sed 's/.*image:[[:space:]]*//' | tr -d '"'"'"'"')"
    if [ -z "$img" ]; then skip "foreign: no image found in $app compose"; return; fi

    mkdir -p "$dir"
    printf 'services:\n  impostor:\n    image: %s\n    command: ["sleep","600"]\n    entrypoint: [""]\n' "$img" \
        > "$dir/docker-compose.yml"

    if ! _dk compose -p "$app" -f "$dir/docker-compose.yml" up -d >/dev/null 2>&1; then
        skip "foreign: could not stage a foreign stack"; rm -rf "$dir"; return
    fi

    set +e
    out="$("$HL" start "$app" --apply 2>&1)"
    rc=$?
    set -e
    if [ "$rc" != 0 ] && [ "$rc" != 2 ] \
       && printf '%s' "$out" | grep -q 'different compose file'; then
        pass "foreign: refused to recreate a stack it did not create (rc=$rc)"
    else
        fail "foreign: did NOT refuse a foreign stack (rc=$rc)" "$(printf '%s' "$out" | tail -3)"
    fi

    _dk compose -p "$app" -f "$dir/docker-compose.yml" down -v >/dev/null 2>&1 || true
    rm -rf "$dir"
    printf '%s\n' "$app" | "$HL" delete "$app" --purge --apply >/dev/null 2>&1 || true
}

# v1.2.4: an override written for hardware the host no longer has must be
# refused before compose runs, with a message that says how to fix it -- not
# surface as a device error from inside `docker compose up`. Stage two stale
# overrides the VM cannot satisfy: a device node that does not exist, and an
# NVIDIA GPU with no nvidia runtime in docker. Neither may create a container.
# Then the remedy the message prints has to be true: `download` regenerates an
# override that fits, and start works.
test_override_does_not_fit() {
    local app="$1" svc="$2" state="/var/lib/homelab/apps/$1" n
    printf '\n%s=== %s (override that does not fit the host) ===%s\n' "$D" "$app" "$Z"

    verb "$app" download;              expect_ok "misfit: download"
    sudo mkdir -p "$state"

    printf 'services:\n  %s:\n    devices:\n      - /dev/homelab-no-such-device:/dev/null\n' "$svc" \
        | sudo tee "$state/compose.override.yml" >/dev/null
    verb "$app" start
    if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'does not fit this host'; then
        pass "misfit: missing device refused before compose (rc=1)"
    else
        fail "misfit: missing device not refused cleanly (rc=$RC)" "$(printf '%s' "$OUT" | tail -3)"
    fi

    if _dk info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
        skip "misfit: this host has an nvidia runtime, so a GPU misfit cannot be staged"
    else
        printf 'services:\n  %s:\n    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]\n' "$svc" \
            | sudo tee "$state/compose.override.yml" >/dev/null
        verb "$app" start
        if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'nvidia runtime'; then
            pass "misfit: NVIDIA override without the runtime refused (rc=1)"
        else
            fail "misfit: NVIDIA override without the runtime not refused cleanly (rc=$RC)" "$(printf '%s' "$OUT" | tail -3)"
        fi
    fi

    n="$(_dk ps -aq --filter "label=com.docker.compose.project=$app" | grep -c . || true)"
    if [ "$n" = 0 ]; then pass "misfit: no containers were created"
    else fail "misfit: $n container(s) created despite the refusal"; fi

    verb "$app" download;              expect_ok "misfit: download regenerates the override"
    verb "$app" start;                 expect_ok "misfit: start after regenerating"

    printf '%s\n' "$app" | "$HL" delete "$app" --purge --apply >/dev/null 2>&1 || true
    sudo rm -f "$state/compose.override.yml"
}

# v1.2.4: install warns -- and only warns -- when an app suggests more RAM than
# the host has. A dry run of the hungriest app whose disk need still fits, so
# the disk stop cannot be mistaken for a RAM block, and nothing changes.
test_install_ram_warning() {
    printf '\n%s=== install preflight: RAM is a warning, not a stop ===%s\n' "$D" "$Z"
    local host_mb free_mb best="" best_mb=0 a mb disk rc out
    host_mb="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
    free_mb="$(df -Pm /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')"
    [ -n "$free_mb" ] || free_mb="$(df -Pm / | awk 'NR==2{print $4}')"
    for a in $(for d in apps/*/; do [ -f "$d/app.conf" ] && basename "$d"; done); do
        mb="$(sed -n 's/^needs_ram_mb=\([0-9]*\).*/\1/p' "apps/$a/app.conf")"
        disk="$(sed -n 's/^needs_disk_mb=\([0-9]*\).*/\1/p' "apps/$a/app.conf")"
        if [ "${disk:-0}" -gt "$free_mb" ]; then continue; fi
        if [ "${mb:-0}" -gt "$best_mb" ]; then best="$a"; best_mb="$mb"; fi
    done
    if [ -z "$best" ] || [ "$best_mb" -le "$host_mb" ]; then
        skip "ram: no app asks for more than this host's ${host_mb} MB"; return
    fi
    set +e
    out="$("$HL" install "$best" 2>&1)"
    rc=$?
    set -e
    if printf '%s' "$out" | grep -q "suggests ${best_mb} MB of RAM"; then
        pass "ram: $best (${best_mb} MB) warned on a ${host_mb} MB host"
    else
        fail "ram: no RAM warning for $best (${best_mb} MB) on a ${host_mb} MB host" "$(printf '%s' "$out" | head -5)"
    fi
    if [ "$rc" = 0 ]; then pass "ram: the warning did not block the install (rc=0)"
    else fail "ram: install blocked or failed (rc=$rc)" "$(printf '%s' "$out" | tail -3)"; fi
}

APPS="${1:-}"
if [ -z "$APPS" ]; then
    APPS="$(for d in apps/*/; do [ -f "$d/app.conf" ] && basename "$d"; done)"
fi

printf '%shomelab contract conformance%s\n' "$D" "$Z"
for a in $APPS; do test_app "$a"; done

# override-capable apps present in this run also go through the override guard
for pair in $OVERRIDE_APPS; do
    a="${pair%%:*}"
    case " $APPS " in *" $a "*) test_override_restart "$a" "${pair#*:}" ;; esac
done

# and through the second-engine-root guard (v1.2.3)
for pair in $OVERRIDE_APPS; do
    a="${pair%%:*}"
    case " $APPS " in *" $a "*) test_moved_root_restart "$a" ;; esac
done

# ...and that loosening it did not stop it refusing a stack that is not ours
for pair in $OVERRIDE_APPS; do
    a="${pair%%:*}"
    case " $APPS " in *" $a "*) test_foreign_stack_refused "$a" ;; esac
done

# ...and an override that no longer fits the host is refused before compose (v1.2.4)
for pair in $OVERRIDE_APPS; do
    a="${pair%%:*}"
    case " $APPS " in *" $a "*) test_override_does_not_fit "$a" "${pair#*:}" ;; esac
done

# install preflight, once per run: read-only, a dry run
test_install_ram_warning

printf '\n%s---%s\n' "$D" "$Z"
printf 'passed %s%d%s   failed %s%d%s   skipped %d\n' "$G" "$PASS" "$Z" "$R" "$FAIL" "$Z" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf '\nfailures:\n'; printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
