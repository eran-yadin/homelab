# homelab

An app store for my own server. Pick apps from a catalog, install them onto a
fresh box, and manage them from one hub — with a sterile VM to test all of it
before anything touches the real machine.

Target hardware: `nucserver`, an Intel i3-7100U / 16 GB / single 500 GB SSD
running Debian 13, currently hosting paperless-ngx, navidrome, a transcription
service, netmon, and a small status hub.

## Status

What works today:

- [x] **app lifecycle contract** + catalog — see [docs/CONTRACT.md](docs/CONTRACT.md)
- [x] **`homelab` CLI** — detect / list / info / setup / install / download / start / stop / restart / update / delete / status / backup / restore
- [x] **`homelab setup`** — pick apps from the store on a new machine, dependencies resolved for you
- [x] inherited implementations for `kind=compose` and `kind=systemd`
- [x] **20 apps**, most of them declarative only (an `app.conf` and a `compose.yml`, no scripts)
- [x] **hub** — web front end, custom filters, reboot, Local/Tailscale link toggle
- [x] **`testenv/`** — disposable Debian 13 QEMU VM, resets in seconds
- [x] `tests/conformance.sh` — drives every app through its whole lifecycle
- [x] Verified backup of the live paperless instance (see below)
- [ ] `migrate` from the old server
- [x] adopting the services already running on nucserver (AMP, Cockpit, Feishin)
- [ ] deployment to nucserver itself

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
