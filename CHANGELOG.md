# Changelog

One line per release. The hub's Update button installs the newest tag here.

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
