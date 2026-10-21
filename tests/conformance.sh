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
    "$HL" install "$app" >/dev/null 2>&1 || true   # may fail (adopted apps); only the before/after matters
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
    assert_json "after purge" "$(status_json "$app")" '^absent$'

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
    # It owns a volume called "data" -- under this project that is the same
    # <app>_data name most of our compose files use, which is what a purge
    # would reach for.
    printf 'services:\n  impostor:\n    image: %s\n    command: ["sleep","600"]\n    entrypoint: [""]\n    volumes: ["data:/x"]\nvolumes:\n  data:\n' "$img" \
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

    # v1.3.0: the hub can delete. Every verb that would recreate, remove, or
    # write into the stack must refuse it, and leave it and its volume alone.
    local v verb rest
    for v in update delete "delete --purge" "restore /tmp"; do
        verb="${v%% *}"; rest="${v#"$verb"}"
        set +e
        # shellcheck disable=SC2086
        out="$(printf '%s\n' "$app" | "$HL" "$verb" "$app" $rest --apply --yes 2>&1)"
        rc=$?
        set -e
        if [ "$rc" != 0 ] && [ "$rc" != 2 ] \
           && printf '%s' "$out" | grep -q 'different compose file'; then
            pass "foreign: $v refused (rc=$rc)"
        else
            fail "foreign: $v did NOT refuse a foreign stack (rc=$rc)" "$(printf '%s' "$out" | tail -3)"
        fi
    done
    if [ -n "$(_dk ps -aq --filter "label=com.docker.compose.project=$app")" ] \
       && _dk volume inspect "${app}_data" >/dev/null 2>&1; then
        pass "foreign: its container and volume are untouched"
    else
        fail "foreign: the foreign stack or its volume was removed"
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

# netmon's web UI (v1.7.0): the companion units come and go with the app, the
# UI can stop and start the monitor and change its settings without sudo, it
# refuses settings that would reach the unit unvalidated, and an update keeps
# targets that were hand-edited into an older unit.
test_netmon_web() {
    local app=netmon W=http://127.0.0.1:8095 J='Content-Type: application/json' i out pid env
    printf '\n%s=== %s (web UI, control, settings) ===%s\n' "$D" "$app" "$Z"

    verb "$app" download;              expect_ok "web: download"
    verb "$app" start;                 expect_ok "web: start"
    for i in 1 2 3 4 5 6 7 8 9 10; do curl -fs "$W/api/status" >/dev/null 2>&1 && break; sleep 1; done
    out="$(curl -fs "$W/api/status" || true)"
    if printf '%s' "$out" | grep -q '"state": "active"'; then pass "web: answers on :8095 and sees netmon running"
    else fail "web: /api/status" "$out"; fi
    if curl -fs "$W/" | grep -q '<title>netmon</title>'; then pass "web: serves the page"
    else fail "web: page not served"; fi
    assert_json "web: status with the UI up" "$(status_json "$app")" '^running$'

    # stop the monitor from the UI: no sudo, the .path unit does it
    curl -fs -H "$J" -d '{"action":"stop"}' "$W/api/control" >/dev/null || true
    for i in 1 2 3 4 5 6 7 8; do systemctl is-active --quiet netmon.service || break; sleep 1; done
    if ! systemctl is-active --quiet netmon.service && systemctl is-active --quiet netmon-web.service; then
        pass "web: stop from the UI stops the monitor, the UI stays up"
    else fail "web: UI stop" "netmon=$(systemctl is-active netmon.service) web=$(systemctl is-active netmon-web.service)"; fi
    assert_json "web: status with only the UI up" "$(status_json "$app")" '^stopped$'

    # the hub's start brings the monitor back even though the UI holds :8095
    verb "$app" start;                 expect_ok "web: start while the UI holds the port"
    if systemctl is-active --quiet netmon.service; then pass "web: monitor running again"
    else fail "web: monitor did not start"; fi

    # settings: rejected input never reaches the file
    sleep 3
    out="$(curl -s -o /dev/null -w '%{http_code}' -H "$J" \
        -d '{"targets":[{"name":"a","host":"1.1.1.1\nLD_PRELOAD=/tmp/x.so"}],"interval":1,"timeout":2,"retention_days":30}' "$W/api/settings" || true)"
    if [ "$out" = 400 ] && ! sudo grep -qs LD_PRELOAD /var/lib/netmon/settings.env; then pass "web: injected setting refused (400)"
    else fail "web: injected setting not refused (HTTP $out)"; fi

    pid="$(systemctl show -p MainPID --value netmon.service)"
    out="$(curl -s -H "$J" -d '{"targets":[{"name":"gateway","host":"10.100.0.2"},{"name":"cflare","host":"1.1.1.1"}],"interval":2,"timeout":1,"retention_days":7}' "$W/api/settings" || true)"
    for i in 1 2 3 4 5 6 7 8; do
        [ "$(systemctl show -p MainPID --value netmon.service)" != "$pid" ] && systemctl is-active --quiet netmon.service && break; sleep 1
    done
    env="$(sudo cat "/proc/$(systemctl show -p MainPID --value netmon.service)/environ" 2>/dev/null | tr '\0' '\n' || true)"
    if printf '%s\n' "$env" | grep -qx 'NETMON_TARGETS=gateway=10.100.0.2,cflare=1.1.1.1' \
       && printf '%s\n' "$env" | grep -qx 'NETMON_INTERVAL=2.0'; then
        pass "web: saved settings restart netmon with them"
    else fail "web: settings not applied" "$out / $(printf '%s' "$env" | grep NETMON_ | tr '\n' ' ')"; fi

    out="$(curl -s -o /dev/null -w '%{http_code}' -H "$J" -d '{"host":"1.1.1.1","cycles":1}' "$W/api/mtr" || true)"
    case "$out" in 200|500) pass "web: path test answers (HTTP $out; SLIRP may hide hops)" ;;
                   *) fail "web: path test HTTP $out" ;; esac
    if curl -fs "$W/api/csv?kind=minute&hours=1" | head -1 | grep -q '^timestamp,target,packets'; then pass "web: csv export"
    else fail "web: csv export"; fi

    # update keeps the web settings and restarts what was running
    verb "$app" update;                expect_ok "web: update"
    if sudo grep -q '^NETMON_TARGETS=gateway=10.100.0.2,cflare=1.1.1.1' /var/lib/netmon/settings.env \
       && systemctl is-active --quiet netmon-web.service; then pass "web: update kept settings.env, UI back up"
    else fail "web: update lost settings or the UI"; fi

    # an older box: targets hand-edited into the unit, no settings.env yet
    sudo rm -f /var/lib/netmon/settings.env
    sudo sed -i 's|^Environment=NETMON_TARGETS=.*|Environment=NETMON_TARGETS=gateway=10.100.0.2,isp_edge=10.100.0.3|' /etc/systemd/system/netmon.service
    sudo systemctl daemon-reload
    verb "$app" update;                expect_ok "web: update on a pre-web box"
    if sudo grep -q '^NETMON_TARGETS=gateway=10.100.0.2,isp_edge=10.100.0.3$' /var/lib/netmon/settings.env; then
        pass "web: hand-edited targets carried into settings.env"
    else fail "web: hand-edited targets lost" "$(sudo cat /var/lib/netmon/settings.env 2>&1)"; fi

    set +e
    OUT="$(printf '%s\n' "$app" | "$HL" delete "$app" --purge --apply 2>&1)"; RC=$?
    set -e
    expect_ok "web: delete --purge"
    local left=""
    for u in netmon.service netmon-web.service netmon-control.path netmon-control.service; do
        if [ -e "/etc/systemd/system/$u" ]; then left="$left $u"; fi
    done
    if [ -z "$left" ] && ! curl -fs "$W/api/status" >/dev/null 2>&1; then pass "web: purge removed every unit, :8095 closed"
    else fail "web: purge left:${left:- (port still open)}"; fi
}

