# homelab

An app store for my own server. Pick apps from a catalog, install them onto a
fresh box, and manage them from one hub — with a sterile VM to test all of it
before anything touches the real machine.

Target hardware: `nucserver`, an Intel i3-7100U / 16 GB / single 500 GB SSD
running Debian 13, currently hosting paperless-ngx, navidrome, a transcription
service, netmon, and a small status hub.

## Status

Running on **nucserver** (10.0.0.5) since 2026-08-30.

- [x] **app lifecycle contract** + catalog — see [docs/CONTRACT.md](docs/CONTRACT.md)
- [x] **`homelab` CLI** — detect / list / info / setup / install / download / start / stop / restart / update / delete / status / backup / restore / migrate / deploy
- [x] **`homelab setup`** — pick apps from the store on a new machine, dependencies resolved for you
- [x] inherited implementations for `kind=compose`, `kind=systemd`, `kind=container`
- [x] **20 apps**, most of them declarative only (an `app.conf` and a `compose.yml`, no scripts)
- [x] **hub** — web front end, custom filters, reboot, Local/Tailscale link toggle, and a [/docs](hub/docs.html) page
- [x] **`testenv/`** — disposable Debian 13 QEMU VM, resets in seconds
- [x] `tests/conformance.sh` — drives every app through its whole lifecycle
- [x] **backup / restore / `migrate`** — verified end to end against the live paperless data
- [x] adopting the services already running on nucserver (AMP, Cockpit, Feishin)
- [x] **deployed to nucserver** — hub on :7070, caddy fronting :80, nginx retired
- [ ] taking paperless itself into the catalog (see below)

## What is deployed

| | |
|---|---|
| hub | `:7070`, and `http://10.0.0.5/` through caddy |
| caddy | `:80` / `:443`, host networking, routes generated from the catalog into `/etc/caddy/sites` |
| routes | `hub.nuc` `paperless.nuc` `amp.nuc` `cockpit.nuc` `feishin.nuc` — they need DNS (AdGuard, the router, or a hosts file) |
| adopted | amp (`ampinstmgr`), cockpit (`cockpit.socket`), feishin (a bare `docker run` container) |
| retired | nginx — disabled, not purged, so the swap reverses with one command |

The hub's sudoers rule is scoped to `/opt/homelab/homelab` plus `systemctl
reboot|poweroff`, replacing the previous `systemctl start *` wildcard, which
was root-equivalent: `systemctl start` accepts a path to any unit file,
including one the caller just wrote.

To ship a change to the server:

    tar czf - --exclude=.git . | ssh nucserver 'rm -rf ~/homelab && mkdir -p ~/homelab && tar xzf - -C ~/homelab'
    ssh nucserver 'sudo -n /opt/homelab/homelab deploy --from ~/homelab --apply'

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
| base | docker, hub |
| gaming | amp *(adopted)* |
| documents | paperless, transcribe |
| files | manyfold, syncthing |
| home | home-assistant |
| media | feishin *(adopted)*, jellyfin, navidrome, stremio-server |
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
`kind` (`compose` / `systemd` / `binary`).

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

## Backups taken so far

paperless-ngx, 2026-08-30, 203 documents — three independent restore paths
(portable `document_exporter` zip, `pg_dump`, raw volume tars), verified by
sha256 and archive integrity check. Stored on DRIVE 2 at
`backups/nucserver/paperless-2026-08-30/`, not in this repo.
