#cloud-config
# Sterile test target for the homelab installer.
#
# Deliberately minimal. This provisions a BARE Debian box and nothing else --
# no Docker, no Caddy, no apps. Installing those is precisely what the homelab
# CLI is supposed to do, so pre-installing them here would make every test a
# false pass.

hostname: homelab-test
fqdn: homelab-test.local
manage_etc_hosts: true
locale: C.UTF-8   # NOT en_US.UTF-8 -- the Debian cloud image has no such locale,
                  # and a locale failure aborts the whole cloud-init config stage
                  # (silently skipping `packages:`). Learned the hard way.
timezone: Asia/Jerusalem

users:
  - name: eran
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: true
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - @@SSH_PUBKEY@@

ssh_pwauth: false
disable_root: true

# Second disk -> /var/lib/docker. The Debian cloud image root is only ~3 GB,
# which a couple of app images would fill immediately.
disk_setup:
  /dev/vdb:
    table_type: gpt
    layout: true
    overwrite: false

fs_setup:
  - label: dockerdata
    filesystem: ext4
    device: /dev/vdb
    partition: auto  # schema allows only auto/any/none, not a number
    overwrite: false

mounts:
  - [ /dev/vdb1, /data, ext4, "defaults,nofail", "0", "2" ]

package_update: true
packages:
  - ca-certificates
  - curl
  - jq
  - git
  - nftables

write_files:
  # The homelab CLI refuses `--apply` unless this marker exists. The test VM
  # is the one machine where it should always be present.
  - path: /etc/homelab/allow-apply
    permissions: '0644'
    content: |
      testenv
      This is the disposable QEMU test VM. Anything here is safe to destroy.

  - path: /etc/homelab/testenv
    permissions: '0644'
    content: |
      HOMELAB_TESTENV=1

  # Accident guard: the VM has internet (apt, docker pulls) but must never
  # touch the real LAN or the tailnet. SLIRP lives on 10.100.0.0/24, so
  # dropping the ranges below costs nothing and blocks a fat-fingered
  # `ssh 10.0.0.5` or a script that hardcodes the NUC.
  - path: /etc/nftables.conf
    permissions: '0755'
    content: |
      #!/usr/sbin/nft -f
      flush ruleset
      table inet homelab_testenv_guard {
        chain output {
          type filter hook output priority 0; policy accept;
          ip daddr 10.0.0.0/24    counter drop comment "real LAN"
          ip daddr 192.168.0.0/16 counter drop comment "other private LANs"
          ip daddr 100.64.0.0/10  counter drop comment "tailnet CGNAT"
        }
      }

runcmd:
  # Docker keeps images in /var/lib/docker, but containerd keeps its snapshots
  # -- which is where the bulk of an image build actually lands -- in
  # /var/lib/containerd. Moving only the former still fills the ~3 GB root.
  # Bind both onto the big disk. Done here rather than via cloud-init `mounts`
  # because the bind sources only exist after /data itself is mounted.
  # /var/cache and /home go on the big disk too. The cloud image root is
  # ~2.8 GB, and an apt cache plus one JRE fills it -- which surfaces as
  # "Unable to locate package", not as a disk error.
  - [ mkdir, -p, /data/docker, /data/containerd, /data/aptcache, /data/home,
      /var/lib/docker, /var/lib/containerd ]
  - [ bash, -c, "cp -a /var/cache/apt /data/aptcache/ 2>/dev/null || true" ]
  - [ mount, --bind, /data/aptcache, /var/cache/apt ]
  - [ mount, --bind, /data/docker, /var/lib/docker ]
  - [ mount, --bind, /data/containerd, /var/lib/containerd ]
  - [ bash, -c, "printf '/data/docker /var/lib/docker none bind 0 0\\n/data/containerd /var/lib/containerd none bind 0 0\\n/data/aptcache /var/cache/apt none bind 0 0\\n' >> /etc/fstab" ]
  - [ systemctl, enable, --now, nftables ]
  - [ bash, -c, "echo 'homelab testenv ready' > /etc/motd" ]

final_message: "homelab testenv up after $UPTIME seconds"
