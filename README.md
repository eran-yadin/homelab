# homelab

An app store for my own server. Pick apps from a catalog, install them onto a
fresh box, and manage them from one hub — with a sterile VM to test all of it
before anything touches the real machine.

Target hardware: `nucserver`, an Intel i3-7100U / 16 GB / single 500 GB SSD
running Debian 13, currently hosting paperless-ngx, Immich, a transcription
service, AMP, Cockpit, Feishin, caddy and the hub.

## Status

Running on **nucserver** (10.0.0.5) since 2026-08-30.

- [x] **app lifecycle contract** + catalog — see [docs/CONTRACT.md](docs/CONTRACT.md)
- [x] **`homelab` CLI** — detect / list / info / setup / install / download / start / stop / restart / update / delete / status / backup / restore / migrate / deploy / update self / version
- [x] **`homelab setup`** — pick apps from the store on a new machine, dependencies resolved for you
- [x] inherited implementations for `kind=compose`, `kind=systemd`, `kind=container`
- [x] **22 apps**, most of them declarative only (an `app.conf` and a `compose.yml`, no scripts)
- [x] **hub** — web front end, custom filters, reboot, Local/Tailscale link toggle, an **Update** button with a live progress page, the deployed version, and a [/docs](hub/docs.html) page
- [x] **releases** — git tags; `homelab update self` installs the newest tag, backs up first, smoke-tests, rolls back on failure. See [CHANGELOG.md](CHANGELOG.md)
- [x] **`testenv/`** — disposable Debian 13 QEMU VM, resets in seconds
- [x] `tests/conformance.sh` — drives every app through its whole lifecycle
- [x] **backup / restore / `migrate`** — verified end to end against the live paperless data
- [x] adopting the services already running on nucserver (AMP, Cockpit, Feishin)
- [x] **deployed to nucserver** — hub on :7070, caddy fronting :80, nginx retired
- [x] **Immich** installed on nucserver (v1.1.0)
- [ ] taking paperless itself into the catalog (see below)
- [ ] unified search across all apps, HTTPS on the LAN — planned in [tasks.md](tasks.md)

## What is deployed

| | |
|---|---|
| hub | `:7070`, and `http://10.0.0.5/` through caddy |
| immich | `:2283` — four containers, data in `immich_library` / `immich_pgdata` |
| caddy | `:80` / `:443`, host networking, routes generated from the catalog into `/etc/caddy/sites` |
| routes | `hub.nuc` `paperless.nuc` `transcribe.nuc` `amp.nuc` `cockpit.nuc` `feishin.nuc` — they need DNS (AdGuard, the router, or a hosts file); rerun `homelab download caddy --apply` after installing an app to add its route |
| adopted | amp (`ampinstmgr`), cockpit (`cockpit.socket`), feishin (a bare `docker run` container) |
| retired | nginx — disabled, not purged, so the swap reverses with one command |

The hub's sudoers rule is scoped to `/opt/homelab/homelab` plus `systemctl
reboot|poweroff`, replacing the previous `systemctl start *` wildcard, which
was root-equivalent: `systemctl start` accepts a path to any unit file,
including one the caller just wrote.

## Releases and updating

Releases are git tags. To ship a change to the server: test it in the VM,
tag it, push, and let the deployed engine update itself:

    git tag -a v1.1.0 -m "what changed" && git push origin main v1.1.0
    ssh nucserver 'sudo -n /opt/homelab/homelab update self --apply'

`update self` fetches `~/homelab` (a git clone on the NUC) and installs the
newest `v*` tag, the **stable** channel. A push to `main` changes nothing on
the box until it is tagged. It backs up `/opt/homelab` and `/opt/homelab-hub`
to `~/backups/homelab-self-<timestamp>/`, deploys, restarts the hub, and
smoke-tests it: the hub answers on :7070, `status --json` parses, and every
app that was running still is. If that fails it redeploys the backup. Without
`--apply` it only fetches and reports. Exit 2 means nothing was new.

    homelab update self --channel main --apply   # follow the branch instead
    homelab update self --to v1.0.0 --apply      # exactly that tag, e.g. to go back
    homelab update self --to 8afd747 --apply     # or a commit / branch, to try it before tagging
    homelab version                              # what is deployed here

A channel never moves backwards on its own: if `main` was deployed by hand
and is ahead of the newest tag, stable reports nothing to do until a newer
tag exists. `--to` is the explicit way back.

One-time setup on the NUC: `git clone https://github.com/eran-yadin/homelab.git ~/homelab`.

