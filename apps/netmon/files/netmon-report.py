#!/usr/bin/env python3
"""
netmon-report.py - Generate reports from netmon database.

Usage:
  netmon-report.py                       # last 24h summary to stdout
  netmon-report.py --hours 12            # last 12 hours
  netmon-report.py --days 7              # last 7 days
  netmon-report.py --csv out.csv         # export per-minute CSV
  netmon-report.py --hourly              # per-hour-of-day loss table
  netmon-report.py --bursts              # find loss bursts
  netmon-report.py --pathping            # run pathping right now
"""

import sqlite3
import argparse
import sys
import os
import csv
import subprocess
from datetime import datetime, timedelta

DB_PATH = os.environ.get("NETMON_DB", "/var/lib/netmon/netmon.db")

def connect():
    if not os.path.exists(DB_PATH):
        print(f"ERROR: database not found at {DB_PATH}", file=sys.stderr)
        print("Is netmon running?  systemctl status netmon", file=sys.stderr)
        sys.exit(1)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def fmt_pct(loss, total):
    if total == 0: return "  -  "
    return f"{100.0 * loss / total:5.2f}%"

def summary(conn, since_ts, label):
    print(f"\n=== Summary: {label} ===")
    rows = conn.execute("""
        SELECT target,
               COUNT(*) AS total,
               SUM(lost) AS lost,
               AVG(CASE WHEN lost=0 THEN rtt_ms END) AS avg_rtt,
               MIN(CASE WHEN lost=0 THEN rtt_ms END) AS min_rtt,
               MAX(CASE WHEN lost=0 THEN rtt_ms END) AS max_rtt
        FROM pings
        WHERE ts >= ?
        GROUP BY target
        ORDER BY target
    """, (since_ts,)).fetchall()

    if not rows:
        print("  (no data in this window)")
        return

    print(f"  {'target':<14} {'total':>7} {'lost':>6} {'loss%':>7} {'avg ms':>8} {'min':>6} {'max':>6}")
    print(f"  {'-'*14} {'-'*7} {'-'*6} {'-'*7} {'-'*8} {'-'*6} {'-'*6}")
    for r in rows:
        avg = f"{r['avg_rtt']:.1f}" if r['avg_rtt'] is not None else "-"
        mn  = f"{r['min_rtt']:.1f}" if r['min_rtt'] is not None else "-"
        mx  = f"{r['max_rtt']:.1f}" if r['max_rtt'] is not None else "-"
        print(f"  {r['target']:<14} {r['total']:>7} {r['lost']:>6} {fmt_pct(r['lost'], r['total']):>7} {avg:>8} {mn:>6} {mx:>6}")

def hourly_breakdown(conn, since_ts):
    print(f"\n=== Loss % by Hour of Day ===")
    print("  (averaged across all data in window — find the rush hour)\n")
    rows = conn.execute("""
        SELECT target,
               CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER) AS hour,
               COUNT(*) AS total,
               SUM(lost) AS lost
        FROM pings
        WHERE ts >= ?
        GROUP BY target, hour
        ORDER BY target, hour
    """, (since_ts,)).fetchall()

    if not rows:
        print("  (no data)")
        return

    by_target = {}
    for r in rows:
        by_target.setdefault(r['target'], {})[r['hour']] = (r['total'], r['lost'])

    targets = sorted(by_target.keys())
    header = "  hour | " + " | ".join(f"{t:>11}" for t in targets)
    print(header)
    print("  " + "-" * (len(header) - 2))
    for h in range(24):
        cells = []
        for t in targets:
            if h in by_target[t]:
                total, lost = by_target[t][h]
                pct = 100.0 * lost / total if total else 0
                bar = "*" if pct >= 1 else " "
                cells.append(f"{pct:>6.2f}% {bar:>2}")
            else:
                cells.append(f"{'-':>11}")
        print(f"  {h:>4} | " + " | ".join(cells))

def find_bursts(conn, since_ts, min_burst=3):
    """Find clusters of consecutive lost packets per target."""
    print(f"\n=== Loss bursts (≥{min_burst} consecutive losses) ===")
    targets = [r['target'] for r in conn.execute(
        "SELECT DISTINCT target FROM pings WHERE ts >= ? ORDER BY target", (since_ts,)
    )]
    any_found = False
    for target in targets:
        rows = conn.execute(
            "SELECT ts, lost FROM pings WHERE target=? AND ts >= ? ORDER BY ts",
            (target, since_ts)
        ).fetchall()
        bursts = []
        run_start = None
        run_len = 0
        for r in rows:
            if r['lost']:
                if run_start is None:
                    run_start = r['ts']
                run_len += 1
            else:
                if run_start is not None and run_len >= min_burst:
                    bursts.append((run_start, run_len))
                run_start = None
                run_len = 0
        if run_start is not None and run_len >= min_burst:
            bursts.append((run_start, run_len))

        if bursts:
            any_found = True
            print(f"\n  {target}: {len(bursts)} bursts")
            for start, length in bursts[-20:]:  # last 20
                dt = datetime.fromtimestamp(start).strftime("%Y-%m-%d %H:%M:%S")
                print(f"    {dt}  {length:>3} consecutive losses (~{length}s)")
    if not any_found:
        print("  (no bursts found — that's good news)")

