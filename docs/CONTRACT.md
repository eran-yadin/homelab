# The app contract

Every app implements the same verbs. The hub and the CLI know nothing about any
specific app — they read the `apps/` directory and the JSON that `status` emits.
That is what lets you add an app later without touching the engine.

## Verbs

| verb | must do | may assume |
|---|---|---|
| `download` | fetch/build everything needed, change nothing that runs | nothing is installed |
| `start` | bring it up | `download` has run |
| `stop` | bring it down, keep data | it may already be down |
| `update` | fetch newer, restart **only if it was already running** | it is installed |
| `delete` | remove it, **keep data** unless `--purge` | it may not exist |
| `status` | print one line of JSON, change nothing | nothing |
| `backup <dir>` | write a restorable copy into `<dir>` | it is installed |
| `restore <dir>` | restore from `<dir>` | `<dir>` came from `backup` |

`backup`/`restore` are required only when `stateful=1`.

## Exit codes

| code | meaning |
|---|---|
| `0` | did the thing |
| `2` | already in that state — nothing to do (**not** an error) |
| `3` | stopped before changing anything because it needs a yes: `update` on a `stateful=1` app, run without `--yes` and without a terminal. The hub turns this into a confirmation dialog. |
| other | failed |

The `2` is what makes idempotency observable. `start` on a running app must
return `2`, not re-run `up -d` and return `0`.

## Rules

1. **Idempotent.** Running any verb twice must be safe. The second run reports
   `2`.
2. **Never call `docker` / `systemctl` / `apt` directly.** Call them through
   `run`, `run_sh` or `run_write`. That is the entire dry-run mechanism: apps
   get `--dry-run` for free and cannot forget to honour it.
3. **`status` prints exactly one line of JSON to stdout** and nothing else.
   Diagnostics go to stderr via `log`/`warn`/`err`.
4. **`delete` without `--purge` must not destroy data.**
5. **Secrets are generated once** and never rewritten by `update`.

## status JSON

Required keys: `app`, `kind`, `state`, `installed`.

```json
{"app":"paperless","kind":"compose","state":"running","installed":true,
 "containers":"3/3","health":"healthy","ports":"8010"}
```

`state` is one of:

| state | meaning |
|---|---|
| `absent` | not installed |
| `downloaded` | images/files present, nothing created yet |
| `stopped` | containers/unit exist but are not running |
| `running` | up and serving |
| `degraded` | partially up, or unhealthy |

Emit it with `emit_status <state> <installed> [key=value ...]`.

## Inheriting an implementation

Most apps write **no scripts at all**. Declare a `kind` and inherit its verbs:

| kind | for | app supplies |
|---|---|---|
| `compose` | docker compose apps | `files/compose.yml`, optionally `files/env.template` |
| `systemd` | host services | usually its own `download.sh`; declares `unit=` |
| `container` | a plain `docker run` container that predates this catalog | `container=`, usually with `adopted=1` |
| `script` | anything else | all verbs itself |

Dispatch order for a verb: `apps/<name>/<verb>.sh` if present and executable,
otherwise `lib/kinds/<kind>.sh <verb>`. Mix freely — netmon supplies only
`download.sh` and inherits the other six.

## A minimal app

`apps/jellyfin/app.conf`:

```sh
kind="compose"
title="Jellyfin"
category="media"
desc="Movies and TV, with hardware transcoding if the box has a GPU."
ports="8096"
requires="docker"
stateful=1
detect="container:jellyfin"
```

plus `apps/jellyfin/files/compose.yml`. That is a complete app: install, start,
stop, update, delete, status, backup and restore all work, and it appears in
the hub.

## app.conf reference

