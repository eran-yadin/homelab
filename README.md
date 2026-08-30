# homelab

An app store for my own server. Pick apps from a catalog, install them onto a
fresh box, and manage them from one hub — with a sterile VM to test all of it
before anything touches the real machine.

Target hardware: `nucserver`, an Intel i3-7100U / 16 GB / single 500 GB SSD
running Debian 13, currently hosting paperless-ngx, navidrome, a transcription
service, netmon, and a small status hub.

## Status

Early. What exists today:

- [x] **`testenv/`** — disposable Debian 13 QEMU VM, resets in seconds
- [x] Verified backup of the live paperless instance (see below)
- [x] **app lifecycle contract** + catalog — see [docs/CONTRACT.md](docs/CONTRACT.md)
- [x] **`homelab` CLI** — detect / list / info / install / download / start / stop / update / delete / status / backup / restore
- [x] inherited implementations for `kind=compose` and `kind=systemd`
- [x] apps: `docker`, `paperless`, `netmon`
- [x] `tests/conformance.sh` — drives every app through its whole lifecycle
- [ ] hub web front-end
- [ ] `migrate` from the old server
- [ ] more apps: caddy, mesh (tailscale/headscale), navidrome, transcribe, jellyfin

See [docs/PLAN.md](docs/PLAN.md) for the full design.

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

    cd testenv
    make build     # once, downloads the golden image
    make up
    make ssh

## Backups taken so far

paperless-ngx, 2026-08-30, 203 documents — three independent restore paths
(portable `document_exporter` zip, `pg_dump`, raw volume tars), verified by
sha256 and archive integrity check. Stored on DRIVE 2 at
`backups/nucserver/paperless-2026-08-30/`, not in this repo.
