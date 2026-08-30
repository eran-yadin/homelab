# `homelab` — an app store for your own server, with the hub as its face

## Context

`nucserver` (10.0.0.5) grew organically: services scattered across `~server_admin/`, `/opt/`,
root-owned dirs and one-off `install.sh` scripts, each one a snowflake. There's no way to
reproduce the box, no single view of what's on it, and adding the next app means writing another
snowflake.

The target is an **app store for your own server**. Three decisions shape it:

1. **The store *is* homelab-hub.** The Flask dashboard already running on :7070 becomes the web
   face of the store — browse, install, start/stop, update, delete. The CLI and the hub are the
   same engine; the hub is a thin front-end over it.
2. **One lifecycle contract for every app.** Every app implements the same verbs —
   `download / start / stop / update / delete / status`. The hub knows nothing about any specific
   app; it only knows the contract. **Drop a new app directory in and it appears in the hub with
   zero hub changes**, forever.
3. **A sterile test environment.** All of this is developed and exercised against a throwaway
   Debian 13 VM, never against nucserver. Reset to pristine in about a second.

This is your own server, so the bias is simple and convenient — not hardened. Sane defaults
(generated passwords instead of `changeme`, backups that exist) only where they cost nothing.

**Nothing is activated.** `--dry-run` is the default, `--apply` is opt-in, and `--apply` refuses
to run on any host lacking an explicit opt-in marker file. nucserver will not have that marker
until you put it there.

### The catalog seed — what's on the NUC (verified over SSH, 2026-08-27)

| App | Where it lives now | State |
|---|---|---|
| paperless-ngx + postgres:16 + redis:7 | `~/paperless/docker-compose.yml`; custom image adds `tesseract-ocr-heb` | Up 2 weeks, :8010 |
| navidrome + feishin (music) | bare `docker run`, data in root-owned `~/navidrome` | Exited 0, 8 days |
| transcribe (Flask + faster-whisper, `ivrit-ai/whisper-large-v3-turbo-ct2`) | `/opt/transcribe` (stale dup at `~/transcribe-app`) | image built, **container gone** |
| netmon (latency/loss monitor) | `/opt/netmon` + a well-hardened unit, sqlite in `/var/lib/netmon` | running |
| homelab-hub (Flask dashboard) | `/opt/homelab-hub` | running, :7070 |
| AMP (CubeCoders `ampinstmgr` v2.8) | `/opt/cubecoders/amp` | running, :8080/:8081, games :2223/:2224 |
| playit.gg agent / ut99 / logmein-hamachi | `/opt/playit`, `/opt/ut99`, `/opt/logmein-hamachi` | hamachi running |
| cockpit, nginx (stock default only), tailscale, ollama (inactive) | system | — |

Two corrections to `~/.claude/CLAUDE.md`: **:7070 is homelab-hub, not AMP**, and the **tailnet
split is resolved** — the NUC's `tailscale status` now lists `cachy-rig 100.111.49.33`.

---

## 1. The lifecycle contract

This is the heart of the project. Every app in the store is a directory implementing the same
six verbs, so the hub, the CLI, and the backup system all drive every app identically.

```
apps/<name>/
├─ app.conf          # the store listing + metadata
├─ download.sh       # acquire: pull/build images, apt deps, make dirs+users, write configs & units.
│                    #          Does NOT start anything.
├─ start.sh          # bring up + enable at boot
├─ stop.sh           # bring down, keep data
├─ update.sh         # fetch newer version, restart
├─ delete.sh         # remove the app.  --purge also removes its data.
├─ status.sh         # READ-ONLY. prints one line of JSON. The hub's only parsing surface.
├─ backup.sh / restore.sh     # only if app.conf says stateful=1
└─ files/            # units, Dockerfiles, configs, compose.yml
```

**Rules that make the contract hold:**

- Every script is sourced with `lib/contract.sh`, which hands it `run()`, `log/ok/warn/fail`,
  and `$APP_DIR $DATA_DIR $APP_NAME` plus config vars. Scripts never call `docker`/`systemctl`
  directly — they call `run docker ...`, and `run()` prints-instead-of-executes in dry-run.
- Every verb is **idempotent**: `start` on a running app succeeds and changes nothing.
- Exit codes: `0` success, `2` nothing-to-do, anything else is failure with a message.
- `status.sh` prints exactly: `{"state":"running|stopped|absent","health":"ok|bad|unknown","url":"http://…","version":"…"}`

**Most apps write zero scripts.** `lib/kinds/compose.sh`, `lib/kinds/systemd.sh` and
`lib/kinds/binary.sh` provide default implementations of all six verbs. An ordinary containerized
app is just:

```sh
# apps/jellyfin/app.conf
kind="compose"                 # ⇒ inherits download/start/stop/update/delete/status
title="Jellyfin";  category="media"
desc="Movies and TV. Hardware transcoding if the box has a GPU."
ports="8096";  needs_ram_mb=1024;  stateful=1
detect="container:jellyfin"
```