| key | default | meaning |
|---|---|---|
| `kind` | `compose` | which default implementation to inherit |
| `title` | app name | display name |
| `category` | `misc` | grouping in `list` and the hub |
| `desc` | — | one line, shown in the catalog |
| `ports` | — | host ports it listens on |
| `requires` | — | other apps, installed first (depth-first) |
| `stateful` | `0` | has data worth backing up; makes `--purge` prompt |
| `detect` | — | space-separated presence probes (below) |
| `needs_ram_mb` / `needs_disk_mb` | `0` | checked by `install` before anything changes: more RAM than the host has is a warning, more disk than is free is a stop |
| `unit` | `<name>.service` | kind=systemd: the unit |
| `backup_paths` | — | kind=systemd: paths to archive |
| `purge_paths` | — | kind=systemd: paths removed by `--purge` |
| `purge_users` | — | kind=systemd: system users removed by `--purge` |
| `oneshot` | — | compose services that run once and exit (init/migration); excluded from the running and total counts |
| `bulk_volumes` | — | kind=compose: volumes an update never rewrites (a photo library). The backup `update` takes before recreating a `stateful=1` app skips them; `backup` still archives everything |
| `health_url` | — | probed from the host when the container reports no health of its own — the only option for a distroless image with no shell |
| `conflicts` | — | things that cannot coexist, e.g. `unit:nginx.service`. Checked before `start` |
| `adopted` | `0` | this app already exists on the host; homelab controls it but will not install or remove it |
| `container` | app name | kind=container: the container to adopt |
| `homepage`, `notes` | — | shown by `info` |

### detect probes

`container:<name>`, `unit:<name>`, `bin:<name>`, `path:<abs>`, `port:<n>`.
All must match for `installed`; some for `partial`; none for `absent`.

## Adopting what is already there

A server that has been running for years already has services on it. An
`adopted=1` entry puts one in the catalog so the hub can see and control it,
while making clear homelab did not install it:

- `download` is a no-op that verifies the thing exists, and fails with a clear
  message if it does not
- `delete` **refuses** — removing something you did not install, by a route
  that never installed it, is how data disappears
- `update` on an adopted container pulls the newer image but will not recreate
  it: docker does not record the original `docker run` arguments, so there is
  no safe way to rebuild it

## Moving an app to another machine

    homelab backup  <app> <dir>        # on the old box
    # copy <dir> across
    homelab download <app> --apply     # on the new box: images only
    homelab restore  <app> <dir> --apply
    homelab start    <app> --apply

The order matters and the engine enforces it. `restore` refuses while the app
is running, because postgres (or any database) has by then initialised a fresh
cluster in the volume and holds those files open -- the archive would land on
top of live data. `install` is download **and** start, so it is the wrong verb
for a restore; use `download`.

`backup` writes one archive per named volume plus the app's `.env`, so
generated secrets travel with the data. That file is as sensitive as the
backup itself.

Prefer this over an application's own export where one exists. A volume
archive is a byte-for-byte copy; an app-level exporter re-serialises through
its own model layer and can silently omit rows. Measured, not theoretical:
paperless-ngx 2.20.13's `document_exporter` left one note out of twenty out of
its manifest, with nothing in the output to say so.

Pin image versions rather than tracking `:latest`. An app-level export usually
imports only into the version it came from, and `:latest` also means a routine
`update` can carry a stateful app across a major version unattended.

## Refusing to start rather than half-starting

Before `start`, the engine checks that nothing else holds the app's ports, that
no `conflicts=` entry is active, and — for compose apps — that no foreign
container already owns a name the compose file claims.

These failures are worth catching early because of how they present otherwise.
"Address already in use" surfaces from deep inside docker, after the install
has begun changing things, and never names what is holding the port. Worse, a
`container_name` collision can silently attach to somebody else's container.

A compose app's per-host `compose.override.yml` gets the same treatment, before
`start` and before `update` recreates anything. It is written at install time
for the hardware present then, and can stop fitting: a GPU removed, the NVIDIA
container toolkit lost in a docker reinstall, a state directory copied from
another machine. Compose reports that as a device error from inside `up`. The
engine instead checks every `/dev` path the override maps and, for an `nvidia`
driver, that docker has the nvidia runtime -- and refuses with the fix:
`homelab download <app> --apply` regenerates the override for this host.
Optional hardware is not checked here; the app's `download.sh` already says
what it found.

## Safety

- Nothing changes without `--apply`.
- `--apply` refuses unless `/etc/homelab/allow-apply` exists on the host.
- `delete --purge` on a `stateful=1` app asks you to type the app name.
- `tests/conformance.sh` refuses to run outside the test VM, because it purges
  everything it touches.
