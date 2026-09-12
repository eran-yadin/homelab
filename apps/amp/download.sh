#!/usr/bin/env bash
# AMP has no package repository; CubeCoders' supported install is a script
# fetched over https and run as root. That is a real trust decision, so this
# says exactly what it is about to do rather than burying it.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"
. "$HOMELAB_ROOT/lib/detect.sh"
detect_host

GETAMP_URL="https://getamp.sh"

# Already here? Adopt it. A server that ran AMP before this catalog existed
# should not be reinstalled, and re-running install must be safe.
if have ampinstmgr || systemctl cat ampinstmgr.service >/dev/null 2>&1; then
    ok "AMP is already installed on this host - adopting it, changing nothing"
    exit $EX_NOOP
fi

if [ "$DET_FAMILY" != debian ]; then
    die "getamp.sh supports Debian/Ubuntu and RHEL; this host is '$DET_FAMILY'.
     See https://cubecoders.com/AMPInstall for the supported list."
fi

ensure_state_dir
render_env

# In a dry run render_env only printed what it would write, so there is no file
# to read. Fall back to placeholders so the rest of the plan can still be shown.
if [ -f "$APP_STATE/.env" ]; then
    # shellcheck disable=SC1090
    set -a; . "$APP_STATE/.env"; set +a
elif ! is_apply; then
    AMP_ADMIN_USER=admin
    AMP_ADMIN_PASSWORD='<generated at install>'
    AMP_SYSTEM_PASSWORD='<generated at install>'
else
    die "$APP_STATE/.env was not created; cannot continue"
fi

if [ "${AMP_INSTALL_HTTPS:-n}" = y ]; then
    warn "AMP_INSTALL_HTTPS=y makes getamp.sh install and configure nginx,"
    warn "  which will fight caddy for port 80. Prefer routing AMP through caddy."
fi

log "installing prerequisites"
run $SUDO apt-get update -qq
run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wget ca-certificates

warn "about to download $GETAMP_URL and execute it as root."
warn "  That is CubeCoders' supported install path; there is no apt repository."
warn "  It creates an 'amp' system user and installs under /home/amp."

# USE_ANSWERS gets past the install prompts, but getamp.sh then blocks on
# "Waiting for user to complete first-time setup in browser..." -- the admin
# account is created in the panel, and no environment variable skips it. Cap
# the run and judge success by what exists afterwards, not by its exit code.
log "running the unattended installer (several minutes)"
# USE_ANSWERS=y is what turns off the interactive prompts. The ANSWER_* names
# are CubeCoders'; see their GetAMP Unattended Installations guide.
run_sh "$SUDO timeout --foreground 1800 env \
    USE_ANSWERS=y \
    ANSWER_AMPUSER='${AMP_ADMIN_USER:-admin}' \
    ANSWER_AMPPASS='${AMP_ADMIN_PASSWORD}' \
    ANSWER_SYSPASSWORD='${AMP_SYSTEM_PASSWORD}' \
    ANSWER_INSTALLJAVA='${AMP_INSTALL_JAVA:-y}' \
    ANSWER_INSTALLSRCDSLIBS='${AMP_INSTALL_SRCDS_LIBS:-n}' \
    ANSWER_INSTALLDOCKER='${AMP_INSTALL_DOCKER:-n}' \
    ANSWER_HTTPS='${AMP_INSTALL_HTTPS:-n}' \
    bash -c 'wget -qO- $GETAMP_URL | bash' </dev/null || true"

if is_apply; then
    have ampinstmgr || die "getamp.sh finished but ampinstmgr is not on PATH.
     Check its output above; AMP may need a licence or a supported distro."
    ok "AMP installed"
    log "panel:    http://${DET_IP:-localhost}:8080"
    log "username: ${AMP_ADMIN_USER:-admin}"
    log "password: in $APP_STATE/.env  (AMP_ADMIN_PASSWORD)"
    warn "First-time setup finishes in the browser -- open the panel and complete"
    warn "  it. Nothing here can do that step for you."
    warn "AMP is free for personal use; enter a licence in the panel for more."
    warn "ampinstmgr runs instances as the 'amp' system user. To manage them:"
    warn "      sudo su -l amp -c 'ampinstmgr status'"
fi
