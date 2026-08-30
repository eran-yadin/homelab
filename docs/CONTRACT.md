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
| `needs_ram_mb` / `needs_disk_mb` | `0` | resource hints |
| `unit` | `<name>.service` | kind=systemd: the unit |
| `backup_paths` | — | kind=systemd: paths to archive |
| `purge_paths` | — | kind=systemd: paths removed by `--purge` |
| `purge_users` | — | kind=systemd: system users removed by `--purge` |
| `homepage`, `notes` | — | shown by `info` |

### detect probes

`container:<name>`, `unit:<name>`, `bin:<name>`, `path:<abs>`, `port:<n>`.
All must match for `installed`; some for `partial`; none for `absent`.

## Safety

- Nothing changes without `--apply`.
- `--apply` refuses unless `/etc/homelab/allow-apply` exists on the host.
- `delete --purge` on a `stateful=1` app asks you to type the app name.
- `tests/conformance.sh` refuses to run outside the test VM, because it purges
  everything it touches.
