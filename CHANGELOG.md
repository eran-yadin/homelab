# Changelog

One line per release. The hub's Update button installs the newest tag here.

## Unreleased

- CHANGELOG.md

## v1.0.0 - 2026-09-12

- `homelab update self`: fetch, back up, deploy, smoke-test, roll back on failure
- Releases are git tags: `--channel stable` (default, newest v* tag), `--channel main`, `--to <tag>`
- `homelab version`, VERSION written at deploy, shown in the hub
- Hub Update button with a live progress page; the update runs as its own systemd unit
- ollama app; disk-space check before install; docker buildx fix; caddy reload; GPU detection
