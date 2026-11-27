# shellcheck shell=bash
# Sourced by start.sh and update.sh. A firewall applied over the network can
# lock out the very session that applied it, and then nothing can undo it
# remotely. So every apply arms a timer that turns the firewall off again in
# ROLLBACK_SECS unless `homelab confirm firewall --apply` disarms it first.
ROLLBACK_UNIT=homelab-firewall-rollback
ROLLBACK_SECS="${HOMELAB_FW_ROLLBACK_SECS:-180}"

arm_rollback() {
    run $SUDO systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
    run $SUDO systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="$ROLLBACK_SECS" \
        --description="homelab firewall: undo unless confirmed" \
        /bin/systemctl disable --now homelab-firewall.service
    warn "firewall is ON with a safety net: it turns itself OFF again in ${ROLLBACK_SECS}s."
    warn "    Check you can still reach this box (ssh, the hub), then keep it with:"
    warn "        homelab confirm firewall --apply"
}
