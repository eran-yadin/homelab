# Tasks

## Auto-deploy script for nucserver (`scripts/ship.sh`)

Replace the manual two-step "tar over ssh, then `deploy --from`" flow from the
README with one script that runs **on the NUC** and does the whole cycle:

1. **Download** — `git fetch` in `~/homelab` (a Linux clone, so the hub's
   symlinks under `apps/hub/files/` are real; a tar from a Windows checkout
   ships them as one-line text files and breaks the hub).
2. **Compare** — if `origin/main` is not ahead of `HEAD`, report "nothing new"
   and exit without touching anything.
3. **Backup** — tar `/opt/homelab` and `/opt/homelab-hub` into
   `~/backups/ship-<timestamp>/`, plus `homelab status --json` as the
   "before" snapshot. Both dirs are world-readable, so no sudo needed.
4. **Update** — `git pull`, then
   `sudo -n /opt/homelab/homelab deploy --from ~/homelab --apply`
   (the only passwordless sudo on the NUC).
5. **Rerun** — `deploy` already refreshes the hub's files and restarts
   `homelab-hub`; nothing extra to do.
6. **Test** — smoke check, since `tests/conformance.sh` refuses to run outside
   the VM: hub answers on `:7070/api/status`, `homelab status --json` is valid,
   and every app that was running before is still running after.
7. **Report** — print before/after summary and the backup path. On a failed
   smoke check, roll back with `deploy --from <backup>` and say so.

Constraints:
- Test the script in the VM first (`cd testenv && make up && make sync`).
- One command, run on demand (`ssh nucserver 'bash ~/homelab/scripts/ship.sh'`).
  No timer yet — unattended deploy on every push skips the VM gate.
- Must obey the contract: nothing changes without `--apply`, no direct
  `docker`/`systemctl` calls beyond the smoke check's read-only queries.
