#!/bin/sh
# Runs inside the container, as PUID. Puts the settings from the app's .env
# into UnrealTournament.ini, then hands over to the image's start script.
set -eu

/app/install.sh /data/server        # first start: download; later: a no-op

sys=/data/addons/System
ini="$sys/UnrealTournament.ini"
mkdir -p "$sys"

# First start: UT would create its ini from Default.ini; do that now so the
# settings below land before the server ever runs.
if [ ! -f "$ini" ]; then
    for d in /data/server/System/Default.ini "$sys/Default.ini"; do
        if [ -f "$d" ]; then cp "$d" "$ini"; break; fi
    done
fi
[ -f "$ini" ] || { echo "homelab: no UnrealTournament.ini or Default.ini" >&2; exit 1; }

# set_ini SECTION KEY VALUE: replace KEY in [SECTION], add it, or add the section.
set_ini() {
    tmp="$ini.homelab.tmp"
    awk -v sec="[$1]" -v key="$2" -v val="$3" '
        function emit() { if (insec && !done) { print key "=" val; done = 1 } }
        { line = $0; sub(/\r$/, "", line) }
        line ~ /^\[/ { emit(); insec = (line == sec) }
        insec && index(line, key "=") == 1 { if (!done) print key "=" val; done = 1; next }
        { print }
        END { emit(); if (!done) { print ""; print sec; print key "=" val } }
    ' "$ini" >"$tmp"
    cat "$tmp" >"$ini"
    rm -f "$tmp"
}

set_ini Engine.GameReplicationInfo ServerName "$SERVER_NAME"
set_ini Engine.GameReplicationInfo ShortName "$SERVER_NAME"
set_ini Engine.GameInfo AdminPassword "$ADMIN_PASSWORD"
set_ini UWeb.WebServer bEnabled True
set_ini UWeb.WebServer ListenPort "$WEBADMIN_PORT"
set_ini UTServerAdmin.UTServerAdmin AdminUsername admin
set_ini UTServerAdmin.UTServerAdmin AdminPassword "$ADMIN_PASSWORD"

# The web admin only runs if the engine loads it.
if ! grep -q '^ServerActors=UWeb.WebServer' "$ini"; then
    echo "homelab: adding UWeb.WebServer to ServerActors"
    tmp="$ini.homelab.tmp"
    awk '{ print } /^\[Engine.GameEngine\]/ { print "ServerActors=UWeb.WebServer" }' "$ini" >"$tmp"
    cat "$tmp" >"$ini"; rm -f "$tmp"
fi

exec /app/start_server.sh
