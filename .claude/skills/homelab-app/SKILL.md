---
name: homelab-app
description: Turn any self-hosted app into a homelab catalog entry, or fix one that misbehaves. Use when adding an app to the app store, adopting a service already running on the server, or when an installed app reports the wrong state. Covers app.conf, the compose/systemd/container kinds, and the traps that only appear when you actually run it.
---

# Adding an app to the store

The goal is an app that installs, starts, stops, updates, deletes, reports its
state and (if it holds data) backs up — **without writing any scripts**, because
it inherits all of that from its `kind`.

## 1. Find out what it actually needs

Do not write the compose file from memory. Fetch the project's own install
docs and reproduce their image name, ports, volumes and required environment.
Note specifically:

- the **exact image**, and whether an all-in-one variant exists (fewer moving
  parts suits a small box)
- **required** environment variables, especially any secret key
- whether it needs **host networking** (device discovery via mDNS/SSDP, or local
  peer discovery, does not cross a docker bridge)
- whether it wants a **device** (`/dev/dri`, a USB dongle)

## 2. Write app.conf

```sh
kind="compose"          # inherits all eight verbs
title="Jellyfin"
category="media"        # groups it in list and the hub; any name works
desc="One line. Shown on the card."
homepage="https://…"
ports="8096"            # first port is what the hub links to
requires="docker"
stateful=1              # has data worth backing up; makes --purge prompt
needs_ram_mb=1024
detect="container:jellyfin"    # probes: container: unit: bin: path: port:
```

`detect` probes are **ANDed** — list one container name, not alternatives, or
the app can never read as fully installed.

Extra fields when needed: `oneshot`, `health_url`, `conflicts`, `adopted`,
`container`, `unit`, `backup_paths`, `purge_paths`, `purge_users`. See
`docs/CONTRACT.md`.

## 3. Write files/compose.yml

Named volumes for data — that is what makes `backup`/`restore` and
`delete --purge` work uniformly. Secrets go in `files/env.template` as
`@@SECRET:32@@`, rendered once at install and never rewritten.

**Pin the image version** for anything stateful. `:latest` means a routine
`update` can carry a database across a major version unattended.

## 4. Then run it, in the VM

```
cd testenv && make up && make sync
ssh homelab-test 'cd ~/homelab && ./homelab install <app> --apply'
```

This is not optional. Every app added so far has had at least one defect that
only appeared on first run.

## The traps, in the order you will hit them

**The volume is owned by root.** Docker populates a fresh named volume from the
image, so it arrives root-owned. An image running as a non-root `PUID` cannot
write into it — SQLite says "attempt to write a readonly database", syncthing
restart-loops. Fix with a one-shot init:

```yaml
services:
  init-perms:
    image: alpine:3
    command: ["sh", "-c", "chown -R ${PUID:-1000}:${PGID:-1000} /config"]
    volumes: [config:/config]
    restart: "no"
  theapp:
    depends_on:
      init-perms: {condition: service_completed_successfully}
```

and `oneshot="init-perms"` in app.conf, or the exited init counts as a stopped
service and the app reads *degraded* forever.

**The healthcheck cannot run.** Check the image actually has what you call:
many have no `curl`, only `wget`; distroless images have no shell at all, so no
Docker healthcheck works — use `health_url` instead. Use `127.0.0.1`, not
`localhost`, which may resolve to `::1` while the app binds IPv4 only. And check
what `/` returns: an app that redirects to a login page can send `wget` into a
loop.

**A missing device is a hard failure.** Docker refuses to start a container
whose `devices:` entry is absent, so never map `/dev/dri` unconditionally.
Leave it out of the compose file and write `$APP_STATE/compose.override.yml`
from `download.sh` only when the hardware exists — see `apps/jellyfin`.

**YAML folded scalars keep the newline** when the continuation line is more
indented, which splits a shell command in half. Use a list: `["sh","-c","…"]`.

**The port may be taken.** Declare `conflicts="unit:nginx.service"` for known
clashes. Port checks happen automatically from `ports=`.

## Adopting something already running

For a service that predates the catalog, set `adopted=1`. `download` becomes a
no-op that verifies it exists, and **`delete` refuses** — removing something you
did not install, by a route that never installed it, is how data disappears.
Use `kind=systemd` with `unit=`, or `kind=container` with `container=` for a
bare `docker run` container.

Do **not** point a compose app at containers created from someone else's compose
file. The engine refuses this, and the refusal is right: recreating them from
your file hands a running database freshly generated credentials.

## Finally

```
tests/conformance.sh <app>     # in the VM; drives the whole lifecycle
```

13 assertions: every verb, idempotency (a second `start` must return 2, not
redo the work), and that `status` emits exactly one line of valid JSON.
