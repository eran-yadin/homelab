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

**Cleanup (2026-09-12):** `/opt/homelab` had 44 GB of test-VM leftovers
(`run/data.img`, `golden/*.qcow2`, a stray `Makefile` and `cloud-init/`),
and the first backups copied all of it. They now live in
`~/testenv-leftover-from-opt/` on the NUC; delete that directory if the test
VM disk is not wanted. The backup step skips VM images and refuses anything
over 200 MB.

**Releases (2026-09-12):** git tags are releases. `update self` defaults to
`--channel stable`, the newest `v*` tag; `--channel main` follows the
branch; `--to <tag>` pins or rolls back. `deploy` writes `VERSION`, shown by
`homelab version` and in the hub. First tag: `v1.0.0`.

## Immich (2026-09-12)

Added as `apps/immich`: app.conf + files/compose.yml + files/env.template,
no scripts, kind=compose. Upstream's release compose with named volumes,
explicit environment, and the version pinned in env.template (v3.2.0).
CPU only; hardware acceleration (openvino ML, quicksync transcoding via
/dev/dri) is a later step, as is a `download.sh` override like jellyfin's.

Tested locally under Docker Desktop (all four healthy, migrations ran, ping,
UI 200), released as v1.1.0, installed on nucserver: `homelab status immich`
reports running/healthy 4/4, hub links to http://10.0.0.5:2283. The test VM
could not be used: qemu is not on the NUC and cachy-rig was offline.

- [ ] Open http://10.0.0.5:2283, create the first (admin) account, install the phone app.
- [ ] `homelab download caddy --apply` to add the immich.nuc route.
- [ ] Hardware acceleration on the NUC (HD 620: openvino ML image + /dev/dri).

**Verb audit (2026-09-12):** every app in the store implements all eight
verbs, its own or inherited from its kind; every stateful app has
backup/restore, and the stateful systemd apps (amp, netmon) declare
`backup_paths`. Nothing missing.

## Safe updates with floating tags (2026-09-12)