APPS="${1:-}"
if [ -z "$APPS" ]; then
    APPS="$(for d in apps/*/; do [ -f "$d/app.conf" ] && basename "$d"; done)"
fi

printf '%shomelab contract conformance%s\n' "$D" "$Z"
for a in $APPS; do test_app "$a"; done

case " $APPS " in *" netmon "*) test_netmon_web ;; esac

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

# v1.3.1: an adopted container can be removed from the hub -- the container
# only. Stage one under feishin's name with a named volume: --purge must be
# refused, plain delete must remove the container and keep the volume.
test_adopted_container_remove() {
    local app=feishin vol=conformance-adopted-vol rc out
    printf '\n%s=== %s (adopted container: remove, never purge) ===%s\n' "$D" "$app" "$Z"
    if ! _dk run -d --name "$app" -v "$vol:/data" busybox sleep 600 >/dev/null 2>&1; then
        skip "adopted: could not stage a container"; return
    fi
    set +e
    out="$(printf '%s\n' "$app" | "$HL" delete "$app" --purge --apply 2>&1)"; rc=$?
    set -e
    if [ "$rc" = 1 ] && _dk inspect "$app" >/dev/null 2>&1; then
        pass "adopted: --purge refused, container still there"
    else
        fail "adopted: --purge was not refused (rc=$rc)" "$(printf '%s' "$out" | tail -3)"
    fi
    verb "$app" delete;                             expect_ok "adopted: delete"
    if ! _dk inspect "$app" >/dev/null 2>&1 && _dk volume inspect "$vol" >/dev/null 2>&1; then
        pass "adopted: container removed, its volume kept"
    else
        fail "adopted: container not removed, or its volume went with it"
    fi
    _dk rm -f "$app" >/dev/null 2>&1 || true
    _dk volume rm "$vol" >/dev/null 2>&1 || true
}

# ...and that loosening it did not stop it refusing a stack that is not ours
for pair in $OVERRIDE_APPS; do
    a="${pair%%:*}"
    case " $APPS " in *" $a "*) test_foreign_stack_refused "$a" ;; esac
done

case " $APPS " in *" feishin "*) test_adopted_container_remove ;; esac

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
