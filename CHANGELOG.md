# Changelog

One line per release. The hub's Update button installs the newest tag here.

## v1.8.0 - 2026-10-25

Verified in the test VM against the published image: conformance 15/15, a full
data migration seeded with the NUC's real recording, and a backup/restore
round-trip that leaves the ~1.6 GB model cache intact -- the first time
backup/restore has been exercised on this app at all, since conformance does
not cover it despite the contract requiring it for stateful=1.

- transcribe: the app is its own project now (github.com/eran-yadin/transcribe) and this entry only deploys its published image, pinned to `v0.2.0` in `files/compose.yml`. It used to carry the source here with `build: .`, so every install compiled faster-whisper on the target -- a 2-core i3 -- and tagged the result `:latest` on an app that holds data: no version to report, nothing to roll back to. The image carries an OCI version label, which `_img_ver` already reads, so `update` now shows a real version jump. The pin lives in the compose file rather than `env.template` because that file is rendered once and never overwritten, so a pin there could never be moved by a catalog update
- transcribe: `init: true` and `stop_grace_period`. The app runs python as PID 1, and PID 1 ignores any signal with no registered handler, so every `docker stop` waited out the 10s grace period and then SIGKILLed it -- exit 137 each time, with no clean SQLite close. Fixed in the app as of its v0.1.0; the compose flags are the second line of defence
- transcribe: `needs_disk_mb` 4096 -> 8192. Measured rather than estimated: the image unpacks to 1.43 GB and the model cache is another ~1.6 GB, so roughly 3 GB is spent before the first recording. The old figure left under a gigabyte for audio, and it predates anyone checking
- transcribe: `download.sh` and `env.template` are unchanged -- the per-host thread sizing still happens at install time, and the engine needs no change at all, since the compose kind already pulls and only builds `if _has_build`

## v1.7.0 - 2026-10-21

