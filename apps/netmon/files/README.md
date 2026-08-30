# netmon — Continuous Network Quality Monitor

Built for the NUC to track packet loss patterns over time and produce evidence-grade reports for the dorm helpdesk.

## What it does

Pings 4 targets once per second, 24/7, logging every result to SQLite:

| Target | Why |
|---|---|
| `gateway` (your router) | Baseline — should always be 0% loss |
| `isp_edge` (100.76.159.254) | The ISP's first hop — where pathping showed your 5% loss |
| `google_dns` (8.8.8.8) | External anchor |
| `cloudflare` (1.1.1.1) | Second external path — rules out one-provider issues |

If `gateway` is clean and `isp_edge` is lossy → blame is on the WAN side (the dorm's uplink). Same pattern you already saw with pathping, now tracked over time so you can prove it's worse at 23:00 than 03:00.

## Install

```bash
# Copy the folder to the NUC
scp -r netmon/ server_admin@10.0.0.5:~/

# SSH in and run the installer
ssh server_admin@10.0.0.5
cd ~/netmon
sudo ./install.sh
```

The installer:
1. Creates a `netmon` system user (no shell, no home)
2. Installs scripts to `/opt/netmon/`
3. Database at `/var/lib/netmon/netmon.db`
4. Installs `mtr-tiny` for path tests
5. Auto-detects your gateway and configures it in the service file
6. Enables + starts the systemd service
7. Adds `/usr/local/bin/netmon-report` for quick reports

## Reports

```bash
netmon-report                              # default: last 24h, full report
netmon-report --hours 12                   # last 12 hours
netmon-report --days 7                     # last week
netmon-report --hourly                     # loss % per hour of day (rush hour!)
netmon-report --bursts                     # consecutive-loss clusters w/ timestamps
netmon-report --bursts --burst-min 5       # only bursts of 5+
netmon-report --csv /tmp/net.csv           # per-minute CSV for Excel
netmon-report --csv-hourly /tmp/h.csv      # per-hour CSV
netmon-report --pathping                   # run mtr to 8.8.8.8 right now
```

## Morning routine (after running overnight)

```bash
netmon-report --hours 12 --hourly --bursts --csv ~/last_night.csv
```

That gives you:
- Summary table (overall loss % per target)
- Hourly heatmap (which hours were bad)
- Burst list (exact timestamps of bad moments)
- A CSV you can open in Excel and chart

## Service management

```bash
systemctl status netmon
systemctl restart netmon
journalctl -u netmon -f                 # live logs
journalctl -u netmon -n 50              # last 50 lines
```

## Changing the targets

Edit the service file:

```bash
sudo nano /etc/systemd/system/netmon.service
# Find: Environment=NETMON_TARGETS=...
# Format: name=ip,name=ip,name=ip
sudo systemctl daemon-reload
sudo systemctl restart netmon
```

## Data retention

30 days by default. Old data is purged hourly. Adjust via `NETMON_RETENTION_DAYS` env var in the service file.

## Database location

`/var/lib/netmon/netmon.db` — SQLite WAL mode, owned by netmon user.

Direct query example:
```bash
sudo -u netmon sqlite3 /var/lib/netmon/netmon.db \
  "SELECT target, COUNT(*), SUM(lost) FROM pings GROUP BY target"
```

## Disk usage

About 100 bytes per row. With 4 targets × 1 ping/sec × 86400 sec/day = 345,600 rows/day ≈ **35 MB/day** or **~1 GB/month**. Well within the NUC's storage.

## Hardening / security

- Runs as unprivileged `netmon` user
- Only `CAP_NET_RAW` capability (needed for ping)
- `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`
- Memory capped at 256 MB, CPU capped at 20% (won't fight with Paperless/Ollama)

## Uninstall

```bash
sudo ./uninstall.sh
```

## Reading the helpdesk report

For the helpdesk ticket, the killer evidence is:

1. **The hourly table** showing loss spikes during evening hours → "this is congestion, not a one-off"
2. **The bursts list** with exact timestamps → "this is when it happens"
3. **The summary** showing `gateway: 0% / isp_edge: 5%` → "the problem is upstream of my equipment"

Attach the CSV for credibility.