The hub's **Update** button does the same thing for people without a
terminal: it opens a tab that starts `update self --detach` and shows the
server's output as it runs. The update runs as its own systemd unit, so
closing the tab, or the hub restarting itself halfway, does not stop it.

To deploy an uncommitted local tree instead (the old way):

    tar czf - --exclude=.git . | ssh nucserver 'rm -rf ~/homelab && mkdir -p ~/homelab && tar xzf - -C ~/homelab'
    ssh nucserver 'sudo -n /opt/homelab/homelab deploy --from ~/homelab --apply'

Do not do that from a Windows checkout: git there turns the symlinks under
`apps/hub/files/` into one-line text files, and deploying them replaces the
hub's `server.py` with a path.

### Deliberately left alone

**paperless** runs outside the catalog, from `~/paperless/docker-compose.yml`.
The engine refuses to recreate containers created from a different compose
file, so nothing here can touch it by accident. Taking it over is a decision,
not a default:

    homelab backup paperless <dir> --apply
    docker compose -f ~/paperless/docker-compose.yml down
    homelab restore paperless <dir> --apply && homelab start paperless --apply

That exact sequence was rehearsed in the VM against the real 203 documents.

**netmon** has been stopped since 2026-08-06 and has a 180 MB unmerged WAL
beside a 259 MB database. Starting it will replay and checkpoint that. Left for
its owner.

## The store

| category | apps |
|---|---|
| ai | ollama |
| base | docker, hub |
| gaming | amp *(adopted)* |
| documents | paperless, transcribe |
| files | manyfold, syncthing |
| home | home-assistant |
| media | feishin *(adopted)*, immich, jellyfin, navidrome, stremio-server |
| network | adguard, headscale, netmon, tailscale |
| ops | caddy, uptime-kuma |
| security | vaultwarden |
| system | cockpit *(adopted)* |

## The idea in one paragraph

Every app implements the same six shell verbs — `download`, `start`, `stop`,
`update`, `delete`, `status` — plus `backup`/`restore` if it holds data. The hub
never knows about specific apps: it reads the catalog directory and parses the
one JSON line that `status` emits. So adding an app later means dropping a
directory in `apps/`, with no change to the hub or the engine. Most apps ship
only an `app.conf` and a `compose.yml` and inherit the six verbs from their
`kind` (`compose` / `systemd` / `container`).

Nothing runs for real without `--apply`, and `--apply` refuses on any host
lacking `/etc/homelab/allow-apply`.

## Getting started

On a new server:

    ./homelab setup            # look, pick, dry run
    ./homelab setup --apply    # actually install

To develop against the throwaway VM instead:

    cd testenv
    make build     # once, downloads the golden image
    make up && make sync
    make ssh

The VM needs QEMU and KVM, which the NUC does not have. When it is not
available, a compose app can be tried on a laptop with Docker Desktop:
`docker compose -p test --project-directory apps/<app>/files -f apps/<app>/files/compose.yml --env-file <rendered env> up -d`.
That is how Immich was verified before v1.1.0.

## Plans and history

[tasks.md](tasks.md) is the running plan: what was done, what is next, and
the design for bigger items such as unified search. [CHANGELOG.md](CHANGELOG.md)
has one line per change, grouped by release.

## Backups taken so far

paperless-ngx, 2026-08-30, 203 documents — three independent restore paths
(portable `document_exporter` zip, `pg_dump`, raw volume tars), verified by
sha256 and archive integrity check. Stored on DRIVE 2 at
`backups/nucserver/paperless-2026-08-30/`, not in this repo.
