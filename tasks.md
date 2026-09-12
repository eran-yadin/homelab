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

**Still to do:**

- [ ] On the NUC, replace the tar-extracted `~/homelab` with a git clone:
      `mv ~/homelab ~/homelab.old && git clone https://github.com/eran-yadin/homelab.git ~/homelab`
- [ ] First run: `deploy --from ~/homelab --apply` once (ships this code and
      writes `.deployed-rev`), then `update self` from then on.
- [ ] Test the whole cycle in the VM first (`cd testenv && make up && make sync`).
- [ ] Maybe: an "Update homelab" button in the hub. Today the hub's control
      endpoint only accepts catalog apps, so `self` is rejected with 404.
- [ ] No timer. Unattended deploy on every push skips the VM gate.
