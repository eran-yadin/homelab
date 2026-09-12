# Tasks

## `homelab update self` - the engine updates itself from GitHub

**Done (2026-09-12):** implemented in the CLI as `homelab update self`
(`cmd_update_self`, sharing `deploy_tree` with `deploy`). Run on the NUC:

    ssh nucserver 'sudo -n /opt/homelab/homelab update self --apply'

What it does, in order:

1. **Download** - `git fetch` in `~/homelab`, run as the checkout's owner even
   when the hub calls us as root (git refuses root in a user-owned repo).
2. **Compare** - origin vs `/opt/homelab/.deployed-rev`, which `deploy` now
   writes. Same commit: "already up to date", exit 2, nothing touched.
   Local commits not on origin: refuse; it only fast-forwards.
3. **Backup** - `cp -a` of `/opt/homelab` and `/opt/homelab-hub` plus a
   status snapshot into `~/backups/homelab-self-<timestamp>/`.
4. **Update** - `git pull --ff-only`, then `deploy_tree`.
5. **Rerun** - `deploy_tree` refreshes the hub's files and restarts it.
6. **Test** - smoke check (conformance refuses outside the VM): hub answers
   on `:7070/api/status`, `status --json` parses, every app that was
   `running` before still is.
7. **Report** - old and new commit and the backup path. On failure: redeploy
   the backup, re-run the smoke test, say which state we ended in.

Dry run (no `--apply`) fetches and compares for real, prints the rest.

**Done on the NUC (2026-09-12):** `~/homelab` is now a git clone (the old
tar copy is `~/homelab.old`). The NUC's unpushed 2026-09-01 work (ollama app,
disk check, buildx fix, caddy reload, GPU detect, AMP fixes) was committed as
a6300f6 first, so nothing was lost. First `update self --apply` ran clean:
backup, deploy, smoke test all ok; a second run reported up to date, exit 2.

**Update button (2026-09-12):** the hub header has an Update button. It
opens `/update` in its own tab; that page calls `POST /api/update/start`,
which runs `homelab update self --apply --detach`. `--detach` hands the work
to a transient systemd unit (`homelab-self-update`) writing to
`/var/lib/homelab-hub/update.log`, so the update survives the hub restart it
causes and closing the tab changes nothing. The page tails the log through
the restart and ends with a plain-language result.

**Still to do:**

- [ ] No timer. Unattended deploy on every push skips the VM gate.
- [ ] Versioning: see the discussion in the session of 2026-09-12.
