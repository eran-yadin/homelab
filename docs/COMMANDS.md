# Commands

Everything is a **dry run without `--apply`**: it prints what it would do and
changes nothing. On nucserver, run as `server_admin` (`ssh server_admin@10.0.0.5`,
or `100.90.182.50` over Tailscale); `sudo` is only needed with `--apply`.

```sh
H=/opt/homelab/homelab
```

## Apps

```sh
$H status                         # every app: state, health
$H list                           # the catalog, and what is installed
$H info immich                    # what an app is, ports, RAM/disk needs
sudo $H install <app> --apply     # download + start
sudo $H start|stop|restart <app> --apply
sudo $H update <app> --apply      # shows the version jump, backs up an app that holds data, asks
sudo $H delete <app> --apply      # keeps its data; --purge also deletes it (asks for the name)
```

## Backups

```sh
sudo $H backup <app> <dir> --apply                  # one app, now
sudo $H restore <app> <dir> --apply                 # stop the app first
sudo $H backup --now --apply                        # the nightly job, started now
sudo ls /var/lib/homelab/backups/nightly/           # one folder per night, + latest
sudo cat /var/lib/homelab/backups/nightly/latest/SUMMARY
journalctl -u homelab-backup.service -n 30          # how the last night went
```

Offsite (another machine pulls the backups, read-only):

```sh
sudo $H offsite allow "ssh-ed25519 AAAA… name" --apply
sudo $H offsite revoke <name> --apply
sudo $H offsite status
# on that machine, once: bash apps/backup/files/install-puller.sh <server-address>
```

## Settings

The same values the hub's `/settings` page shows and changes.

```sh
sudo $H settings                                    # all of them, as JSON
sudo $H settings set backup.time 03:30 --apply
sudo $H settings set backup.keep_daily 7 --apply    # also backup.keep_weekly
sudo $H settings set backup.mode.<app> all|nobulk|skip --apply
sudo $H settings set offsite.warn_days 3 --apply
sudo $H settings set firewall.friend_tcp "27015 25565" --apply   # then: update firewall
```

## Firewall

```sh
sudo $H update firewall --apply     # apply /etc/homelab/firewall.conf
sudo $H confirm firewall --apply    # keep it; without this it switches itself off after 3 min
sudo nft list table inet homelab    # the rules as loaded
```

## Jellyfin accounts

```sh
$H jellyfin user list
sudo $H jellyfin user add mom --apply              # family: everything, can download
sudo $H jellyfin user add noa --kid 12 --apply     # kid: Movies + Shows, ratings up to 12
sudo $H jellyfin user password noa --apply         # a new password, printed once
sudo $H jellyfin user remove noa --apply
sudo $H jellyfin share dan --hours 24 --apply      # guest that ends by itself
sudo $H jellyfin share list --apply
sudo $H jellyfin share stop dan --apply            # or: stop all
```

## USB drives (read-only)

```sh
$H disk list                                # USB drives, size, filesystem, label
sudo $H disk mount /dev/sdb1 --apply        # read-only at /mnt/disks/<label>
                                            # Immich: External Libraries > /external/<label>
sudo $H disk unmount <label> --apply        # before unplugging
```

## Names, routes, DNS

```sh
sudo $H download caddy --apply      # regenerate http://<app>.nuc routes (restarts caddy)
dig +short @10.0.0.5 hub.nuc        # what AdGuard answers
```

## The engine itself

```sh
$H version                                  # deployed version
sudo $H update self --apply                 # install the newest release tag
sudo $H update self --to v1.13.0 --apply    # go to a given version (or back)
sudo systemctl status homelab-hub           # the hub
sudo journalctl -u homelab-hub -f
```

## Generated passwords

Readable by `server_admin`, never shown in the hub:

```sh
grep ADGUARD /var/lib/homelab/apps/adguard/.env
cat /var/lib/homelab/apps/samba/.env
ssh -t server_admin@10.0.0.5 'docker exec -it immich_server immich-admin reset-admin-password'
```