Decision: apps follow `latest`/`stable`/`release`; staying pinned is worse
than moving. What makes that safe is the moment of the update: `update` on a
compose app pulls, shows the version jump per service, and for a stateful
app backs up its volumes (minus `bulk_volumes`, e.g. Immich's library) and
asks before recreating. Exit 3 = asked, nobody answered; `--yes` answers.
The hub shows a dialog. Restore path printed after the backup.

- [x] On the NUC, switch the installed Immich's `.env` from v3.2.0 to `release` (done, v1.2.0 deployed).
- [ ] Same treatment for kind=systemd apps (amp, netmon): back up `backup_paths` before `update`.

## Unified search ("search everything", launcher style)

One box in the hub, or a keyboard shortcut, that fans a query out to every
installed app in parallel and shows results grouped by source; clicking a
result opens it in that app. Not started. The plan:

**Shape**

- `GET /api/search?q=...` in the hub. The hub holds the API tokens, calls
  each app server-side in parallel with a per-app timeout (~3 s), and
  streams results as they arrive (SSE or chunked JSON) so one slow app
  never holds the list.
- One adapter per app, ~20 lines each: build the query URL, map the
  response to `{title, snippet, url, thumb, source}`. Adapters live in
  `apps/<name>/search.py` (or a `search=` block in app.conf naming a
  built-in adapter), so a new app joins by adding a file, like everything
  else in the catalog.
- Tokens in `/var/lib/homelab-hub/search/<app>.token`, 0600, hub user
  only. Never in the page. A settings section in the hub to paste them.
- The hub page: a search field (the app-filter search box already exists;
  reuse its position), `/` to focus, results grouped by app with the
  app's icon, arrow keys to move, Enter to open.

**Sources, in the order to build them**

1. **transcribe** - our own Flask app; already has a search page. Easiest.
2. **paperless** - `GET /api/documents/?query=` with a token; full text.
   Where the real data is.
3. **immich** - `POST /api/search/smart` (`{"query": ...}`) with an API
   key; also `/api/search/metadata`. The one that makes it feel magical.
4. **jellyfin** - `/Items?searchTerm=` with an API key.
5. **navidrome** - Subsonic `search3`.
6. **home-assistant** - entities/states, a different kind of result; last.
7. **ollama** - not a source, a layer: rewrite a vague query, or answer
   from the top results. Only after the plain version is useful.

Deliberately out: **vaultwarden** (encrypted client-side; the server must
not search it), caddy, tailscale, adguard, docker, cockpit, uptime-kuma.

**Steps**

- [ ] hub: `/api/search` with parallel fan-out, timeout, streaming; adapter loader
- [ ] hub: search UI, keyboard driven; settings page for tokens
- [ ] adapter: transcribe, paperless (test against the real 200+ documents)
- [ ] adapter: immich (after Immich is installed and has photos)
- [ ] adapter: jellyfin, navidrome (when installed)
- [ ] ollama layer, optional
- [ ] docs: how to add an adapter, in `.claude/skills/homelab-app/SKILL.md`

**Still to do:**

- [ ] Delete `~/testenv-leftover-from-opt/` on the NUC (44 GB) if not needed.
- [ ] CHANGELOG, one line per tag, shown on the update page.
- [ ] GitHub Actions: bash -n, shellcheck, tests/checkjs.py on every push.
- [ ] No timer. The stable channel makes one safe now, if wanted.

## Hamachi for friends (game servers) - later

Why: friends need to reach game servers (Factorio via AMP, UDP 34197)
without port forwarding or a reverse proxy; caddy cannot proxy UDP anyway.
**Tailscale stays for me and family only** - friends do not join it.

Already on the NUC (checked 2026-09-13), just not in the catalog, so this
is an **adopt**, like amp and cockpit:

- `logmein-hamachi` 2.1.0.203-1 (deb, a 2019 build), running and enabled
  through a SysV init script (`/etc/init.d/logmein-hamachi`), `ham0` up
  as 25.28.0.159. State in `/var/lib/logmein-hamachi` (identity + keys:
  that is `backup_paths`, or the node gets a new ID).
- `playit` 0.17.1 (deb) with a `playit.service` (screen-wrapped,
  User=server_admin), inactive and disabled.

Hamachi's Linux client is CLI only, still "beta", and has not changed since
2019. The free tier caps a network at 5 members. Every friend installs
Hamachi. playit.gg (below) is the other half: no client install for
friends. The two can coexist.

**Steps (Hamachi)**

- [ ] `apps/hamachi`: kind=systemd adopt (`unit:logmein-hamachi.service
      bin:hamachi`), stateful, `backup_paths="/var/lib/logmein-hamachi"`,
      no ports. Install path: the vendor .deb from vpn.net/linux.
- [ ] `status`: parse `hamachi` output for online/offline, nick, and the
      ham0 address. Note the `hamachi` CLI needs root; read-only status
      must still not break without sudo (hard rule 5).
- [ ] Hub UI for Hamachi (there are no per-app pages yet; `/update` is the
      precedent for a standalone page): show online state, the 25.x
      address, the networks and who is in them (online/offline); buttons
      for go-online/offline, create network, set password, approve or
      evict a member. Every action goes through a `homelab` verb, never a
      raw `hamachi` call from the hub.
- [ ] Show "how to join" per game on that page: network name + password,
      then `25.28.0.159:34197` for Factorio.
- [ ] Test in the VM first, then adopt on the NUC (it is running there now;
      adopting must change nothing).
### playit.gg

A relay made for game servers: the agent dials out to playit.gg, which gives
each tunnel a public address. Handles UDP, no port forwarding, works behind
CGNAT, and **friends install nothing** - they type the address into
Factorio. The trade: the address is public, so the game needs its own
password. Free tier has bandwidth limits and throttles heavy traffic.
Tunnels are created and listed on the playit.gg dashboard; the agent has no
local UI.

Already on the NUC (checked 2026-09-13), not in the catalog:

- `playit` 0.17.1 (deb). The agent is at 1.0.10 upstream; 1.0.10 fixed
  "permission issues when upgrading from pre 1.0".
- **Inactive and disabled**; last ran until 2026-04-10.
- The packaged unit (`/lib/systemd/system/playit.service`) runs
  `playit --secret_wait --secret_path /etc/playit/playit.toml start`. It is
  **shadowed** by a hand-made `/etc/systemd/system/playit.service` that
  wraps the agent in `screen` as server_admin, so the secret lives in
  `~server_admin/.config/playit_gg/playit.toml`, mode 664.
- `/etc/playit` exists, is empty, and is mode **777**.

**Steps (playit.gg)**

- [ ] Before anything starts it: check the playit.gg dashboard for tunnels
      left from April. Starting the agent republishes every tunnel on the
      account, to the internet.
- [ ] `apps/playit`: kind=systemd adopt (`unit:playit.service bin:playit`),
      stateful, `backup_paths="/etc/playit"`, no local ports.
- [ ] Move to the packaged unit: secret into `/etc/playit/playit.toml`
      (root, 0600), `/etc/playit` to 0700, drop the screen override. VM
      first, every step through `run`/`run_write` behind `--apply`.
- [ ] Upgrade 0.17.1 to 1.0.x (playit's apt repo); confirm 1.0 keeps
      `--secret_path` and the unit before relying on either.
- [ ] Factorio: a UDP tunnel to `127.0.0.1:34197` on the dashboard, and a
      game password in AMP. Never tunnel the AMP panel, cockpit or the hub.
- [ ] Hub UI: agent online/offline, the claim link on first setup (the
      agent prints one), a link to the dashboard, and the tunnel address
      friends type in, if the agent or API exposes it (unverified).
- [ ] Decide per game: Hamachi (private network, 5-member cap, friends
      install a client) or playit (public address, game password,
      nothing to install). Both on one hub page: "friends access".
