# testenv — the sterile test target

A throwaway Debian 13 VM that matches `nucserver`, used to test the homelab
installer against a machine that is **empty every single time**.

## Why this exists

The installer's whole job is to change a machine, so testing it needs a machine
we're willing to have changed — and one that is *clean* on every run. Without
that you get false passes: the second run of an installer succeeds only because
the first run already created the volume / installed the package / made the
network, and you never find out it's broken on a genuinely fresh box.

Not the NUC: paperless holds years of scans. Not a container: it can't run real
systemd or install Docker inside itself, which is precisely what we need to test.

## Requirements

Already satisfied on cachy-rig; nothing needs installing.

- `qemu-system-x86_64`, `/dev/kvm` readable (runs at near-native speed)
- `mkfs.vfat` + `mcopy` (dosfstools, mtools) to build the cloud-init seed
- a **reflink-capable filesystem** (btrfs/xfs) for instant resets

No `qemu-img`, no libvirt, no Vagrant, no root.

## Usage

    make build    # once: download + sha512-verify the golden image (~414 MB)
    make up       # boot, wait for ssh AND for cloud-init to finish
    make ssh      # shell in
    make status   # what's running
    make reset    # destroy and boot a pristine machine  <-- the point
    make down     # shut down
    make clean    # drop all run state, keep the golden image

## How the reset works

`golden/debian-13-generic-amd64.qcow2` is downloaded once and made read-only.
`make up` clones it with `cp --reflink=always` — a btrfs copy-on-write clone that
takes ~5 ms and consumes **zero** extra disk until the VM writes. Reset is just
`rm run/disk.qcow2` and clone again.

This replaces the usual qcow2 backing-file overlay. It's simpler, faster, needs
no `qemu-img`, and has no backing-file corruption failure mode.

| | |
|---|---|
| reflink clone of the 414 MB root | ~5 ms |
| reset → SSH answering | ~16 s |
| reset → cloud-init fully done | ~98 s (apt over the network) |

## Disks

- `/dev/vda` — root, reflink clone of golden (~3 GB, auto-grown)
- `/dev/vdb` — 40 GB sparse raw, formatted and mounted at **`/var/lib/docker`**.
  The cloud image root is only ~3 GB; two app images would fill it.
- `/dev/vdc` — 1 MB FAT labelled `CIDATA`, the cloud-init NoCloud seed

## What the VM deliberately does NOT have

No Docker, no Caddy, no Tailscale. Installing those is exactly what the homelab
CLI is for, so pre-installing them would make every test a false pass.

It does have `/etc/homelab/allow-apply`, the marker the CLI requires before it
will run `--apply`. The test VM is the one machine where that's always present.

## Network isolation — read this

The VM uses QEMU user-mode (SLIRP) networking on `10.100.0.0/24`, deliberately
distinct from the real LAN at `10.0.0.0/24`.

**SLIRP NATs through the host's network stack, so by default the guest CAN reach
the LAN** — including the NUC. That is not the isolation people assume it is.
So the guest runs an nftables rule dropping output to:

- `10.0.0.0/24` — the real LAN (the NUC lives at 10.0.0.5)
- `192.168.0.0/16` — other private LANs
- `100.64.0.0/10` — the tailnet

Internet still works (apt, docker pulls). Verified: `ping 10.0.0.5` and
`10.0.0.5:8010` are blocked, `https://deb.debian.org` succeeds.

This is an **accident guard**, not a security boundary — it stops a hardcoded IP
or a fat-fingered command from touching production. The stronger protection is
that the VM holds no credentials to anything: `make up` generates a throwaway
SSH keypair in `run/`, and your real keys are never copied in.

## Forwarded ports stall during big downloads

While the VM is pulling a large image or running a build that downloads
packages, the forwarded ports (the hub, app UIs) can appear to hang from the
host. The TCP connection is accepted and the service answers fine *inside* the
guest -- it is the path between them that is starved.

QEMU's user-mode networking is single-threaded and each `hostfwd` listens with
a backlog of 1, so a guest saturating its NIC crowds out host-to-guest
connections. SSH usually survives because it is low-bandwidth and already
established.

It clears on its own when the download finishes. Nothing to fix; a real server
has no SLIRP in the path.

## Known limits

- **No GPU.** The NUC's HD 620 QuickSync transcoding can't be tested here.
  Anything hardware-specific needs a careful first run on real hardware.
- 2 vCPU / 4 GB by design — smaller than the NUC, so resource problems surface
  here first. Change `CPUS` / `MEM` in the Makefile if needed.

## Gotchas already hit and fixed

Both of these cost a boot cycle and are worth knowing:

1. `locale: en_US.UTF-8` — **not present** in the Debian cloud image (only
   `C.utf8`). The failure aborted cloud-init's whole config stage, which
   *silently skipped `packages:`*, so nftables was never installed and the
   firewall guard never applied. Now `C.UTF-8`.
2. `fs_setup.partition` must be `auto`/`any`/`none`, not a number.
3. SSH answers long before cloud-init finishes. `make up` now blocks on
   `cloud-init status --wait` so tests can't race provisioning.
