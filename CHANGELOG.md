# Changelog

One line per release. The hub's Update button installs the newest tag here.

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