- netmon: a web UI on port 8095 (`netmon.nuc` through caddy, and the hub card's Open button). Dashboard with per-target loss, average/p95 and a sparkline, plus a verdict line (LAN clean, loss past the router, dead targets); timeline with gaps where netmon was not running; loss by hour of day; bursts; latency percentiles, jitter and the worst spikes; CSV export with the same columns as `netmon-report --csv`; and an mtr path test that runs only when asked and suggests an `isp_edge`. While the monitor is stopped it says so, shows the data up to the last sample, and has a start button
- netmon: targets, interval, timeout and retention are editable from the UI. They are saved to `/var/lib/netmon/settings.env`, which `netmon.service` reads with `EnvironmentFile=`; saving restarts a running monitor. The web process stays unprivileged: start/stop/apply go through `netmon-control.path`, a root helper that knows those three words and nothing else. Input is validated (names `a-z0-9_`, addresses must be an IP or host name, so nothing can smuggle another variable into the env file)
- netmon: `update` on a box whose targets were hand-edited into the unit carries them into `settings.env` first, instead of resetting them to the detected defaults. A fresh install also detects `isp_edge` (the first hop past the router that answers, which skips a silent CGNAT hop)
- engine: `extra_units=` for kind=systemd -- companion units that start, stop, update and delete with the main one. State is still the main unit's; a companion down while it runs reads `degraded`. `status` reports `extras_up`
- fix: a dry-run install of a compose app on a host with no docker yet failed silently at `start`. With docker unresolved, the foreign-stack check ran the system `ps` instead of `docker ps`, and pipefail ended the script with no message
- testenv forwards 8095; conformance drives the netmon UI end to end (stop/start from the page, settings applied to the running process, an injected setting refused, purge removes every unit)

## v1.6.0 - 2026-10-20

- hub: every action it runs is recorded -- command, exit code, timing, the full terminal output (stderr and stdout interleaved, colours stripped, capped at 256 KB) and the `err` lines pulled out of it. The last 50 are kept in `/var/lib/homelab-hub/runs/` and survive a hub restart. `GET /api/runs`, `GET /api/runs/<id>`
- hub: a failed action's toast now says why (the first error, wrapped lines joined) and stays until clicked; click it for a details popup with the error lines, command, exit code, duration and the full output, opened at the first error, with Copy. The card shows the error lines instead of the last 1500 characters, plus a details link. A History button lists recent actions. A timeout is recorded too, with the output up to it
- fix: after any action on a card, Remove (and Install after a failed install) stayed disabled until the page was reloaded
- testenv: no longer forwards port 11470, which the Stremio desktop app on the host uses (the VM would not boot while Stremio ran, and earlier it made Stremio find the VM's server)

## v1.5.0 - 2026-10-20

- hub: listens to `docker events` (container start/stop/die/destroy/health). The app a container belongs to is re-read within ~2 s of the change, debounced so a multi-container `up` re-reads once; a container with no compose label triggers a full refresh. Reconnects with backoff if docker restarts
- hub: with the event stream up, background polling drops to every 2 minutes, kept as the safety net for what emits no docker event (systemd apps: amp, netmon, cockpit); without it, every 30 s as before
- page: polls the cache every 5 s (it is cheap now), so a change shows within seconds; auto-refreshes are quiet (no spinner, one toast if the hub is unreachable). Tailscale lookup cached for 30 s

## v1.4.0 - 2026-10-20

- hub: statuses come from a cache kept by one background thread (every 30 s), so `/api/status` answers in milliseconds instead of ~5.6 s, and all open tabs share one refresh. With no page asking for 2 minutes the thread stops running status at all
- hub: a button press re-reads only that app (`/api/control` returns its new status; `/api/status?app=<id>` for one app), and the page repaints that card instead of waiting on every app
- page: no polling while the tab is hidden; refreshes when you come back
- engine: `status` over many apps resolves docker once and takes one `docker ps` snapshot for all of them; `compose config --services/--images` is cached by a hash of the compose files and `.env`; an app with no containers and no state dir is `absent` without asking compose. `status --all` on nucserver: 9.5 s -> 1.5 s, ~8 s -> 1.4 s CPU
- fix: an app whose compose shares a common image (manyfold's `alpine:3` init step) was reported `downloaded` when only that shared image was present

## v1.3.2 - 2026-10-18

- hub: adopted containers (feishin) get the Remove button. It removes the container only; `delete --purge` on an adopted container is refused, because its data is not homelab's to judge. Adopted services such as cockpit (an OS package) still have no button
- stremio-server back on its bridge network, as before v1.2.5. Host networking did not get web.stremio.com working, and nothing else needed it. The v1.2.5 port-preflight fix for host-network apps stays
- fix: `apps/ollama/download.sh` had lost its executable bit, so the engine skipped it (it only runs app scripts marked executable) and ollama installed without its VRAM detection
- conformance: an adopted container is removable, its volume survives, and --purge is refused

## v1.3.1 - 2026-10-18

- fix: `delete`, `delete --purge`, `update` and `restore` now refuse a stack under the app's project name that homelab did not create, the same check `start` already had. Before, `delete paperless` would have run `docker compose -p paperless down` against nucserver's own paperless stack, and `--purge` would have taken its volumes; v1.3.0's Remove button put that one click away
- conformance: the foreign-stack test gives the impostor an `<app>_data` volume and checks all four verbs refuse and leave the stack and volume alone

## v1.3.0 - 2026-10-18

- hub: a Remove button on every installed app. It keeps the app's data unless "Also delete its data" is ticked; for an app that holds data that also needs the app name typed, which the hub hands to the engine's own `delete --purge` confirmation. Adopted apps and what the hub itself stands on (hub, caddy, docker, tailscale) get no button, and the API refuses them
- `delete --purge` on a compose app also removes its images (not ones another container still uses), so the app reads as absent afterwards instead of "downloaded"
- `list --json` reports `adopted` and `stateful`

## v1.2.5 - 2026-10-18

- stremio-server runs on the host network. On a bridge it saw only its 172.x address, so it could not get a `*.stremio.rocks` certificate for the LAN IP, and web.stremio.com (https) refused the plain-http server as mixed content ("NetworkError when attempting to fetch resource"). Now pick the LAN IP under "remote HTTPS" in its settings and use the `https://…stremio.rocks:12470` address. `ports` declares 12470 too
- fix: the port preflight could not tell an app's own host-network container from a stranger, because Docker's `publish=` filter does not see host-network ports. A second `start` of a running host-network app (stremio-server, syncthing, caddy, home-assistant) was refused with "'node' is already listening". A port held while the app's own project has a host-network container running is now treated as the app's own

## v1.2.4 - 2026-09-13

- compose apps: before `start`, and before `update` recreates anything, a per-host `compose.override.yml` is checked against the host -- every `/dev` path it maps must exist, and an `nvidia` driver needs docker's nvidia runtime. A miss refuses with `homelab download <app> --apply` as the fix, instead of a device error from inside `docker compose up`. Optional hardware is not re-checked; download.sh already reports it
- `install` warns (does not stop) when an app's `needs_ram_mb` is more than the host's total RAM; the disk check stays a stop
- conformance: stage a missing-device override and an NVIDIA override without the runtime (both refused, no container created, `download` then fixes it), and a dry-run install that must warn about RAM yet exit 0

## v1.2.3 - 2026-09-13

- fix: the "different compose file" guard compared the absolute paths a container recorded as a string, so an app created from `~/homelab` and managed from `/opt/homelab` (what `deploy --from` then `update self` does), or with its files recorded in another order, was refused every restart. It now compares each file's app-relative path plus a sha256 of its contents, order-independent. A genuinely foreign stack still mismatches: its path has no `apps/<app>/` prefix to strip, and a file at our path with different contents fails on the hash
- conformance: restart the same app from a second engine root (must be a no-op), and stage a foreign stack under the app's project name (must still be refused) — the second proves the loosening kept the check's teeth

## v1.2.2 - 2026-09-13

- `_dc_args` and the start-time guard now derive the compose file list from one helper (`_compose_files`), so they can't disagree the way they did in v1.2.1; the "different compose file" refusal now prints the full expected list
- conformance exercises the per-host override path (injects a harmless override, asserts restart is a no-op) — the gap that let the v1.2.1 bug ship

## v1.2.1 - 2026-09-13

- fix: compose apps with a per-host `compose.override.yml` could not be restarted. The "different compose file" guard compared the container's recorded config-files against the base `compose.yml` alone, ignoring the override the engine itself appends, so the check always tripped. Hit stremio-server on any host with `/dev/dri`. The guard now expects base+override.

## v1.2.0 - 2026-09-12

- `update <app>` for compose apps shows the version jump per service before recreating anything
- an app that holds data is backed up first, into `/var/lib/homelab/backups/<app>/pre-update-<ts>/`, and asked about: a prompt at a terminal, exit 3 without one, `--yes` to answer
- hub: the per-app Update button turns that into a dialog with the jump and a "Back up and update" button
- `bulk_volumes` in app.conf: volumes the pre-update backup skips (Immich's photo library); `backup` still archives everything
- immich and paperless follow floating tags (`release`, `latest`) instead of pins; the update flow is what makes that safe

## v1.1.2 - 2026-09-12

- hub: switching to Tailscale links first checks that this device can reach the server over the tailnet; if not, an error says so and the mode stays Local. The server-side case (Tailscale down on the NUC) already disabled the button with a message

## v1.1.1 - 2026-09-12

- hub: the Local link mode now uses the server's LAN IP when the hub itself is viewed over Tailscale; before, Local and Tailscale built the same link and the toggle looked dead
- README brought up to date: 22 apps, releases, Update button, Immich, plans

## v1.1.0 - 2026-09-12

- immich app: photos and videos from your phone, four containers, named volumes, pinned v3.2.0
- tasks.md: the unified-search plan

## v1.0.1 - 2026-09-12

- `update self --to` accepts a commit hash or branch, not only a tag, to try a change on the box before tagging
- CHANGELOG.md

## v1.0.0 - 2026-09-12

- `homelab update self`: fetch, back up, deploy, smoke-test, roll back on failure
- Releases are git tags: `--channel stable` (default, newest v* tag), `--channel main`, `--to <tag>`
- `homelab version`, VERSION written at deploy, shown in the hub
- Hub Update button with a live progress page; the update runs as its own systemd unit
- ollama app; disk-space check before install; docker buildx fix; caddy reload; GPU detection