…plus a `files/compose.yml`. That's the whole app. An app only writes its own `start.sh` etc.
when it's genuinely unusual — AMP, playit, netmon, hamachi. **Standardize the interface, inherit
the implementation.** That's what keeps adding an app cheap.

---

## 2. The engine and the hub

```
~/Projects/homelab/          →  deploys to /opt/homelab
├─ homelab                   # CLI — the engine. Every action goes through here.
├─ lib/
│  ├─ contract.sh            # what each app script gets sourced with; run() / dry-run gate
│  ├─ kinds/{compose,systemd,binary}.sh    # default verb implementations
│  ├─ detect.sh              # OS/env probe + "what's already installed"
│  ├─ pkg.sh                 # apt|dnf|pacman abstraction
│  ├─ ui.sh                  # whiptail catalog + plain-numbered fallback, logging
│  └─ secrets.sh             # gen_secret → chmod 600 .env
├─ hub/                      # the web store — Flask, thin front over `homelab --json`
│  ├─ server.py
│  └─ templates/ static/
├─ apps/<name>/              # THE CATALOG (contract above)
└─ testenv/                  # sterile VM (section 3)
```

### CLI

```
homelab detect                       # OS/env + what's already installed. Read-only.
homelab list [category]              # the catalog: [installed] [available] [n/a on this OS]
homelab info paperless               # the store listing
homelab install                      # interactive catalog checklist → DRY RUN
homelab install --apply              # = download + start, for each ticked app
homelab install jellyfin immich --apply
homelab start|stop|update <app>
homelab delete <app> [--purge]       # --purge confirms before touching data
homelab status [--all] [--json]      # ← what the hub calls
homelab backup|restore [app]
homelab migrate --from server_admin@10.0.0.5
```

### The hub is the store's front end

`hub/server.py` renders a grid of app cards from `homelab status --all --json`, and every button
shells out to the same CLI: Install → `homelab install <app> --apply`, plus Start / Stop / Update
/ Delete, streaming the output to the browser as it runs. Because the hub reads the catalog
directory and the contract — never a hardcoded list — **an app added next year needs no hub
change**. This is exactly why the contract is worth the up-front structure.

The hub is itself `apps/hub/` in the catalog, so it can update itself.

**Privilege:** the hub runs as your user; the verbs need root. One narrow sudoers line —
`NOPASSWD: /opt/homelab/homelab` — replaces the current
`NOPASSWD: /bin/systemctl start *, stop *, restart *`, which is a root shell in disguise.

---

## 3. The sterile test environment

You have `qemu-system-x86_64` + a usable `/dev/kvm` + 552 GB free, and no libvirt/vagrant.
So: **a plain QEMU/KVM VM, no libvirt** — the only genuinely sterile option for something that
installs apt packages, systemd units, Docker and firewall rules.

```
testenv/
├─ Makefile
├─ cloud-init/{user-data,meta-data}    # injects your SSH key, enables the apply-marker
└─ .gitignore                          # images are never committed
```

```
make testenv-build   # fetch the Debian 13 generic cloud qcow2 → golden.qcow2 (once)
make testenv-up      # overlay.qcow2 backed by golden.qcow2, boot headless, SSH on :2222
make testenv-ssh     # ssh -p 2222 homelab@localhost
make testenv-reset   # rm overlay.qcow2 → recreate. Back to pristine in ~1 second.
make testenv-down
```

The overlay-on-backing-file trick is what makes this pleasant: reset is deleting one file, so you
can run a destructive `delete --purge` test, reset, and re-run in seconds. Same OS as the NUC
(Debian 13), so what passes here is what will run there. Needs `cloud-image-utils` for
`cloud-localds` — or fall back to building the seed ISO with `xorriso`.

**The guard that keeps this off your real boxes:** `--apply` refuses to run unless
`/etc/homelab/allow-apply` exists. Cloud-init creates it in the VM. nucserver and cachy-rig do
not have it and will not get it until you create it by hand.

---

## 4. Catalog contents

**Infrastructure** — pulled in as `requires`, not really browsed
- `base` — timezone, baseline packages, `unattended-upgrades` (the NUC is 211 packages behind)
- `docker` — Docker CE + compose plugin, your user in the `docker` group, container log-size caps
- `mesh` — **one of `tailscale` | `headscale` | none.** Tailscale joins with an auth key;
  Headscale self-hosts the coordination server, fully open source, and prints you a preauth key
- `caddy` — optional: one hostname per app with automatic TLS so you stop memorizing port
  numbers. Apps drop a route fragment into `/etc/caddy/homelab.d/<app>.caddy`. LAN-only mode
  with an internal CA when there's no public domain

