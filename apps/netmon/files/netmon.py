#!/usr/bin/env python3
"""
netmon.py - Continuous network monitor
Pings multiple targets once per second, logs to SQLite.
Designed to run forever as a systemd service.
"""

import sqlite3
import subprocess
import threading
import time
import signal
import sys
import os
import re
from datetime import datetime, timezone
from pathlib import Path

# --- Config (override via env vars in the systemd unit) -----------------------
DB_PATH = os.environ.get("NETMON_DB", "/var/lib/netmon/netmon.db")
INTERVAL = float(os.environ.get("NETMON_INTERVAL", "1.0"))         # seconds between pings per target
TIMEOUT = float(os.environ.get("NETMON_TIMEOUT", "2.0"))           # ping timeout
RETENTION_DAYS = int(os.environ.get("NETMON_RETENTION_DAYS", "30"))
TARGETS = os.environ.get(
    "NETMON_TARGETS",
    # name=ip pairs, comma-separated
    "gateway=10.0.0.138,isp_edge=100.76.159.254,google_dns=8.8.8.8,cloudflare=1.1.1.1"
).split(",")

# --- Logging ------------------------------------------------------------------
def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)

# --- Database -----------------------------------------------------------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS pings (
    ts INTEGER NOT NULL,
    target TEXT NOT NULL,
    rtt_ms REAL,
    lost INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pings_ts ON pings(ts);
CREATE INDEX IF NOT EXISTS idx_pings_target_ts ON pings(target, ts);
"""

def db_connect():
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=30, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.executescript(SCHEMA)
    return conn

# --- Ping ---------------------------------------------------------------------
# Match RTT from `ping -c 1` output. Works on Debian's iputils-ping.
RTT_RE = re.compile(r"time[=<]([\d.]+)\s*ms")

def ping_once(host, timeout):
    """Returns rtt_ms or None on loss/timeout."""
    try:
        # -c 1: one packet. -n: no DNS. -W: timeout in seconds.
        # -q would suppress per-packet output but we need it for RTT.
        result = subprocess.run(
            ["ping", "-c", "1", "-n", "-W", str(int(timeout)), host],
            capture_output=True, text=True, timeout=timeout + 1
        )
        if result.returncode != 0:
            return None
        m = RTT_RE.search(result.stdout)
        return float(m.group(1)) if m else None
    except subprocess.TimeoutExpired:
        return None
    except Exception as e:
        log(f"ping {host} unexpected error: {e}")
        return None

# --- Probe thread per target --------------------------------------------------
class Probe(threading.Thread):
    def __init__(self, name, host, db_queue, stop_event):
        super().__init__(daemon=True, name=f"probe-{name}")
        self.target_name = name
        self.host = host
        self.db_queue = db_queue
        self.stop_event = stop_event

    def run(self):
        log(f"probe started: {self.target_name} ({self.host})")
        while not self.stop_event.is_set():
            start = time.monotonic()
            ts = int(time.time())
            rtt = ping_once(self.host, TIMEOUT)
            self.db_queue.append((ts, self.target_name, rtt, 0 if rtt is not None else 1))
            elapsed = time.monotonic() - start
            sleep_for = max(0, INTERVAL - elapsed)
            self.stop_event.wait(sleep_for)
        log(f"probe stopped: {self.target_name}")

# --- DB writer thread (batched inserts) ---------------------------------------
class Writer(threading.Thread):
    def __init__(self, db_queue, stop_event):
        super().__init__(daemon=True, name="db-writer")
        self.db_queue = db_queue
        self.stop_event = stop_event
        self.last_cleanup = 0

    def run(self):
        conn = db_connect()
        log(f"db writer started: {DB_PATH}")
        while not self.stop_event.is_set() or self.db_queue:
            if not self.db_queue:
                self.stop_event.wait(1.0)
                continue
            # Drain whatever is in the queue
            batch = []
            while self.db_queue and len(batch) < 500:
                batch.append(self.db_queue.pop(0))
            try:
                conn.executemany(
                    "INSERT INTO pings (ts, target, rtt_ms, lost) VALUES (?, ?, ?, ?)",
                    batch
                )
            except Exception as e:
                log(f"db write failed (will retry connection): {e}")
                try: conn.close()
                except Exception: pass
                time.sleep(2)
                conn = db_connect()
                continue
            # Daily cleanup of old rows
            now = time.time()
            if now - self.last_cleanup > 3600:  # once an hour
                cutoff = int(now - RETENTION_DAYS * 86400)
                try:
                    conn.execute("DELETE FROM pings WHERE ts < ?", (cutoff,))
                except Exception as e:
                    log(f"cleanup failed: {e}")
                self.last_cleanup = now
        conn.close()
        log("db writer stopped")

# --- Main ---------------------------------------------------------------------
def main():
    log("=== netmon starting ===")
    log(f"db:        {DB_PATH}")
    log(f"interval:  {INTERVAL}s")
    log(f"timeout:   {TIMEOUT}s")
    log(f"retention: {RETENTION_DAYS} days")

    targets = []
    for pair in TARGETS:
        pair = pair.strip()
        if not pair: continue
        if "=" not in pair:
            log(f"bad target (need name=ip): {pair}")
            continue
        name, host = pair.split("=", 1)
        targets.append((name.strip(), host.strip()))
        log(f"target: {name.strip()} -> {host.strip()}")

    if not targets:
        log("no targets configured, exiting")
        sys.exit(1)

    stop_event = threading.Event()
    db_queue = []  # simple shared list; lock-free because GIL + atomic ops

    def handle_signal(signum, frame):
        log(f"got signal {signum}, shutting down")
        stop_event.set()
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    writer = Writer(db_queue, stop_event)
    writer.start()

    probes = [Probe(name, host, db_queue, stop_event) for name, host in targets]
    for p in probes:
        p.start()

    # Stagger probes slightly so they don't all fire on the same second
    # (they're already on independent threads, but this spreads the ping load)
    # The wait above in run() handles this naturally after the first cycle.

    while not stop_event.is_set():
        stop_event.wait(5)

    log("waiting for probes to finish...")
    for p in probes:
        p.join(timeout=5)
    log("waiting for writer to drain...")
    writer.join(timeout=10)
    log("=== netmon stopped ===")

if __name__ == "__main__":
    main()
