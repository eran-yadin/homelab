# homelab — project instructions

An app store for a personal server. Pick apps from a catalog, install them onto
a machine, manage them from one hub. Runs on **nucserver** (10.0.0.5, Debian 13,
i3-7100U, 4 threads, 16 GB, single 500 GB SSD).

## Hard rules

1. **Nothing changes without `--apply`.** Every command is a dry run by default.
   `--apply` additionally refuses on any host lacking `/etc/homelab/allow-apply`.
2. **Test in the VM before the real server.** `cd testenv && make up && make sync`.
   It resets in seconds; the NUC holds years of scanned documents.
3. **App scripts never call `docker` / `systemctl` / `apt` directly.** They call
   `run`, `run_sh`, `run_write`. That is the entire dry-run mechanism — an app
   cannot forget to honour it.
4. **`sudo` on the NUC needs a password**, which an agent cannot supply. Only
   `/opt/homelab/homelab` is passwordless there. To ship code: tag a release
   (`git tag -a vX.Y.Z`), push main and the tag, then
   `sudo -n /opt/homelab/homelab update self --apply` (installs the newest
   tag; backs up, deploys, smoke-tests, rolls back on failure). A push to
   main alone changes nothing on the NUC. `--channel main` follows the
   branch, `--to vX.Y.Z` pins or goes back, `deploy --from ~/homelab --apply`
   deploys an uncommitted tree.
5. **Read-only queries must not use sudo.** `systemctl cat/is-active/is-enabled/
   show` and `ss` all work unprivileged. Using sudo makes them fail on any host
   without blanket NOPASSWD, and a failed "does this exist?" reads as *absent*.

## Layout

```
homelab              the CLI
lib/contract.sh      the contract app scripts source; run() and the dry-run gate
lib/kinds/*.sh       default verb implementations apps inherit
lib/{catalog,detect,common}.sh
apps/<name>/         app.conf, optional <verb>.sh, files/
hub/                 web front end (Flask + a static page)
tests/               conformance.sh, checkjs.py
testenv/             disposable Debian VM
docs/CONTRACT.md     the full contract
```

## Adding an app

See `.claude/skills/homelab-app/SKILL.md` — invoke it for the full procedure.
In short: most apps are an `app.conf` plus a `files/compose.yml` and **no
scripts at all**. Then test it in the VM, never on the NUC first.

## What is deployed on nucserver

- **hub** on :7070, **caddy** on :80/:443 (host networking, routes generated
  from the catalog into `/etc/caddy/sites`), nginx disabled
- **adopted, not installed by us**: amp (ampinstmgr), cockpit (cockpit.socket),
  feishin (a bare `docker run` container)
- **paperless is deliberately outside the catalog.** Its containers were created
  from `~/paperless/docker-compose.yml`; the engine refuses to recreate
  containers built from a different compose file, so it is safe from us. Taking
  it over means backup → bring the old stack down → restore → start.
- **netmon is stopped** since 2026-08-06 and has a 180 MB unmerged WAL beside a
  259 MB database. The user has plans for it — leave it alone.

## Gotchas already paid for

Each of these cost a debugging cycle. Do not rediscover them.

- **Root-owned named volumes.** Docker populates a fresh named volume from the
  image, so it arrives owned by root. An image running as a non-root PUID then
  cannot write — SQLite reports "attempt to write a readonly database", and
  syncthing restart-loops. Fix with a one-shot init service that chowns it, and
  declare `oneshot="init-perms"` so it is excluded from the running counts.
- **Distroless images** (headscale) have no `/bin/sh`, so *no* Docker
  healthcheck can run. Declare `health_url` and the engine probes from the host.
- **`curl` is often absent** from an image; check before using it in a
  healthcheck. `localhost` may resolve to `::1` while the app binds IPv4 only.
- **`:latest` on a stateful app is a hazard.** Paperless built 3.1.0 from
  `:latest` while the NUC ran 2.20.13, and an export only imports into the
  version it came from. Pin, and treat the pin as a declared version.
- **An app's own exporter can silently drop rows.** paperless-ngx 2.20.13's
  `document_exporter` left one note of twenty out of its manifest. Prefer
  `homelab backup`/`restore`, which copies volumes byte for byte.
- **`[ cond ] && action` as the last line of a function** returns 1 and, under
  `set -e`, kills the caller. This made `homelab detect` exit silently with no
  output on every host without the allow-apply marker.
- **`tr -dc … </dev/urandom | head -c N`** kills `tr` with SIGPIPE; with
  `pipefail` and `set -e` the script aborts with no message at all.
- **The test VM gives its user blanket NOPASSWD sudo.** That has hidden two real
  permissions bugs. It is a faithful machine but a misleading user.

## Verifying

```
tests/conformance.sh [app]     # full lifecycle; refuses outside the test VM
tests/checkjs.py               # hub JS structure (no JS engine on this machine)
```