**Ported from the NUC**, fixed on the way in
- `paperless` — same compose, but `POSTGRES_PASSWORD` / `PAPERLESS_SECRET_KEY` generated into a
  `chmod 600 .env` (today they are literally `paperless` and `changeme-use-a-long-random-string`),
  and healthchecks on db + broker so a wedged postgres stops reporting `Up`. Volumes and the
  Hebrew-tesseract image carry over. Still :8010.
- `navidrome` — navidrome + feishin promoted from bare `docker run` into compose, data dir owned
  by you rather than root, configurable music path
- `transcribe` — vendored from `/opt/transcribe` (newer of the two copies). Keeps the CPU tuning
  but derives `WHISPER_THREADS` from detected cores instead of a hardcoded `3`, and keeps the
  model-cache volume so a rebuild doesn't re-pull the ~1.5 GB ivrit-ai model
- `netmon` — `kind=systemd`, unit ported as-is (it's good: `NoNewPrivileges`, `ProtectSystem=strict`,
  `CAP_NET_RAW` only), gateway auto-detected by `lib/detect.sh` instead of a `sed` patch
- `homelab-hub` — now `apps/hub/`, see above
- `amp`, `playit`, `hamachi` (optional, legacy) — the custom-script apps

**New — the gaps**
- `backup` — **restic** to B2 / rsync.net / a local disk on a systemd timer, calling each app's
  `backup.sh`. `homelab backup --verify` runs `restic check` *and a test restore into a scratch
  dir*. The NUC's entire backup story is one 4.5 MB tgz on the same SSD as the data, and
  paperless holds years of scans with zero copies. Highest-value entry in the catalog.
- `uptime-kuma`, `dozzle` (container logs), `cockpit`

**New — to browse**
- Media: `jellyfin` (offers QuickSync passthrough when `/dev/dri` is present — the NUC's HD 620
  has it, unused), `immich`
- Tools: `vaultwarden`, `forgejo`, `nextcloud`
- Network/home: `adguard`, `home-assistant`, `wireguard` (flagged redundant if Tailscale is on)

---

## 5. Migration off the NUC

`backup.sh`/`restore.sh` are contract verbs, so the backup app and migration share one mechanism.
`homelab migrate --from server_admin@10.0.0.5`:

1. SSH the source, run each selected app's `backup.sh` into a staging tarball
2. rsync the bundle over
3. `download` + `restore` + `start` each app on the new box
4. print a check: paperless doc count before/after, navidrome song count, transcribe row count

Source side is read-only apart from writing its own tarball. It needs `sudo` for the root-owned
`~/navidrome` and `/opt/transcribe/data` — `server_admin` has sudo but it prompts, so migration
is interactive.

---

## Build order

1. `testenv/` first — nothing else can be tested honestly without it.
2. `lib/contract.sh` + `lib/kinds/compose.sh` + the `homelab` CLI skeleton (`detect`, `list`,
   dry-run plumbing, the apply-marker guard).
3. Two proof apps against the contract: `paperless` (`kind=compose`, inherits everything) and
   `netmon` (`kind=systemd`, custom scripts). If both work through identical verbs, the contract
   is sound; if not, fix it now before there are twenty apps.
4. The hub rewritten as a front-end over `homelab --json`.
5. `base` / `docker` / `mesh` / `caddy`, then the rest of the NUC apps.
6. `backup` + per-app backup/restore → `migrate`.
7. Fill out the browse catalog.

## Verification

- `shellcheck` clean across `homelab`, `lib/`, `apps/*/*.sh`.
- **Contract conformance test** — `testenv/conformance.sh` runs every app in the catalog through
  `download → status → start → status → stop → status → start → update → delete --purge → status`
  in the VM, asserting idempotency (each verb twice = same result) and that `status.sh` emits
  valid JSON at every stage. This is the test that keeps future apps honest.
- `homelab detect` on cachy-rig (Arch) and nucserver (Debian 13): correct OS family, resources,
  GPU; the NUC must report paperless/netmon/hub/AMP `installed`, navidrome `partial`.
- Dry-run proof: `homelab install <everything>` without `--apply` prints a full ordered action log
  and changes nothing — confirmed by `docker ps` and `systemctl list-units` being untouched.
- Guard proof: `homelab install --apply` on cachy-rig **refuses**, because there's no
  `/etc/homelab/allow-apply`.
- Hub proof: add a throwaway app dir to `apps/`, reload the hub, confirm it appears and its
  buttons drive it — with no edit to `hub/server.py`.
- Backup round-trip in the VM: `backup` → `delete --purge` → `restore` → paperless doc count matches.

## Not in this pass

- Nothing is installed, started, or changed on nucserver or cachy-rig. All work happens in the
  throwaway VM. Any `--apply` against a real box waits for your explicit go-ahead.
- `homelab.conf` is gitignored; only `homelab.conf.example` is committed. VM images never committed.
