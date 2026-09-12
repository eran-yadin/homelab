#!/usr/bin/env bash
# Generate one route per installed app, from the catalog, so the proxy follows
# the app store instead of being hand-maintained alongside it.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/catalog.sh"      # catalog_names
. "$HOMELAB_ROOT/lib/detect.sh"       # DET_IP for the hosts-file hint
detect_host
ensure_state_dir
render_env

DOMAIN="$(sed -n 's/^CADDY_DOMAIN=//p' "$APP_STATE/.env" 2>/dev/null | head -1)"
DOMAIN="${DOMAIN:-nuc}"
SITES=/etc/caddy/sites

log "generating routes for *.$DOMAIN"
run $SUDO mkdir -p "$SITES"

generated=""
for a in $(catalog_names 2>/dev/null || true); do
    [ "$a" = caddy ] && continue
    # shellcheck disable=SC1090
    ( . "$HOMELAB_APPS/$a/app.conf" ) 2>/dev/null || continue
    port="$(sed -n 's/^ports="\([0-9]*\).*/\1/p' "$HOMELAB_APPS/$a/app.conf" | head -1)"
    [ -n "$port" ] || continue

    # Only route what is actually here, so the proxy does not advertise
    # hostnames that answer with a connection refused.
    state="$("$HOMELAB_ROOT/homelab" status "$a" --json 2>/dev/null \
             | sed -n 's/.*"state":"\([a-z]*\)".*/\1/p')"
    case "$state" in running|degraded|stopped) ;; *) continue ;; esac

    printf '%s.%s {\n\treverse_proxy 127.0.0.1:%s\n}\n' "$a" "$DOMAIN" "$port" \
        | run_write "$SITES/$a.caddy" 0644
    generated="$generated $a"
done
ok "routed:${generated:- none}"

if [ -n "$generated" ]; then
    warn "these names need to resolve to this machine. Until then, on each client:"
    for a in $generated; do printf '      %s  %s.%s\n' "${DET_IP:-<server-ip>}" "$a" "$DOMAIN" >&2; done
    warn "  (add to /etc/hosts, or let AdGuard answer for *.$DOMAIN)"
fi

# Writing the files is not enough: caddy reads them at config load, so a route
# generated while it is running stays inactive until something reloads it.
# `caddy reload` is graceful -- no dropped connections, unlike a restart.
if dk_resolve && "${DK[@]}" inspect caddy >/dev/null 2>&1 \
   && [ "$("${DK[@]}" inspect -f '{{.State.Running}}' caddy 2>/dev/null)" = true ]; then
    log "reloading caddy so the new routes take effect"
    run "${DK[@]}" exec caddy caddy reload --config /etc/caddy/Caddyfile
fi

exec bash "$HOMELAB_ROOT/lib/kinds/compose.sh" download "$@"