def export_csv(conn, since_ts, path, granularity="minute"):
    if granularity == "minute":
        bucket = "strftime('%Y-%m-%d %H:%M:00', ts, 'unixepoch', 'localtime')"
    else:
        bucket = "strftime('%Y-%m-%d %H:00:00', ts, 'unixepoch', 'localtime')"

    rows = conn.execute(f"""
        SELECT {bucket} AS bucket,
               target,
               COUNT(*) AS total,
               SUM(lost) AS lost,
               AVG(CASE WHEN lost=0 THEN rtt_ms END) AS avg_rtt,
               MAX(CASE WHEN lost=0 THEN rtt_ms END) AS max_rtt
        FROM pings
        WHERE ts >= ?
        GROUP BY bucket, target
        ORDER BY bucket, target
    """, (since_ts,)).fetchall()

    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["timestamp", "target", "packets", "lost", "loss_pct", "avg_rtt_ms", "max_rtt_ms"])
        for r in rows:
            pct = 100.0 * r['lost'] / r['total'] if r['total'] else 0
            avg = f"{r['avg_rtt']:.2f}" if r['avg_rtt'] is not None else ""
            mx  = f"{r['max_rtt']:.2f}" if r['max_rtt'] is not None else ""
            w.writerow([r['bucket'], r['target'], r['total'], r['lost'], f"{pct:.2f}", avg, mx])
    print(f"  CSV written: {path} ({len(rows)} rows)")

def run_pathping(host="8.8.8.8"):
    """Run a Linux equivalent of Windows pathping using mtr if available."""
    print(f"\n=== Path test to {host} ===")
    # mtr -r runs in report mode, -c 100 = 100 packets
    if subprocess.run(["which", "mtr"], capture_output=True).returncode == 0:
        try:
            result = subprocess.run(
                ["mtr", "-r", "-n", "-c", "100", host],
                capture_output=True, text=True, timeout=180
            )
            print(result.stdout)
            if result.stderr:
                print(result.stderr, file=sys.stderr)
        except subprocess.TimeoutExpired:
            print("  mtr timed out")
    else:
        print("  mtr not installed.  Install with:  sudo apt install mtr-tiny")

def main():
    ap = argparse.ArgumentParser(description="netmon report generator")
    ap.add_argument("--hours", type=float, help="window in hours (default 24)")
    ap.add_argument("--days", type=float, help="window in days")
    ap.add_argument("--csv", help="export per-minute CSV to this path")
    ap.add_argument("--csv-hourly", help="export per-hour CSV to this path")
    ap.add_argument("--hourly", action="store_true", help="show per-hour-of-day loss table")
    ap.add_argument("--bursts", action="store_true", help="find consecutive-loss bursts")
    ap.add_argument("--burst-min", type=int, default=3, help="min burst length (default 3)")
    ap.add_argument("--pathping", action="store_true", help="run mtr against 8.8.8.8 now")
    ap.add_argument("--pathping-host", default="8.8.8.8")
    args = ap.parse_args()

    if args.hours is not None:
        window_s = int(args.hours * 3600)
        label = f"last {args.hours}h"
    elif args.days is not None:
        window_s = int(args.days * 86400)
        label = f"last {args.days} days"
    else:
        window_s = 86400
        label = "last 24h"

    since_ts = int(datetime.now().timestamp() - window_s)
    conn = connect()

    summary(conn, since_ts, label)

    if args.hourly:
        hourly_breakdown(conn, since_ts)
    if args.bursts:
        find_bursts(conn, since_ts, min_burst=args.burst_min)
    if args.csv:
        export_csv(conn, since_ts, args.csv, "minute")
    if args.csv_hourly:
        export_csv(conn, since_ts, args.csv_hourly, "hour")
    if args.pathping:
        run_pathping(args.pathping_host)

    # If no special flags, default to a useful full report
    if not (args.hourly or args.bursts or args.csv or args.csv_hourly or args.pathping):
        hourly_breakdown(conn, since_ts)
        find_bursts(conn, since_ts, min_burst=args.burst_min)

if __name__ == "__main__":
    main()
