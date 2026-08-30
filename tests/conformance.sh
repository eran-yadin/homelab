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

# run a verb, echo its exit code, keep output in $OUT
verb() {
    local app="$1" v="$2"; shift 2
    OUT="$("$HL" "$v" "$app" "$@" --apply 2>&1)"
    printf '%s' "$?"
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
    rc="$(verb "$app" download)"
    [ "$rc" = 0 ] || [ "$rc" = 2 ] && pass "download rc=$rc" || fail "download rc=$rc" "$OUT"

    # --- start ----------------------------------------------------------
    rc="$(verb "$app" start)"
    [ "$rc" = 0 ] || [ "$rc" = 2 ] && pass "start rc=$rc" || fail "start rc=$rc" "$OUT"
    sleep 3
    assert_json "after start" "$(status_json "$app")" '^(running|degraded)$'

    # --- start again must be a no-op ------------------------------------
    rc="$(verb "$app" start)"
    if [ "$rc" = 2 ]; then pass "start is idempotent (rc=2)"
    elif [ "$rc" = 0 ]; then fail "start ran again instead of reporting no-op (rc=0)" "$OUT"
    else fail "start rc=$rc on second run" "$OUT"; fi

    # --- stop -----------------------------------------------------------
    rc="$(verb "$app" stop)"
    [ "$rc" = 0 ] || [ "$rc" = 2 ] && pass "stop rc=$rc" || fail "stop rc=$rc" "$OUT"
    assert_json "after stop" "$(status_json "$app")" '^(stopped|absent|downloaded)$'

    # --- stop again must be a no-op -------------------------------------
    rc="$(verb "$app" stop)"
    if [ "$rc" = 2 ]; then pass "stop is idempotent (rc=2)"
    else fail "stop not idempotent (rc=$rc)" "$OUT"; fi

    # --- restart + update ------------------------------------------------
    rc="$(verb "$app" start)"
    [ "$rc" = 0 ] || [ "$rc" = 2 ] && pass "restart rc=$rc" || fail "restart rc=$rc" "$OUT"
    rc="$(verb "$app" update)"
    [ "$rc" = 0 ] || [ "$rc" = 2 ] && pass "update rc=$rc" || fail "update rc=$rc" "$OUT"

    # --- delete --purge --------------------------------------------------
    if [ "$app" = docker ]; then
        skip "delete: refusing to uninstall docker mid-suite (other apps need it)"
        return
    fi
    rc="$(printf '%s\n' "$app" | "$HL" delete "$app" --purge --apply >/dev/null 2>&1; echo $?)"
    if [ "$rc" = 0 ] || [ "$rc" = 2 ]; then pass "delete --purge rc=$rc"
    else fail "delete --purge rc=$rc"; fi
    assert_json "after purge" "$(status_json "$app")" '^(absent|downloaded)$'

    # --- delete again must be a no-op ------------------------------------
    rc="$(verb "$app" delete)"
    if [ "$rc" = 2 ]; then pass "delete is idempotent (rc=2)"
    else fail "delete not idempotent (rc=$rc)" "$OUT"; fi
}

APPS="${1:-}"
if [ -z "$APPS" ]; then
    APPS="$(for d in apps/*/; do [ -f "$d/app.conf" ] && basename "$d"; done)"
fi

printf '%shomelab contract conformance%s\n' "$D" "$Z"
for a in $APPS; do test_app "$a"; done

printf '\n%s---%s\n' "$D" "$Z"
printf 'passed %s%d%s   failed %s%d%s   skipped %d\n' "$G" "$PASS" "$Z" "$R" "$FAIL" "$Z" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf '\nfailures:\n'; printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
