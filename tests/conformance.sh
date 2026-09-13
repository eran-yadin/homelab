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

printf '\n%s---%s\n' "$D" "$Z"
printf 'passed %s%d%s   failed %s%d%s   skipped %d\n' "$G" "$PASS" "$Z" "$R" "$FAIL" "$Z" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf '\nfailures:\n'; printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
