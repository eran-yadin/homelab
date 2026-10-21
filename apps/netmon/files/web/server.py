#!/usr/bin/env python3
"""
netmon web - a browser front end for netmon.

Reads the netmon database read-only and serves one page plus a small JSON API.
It does not ping anything itself and never writes to the database; netmon.py
stays the only writer.

Two things it may change, both inside /var/lib/netmon:
  settings.env  targets / interval / timeout / retention, read by netmon.service
                through EnvironmentFile=
  request       one word (start, stop, apply) picked up by netmon-control.path,
                which runs netmon-control as root. That is how an unprivileged
                web process starts, stops and restarts the monitor without sudo.

Standard library only, so it runs from the same venv as netmon with nothing to
install.
"""

import csv
import io
import ipaddress
import json
import os
import re
import sqlite3
import subprocess
import sys
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

DB_PATH = os.environ.get("NETMON_DB", "/var/lib/netmon/netmon.db")
DATA_DIR = Path(os.environ.get("NETMON_DATA_DIR", "/var/lib/netmon"))
SETTINGS = DATA_DIR / "settings.env"
REQUEST = DATA_DIR / "request"
UNIT = os.environ.get("NETMON_UNIT", "netmon.service")
LISTEN = os.environ.get("NETMON_WEB_LISTEN", "0.0.0.0")
PORT = int(os.environ.get("NETMON_WEB_PORT", "8095"))
STATIC = Path(__file__).resolve().parent / "index.html"

# Same defaults netmon.py falls back to when the unit sets nothing.
DEFAULTS = {
    "NETMON_TARGETS": "gateway=10.0.0.138,google_dns=8.8.8.8,cloudflare=1.1.1.1",
    "NETMON_INTERVAL": "1.0",
    "NETMON_TIMEOUT": "2.0",
    "NETMON_RETENTION_DAYS": "30",
}
MAX_WINDOW_S = 31 * 86400
# Queries that pull every sample into Python (percentiles, bursts) stop at a
# week: 30 days is ~800k samples per target, too much for a 128 MB service.
MAX_SAMPLE_WINDOW_S = 7 * 86400
# no sample for this long = the monitor was not running
GAP_S = 60          # measured on nucserver: ~258 MB for 2.94M rows incl. indexes

# ------------------------------------------------------------------ helpers

def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def db():
    """A fresh read-only connection, or None when netmon has not made one yet.

    mode=ro still needs to write the -shm file of a WAL database, which is why
    this process runs as the netmon user, the owner of that directory.
    """
    if not os.path.exists(DB_PATH):
        return None
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=10,
                           check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


_cache = {}
_cache_lock = threading.Lock()


def cached(key, ttl, fn):
    """Reuse a result for ttl seconds, so a tab that refreshes does not re-run
    a multi-second query on a 4-thread box. One computation per key at a time."""
    now = time.monotonic()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < ttl:
            return hit[1]
    val = fn()
    with _cache_lock:
        _cache[key] = (time.monotonic(), val)
        if len(_cache) > 200:
            for k, _ in sorted(_cache.items(), key=lambda kv: kv[1][0])[:100]:
                _cache.pop(k, None)
    return val


def unit_state():
    try:
        out = subprocess.run(["systemctl", "show", UNIT, "-p", "ActiveState",
                              "-p", "ActiveEnterTimestampMonotonic", "--value"],
                             capture_output=True, text=True, timeout=5).stdout.split()
        state = out[0] if out else "unknown"
        since = None
        if len(out) > 1 and out[1].isdigit() and int(out[1]) > 0 and state == "active":
            since = time.clock_gettime(time.CLOCK_MONOTONIC) - int(out[1]) / 1e6
        return state, since
    except Exception:
        return "unknown", None


def last_ts(conn):
    r = conn.execute("SELECT MAX(ts) FROM pings").fetchone()
    return r[0]


def window(q, conn, max_span=MAX_WINDOW_S):
    """(since, until, label) from ?hours= / ?days= and ?end=now|last.

    end=last anchors the window at the newest sample instead of the clock,
    which is what you want while the monitor is stopped and the data is old.
    """
    try:
        hours = float(q.get("hours", ["24"])[0])
    except ValueError:
        hours = 24.0
    span = int(min(max(hours, 0.05) * 3600, max_span))
    until = int(time.time())
    if q.get("end", ["now"])[0] == "last" and conn is not None:
        lt = last_ts(conn)
        if lt:
            until = int(lt) + 1
    return until - span, until, span


def pct(lost, total):
    return round(100.0 * lost / total, 3) if total else None


def percentile(sorted_vals, p):
    if not sorted_vals:
        return None
    k = (len(sorted_vals) - 1) * p / 100.0
    lo = int(k)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return round(sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo), 2)


# ------------------------------------------------------------------ settings

NAME_RE = re.compile(r"^[a-z0-9_]{1,24}$")
HOST_RE = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
                     r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")


def valid_host(h):
    try:
        ipaddress.ip_address(h)
        return True
    except ValueError:
        return bool(HOST_RE.match(h)) and not h.startswith("-")


def parse_env(text):
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"')
    return out


def unit_env():
    """The Environment= values systemd has for the unit (before settings.env)."""
    try:
        out = subprocess.run(["systemctl", "show", UNIT, "-p", "Environment", "--value"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return {}
    env = {}
    for part in out.split():
        if "=" in part:
            k, v = part.split("=", 1)
            env[k] = v
    return env


def current_settings():
    s = dict(DEFAULTS)
    s.update({k: v for k, v in unit_env().items() if k in DEFAULTS})
    try:
        s.update({k: v for k, v in parse_env(SETTINGS.read_text()).items() if k in DEFAULTS})
    except FileNotFoundError:
        pass
    targets = []
    for pair in s["NETMON_TARGETS"].split(","):
        if "=" in pair:
            n, h = pair.split("=", 1)
            targets.append({"name": n.strip(), "host": h.strip()})
    return {
        "targets": targets,
        "interval": float(s["NETMON_INTERVAL"]),
        "timeout": float(s["NETMON_TIMEOUT"]),
        "retention_days": int(float(s["NETMON_RETENTION_DAYS"])),
    }


def validate_settings(body):
    """Returns (settings, None) or (None, error message for the user)."""
    if not isinstance(body, dict):
        return None, "expected a JSON object"
    targets = body.get("targets")
    if not isinstance(targets, list) or not 1 <= len(targets) <= 8:
        return None, "give between 1 and 8 targets"
    seen, clean = set(), []
    for t in targets:
        if not isinstance(t, dict):
            return None, "each target needs a name and an address"
        n = str(t.get("name", "")).strip()
        h = str(t.get("host", "")).strip()
        if not NAME_RE.match(n):
            return None, f"target name '{n}' must be 1-24 of a-z, 0-9 or _"
        if n in seen:
            return None, f"target name '{n}' is used twice"
        if not valid_host(h):
            return None, f"'{h}' for {n} is not an IP address or host name"
        seen.add(n)
        clean.append({"name": n, "host": h})
    try:
        interval = float(body.get("interval"))
        timeout = float(body.get("timeout"))
        retention = int(body.get("retention_days"))
    except (TypeError, ValueError):
        return None, "interval, timeout and retention must be numbers"
    if not 0.5 <= interval <= 60:
        return None, "interval must be between 0.5 and 60 seconds"
    if not 1 <= timeout <= 10:
        return None, "timeout must be between 1 and 10 seconds"
    if not 1 <= retention <= 90:
        return None, "keep data between 1 and 90 days"
    return {"targets": clean, "interval": interval, "timeout": timeout,
            "retention_days": retention}, None


def write_settings(s):
    text = (
        "# Written by netmon web. Read by netmon.service (EnvironmentFile=);\n"
        "# values here override the unit's own Environment= lines.\n"
        f"NETMON_TARGETS={','.join(t['name'] + '=' + t['host'] for t in s['targets'])}\n"
        f"NETMON_INTERVAL={s['interval']}\n"
        f"NETMON_TIMEOUT={s['timeout']}\n"
        f"NETMON_RETENTION_DAYS={s['retention_days']}\n"
    )
    tmp = SETTINGS.with_suffix(".tmp")
    tmp.write_text(text)
    os.chmod(tmp, 0o640)
    os.replace(tmp, SETTINGS)


_last_request = [0.0]


def request_control(action):
    """Ask netmon-control (root, via a path unit) to act on netmon.service."""
    if action not in ("start", "stop", "apply"):
        raise ValueError(action)
    now = time.monotonic()
    if now - _last_request[0] < 3:
        return False
    _last_request[0] = now
    REQUEST.write_text(action + "\n")
    return True


# ------------------------------------------------------------------ queries

def q_status():
    state, since = unit_state()
    out = {"unit": UNIT, "state": state, "uptime_s": int(since) if since else None,
           "db": DB_PATH, "db_bytes": None, "rows": None, "first_ts": None,
           "last_ts": None, "now": int(time.time()),
           "control": os.access(DATA_DIR, os.W_OK)}
    try:
        out["db_bytes"] = sum(os.path.getsize(p) for p in (DB_PATH, DB_PATH + "-wal")
                              if os.path.exists(p))
    except OSError:
        pass
    conn = db()
    if conn is None:
        return out
    with conn:
        r = conn.execute("SELECT MIN(ts), MAX(ts) FROM pings").fetchone()
        out["first_ts"], out["last_ts"] = r[0], r[1]
        out["rows"] = cached("rows", 60, lambda: conn.execute(
            "SELECT COUNT(*) FROM pings").fetchone()[0])
    return out


def q_summary(q):
    conn = db()
    if conn is None:
        return {"targets": []}
    with conn:
        since, until, span = window(q, conn, MAX_SAMPLE_WINDOW_S)
        hosts = {t["name"]: t["host"] for t in current_settings()["targets"]}
        rows = conn.execute("""
            SELECT target, COUNT(*) total, SUM(lost) lost,
                   AVG(CASE WHEN lost=0 THEN rtt_ms END) avg_rtt,
                   MIN(CASE WHEN lost=0 THEN rtt_ms END) min_rtt,
                   MAX(CASE WHEN lost=0 THEN rtt_ms END) max_rtt
            FROM pings WHERE ts >= ? AND ts < ? GROUP BY target ORDER BY target
        """, (since, until)).fetchall()
        # sparkline: 60 buckets of average rtt and loss
        step = max(span // 60, 1)
        spark = {}
        for r in conn.execute("""
            SELECT target, (ts - ?) / ? b, AVG(CASE WHEN lost=0 THEN rtt_ms END) rtt, SUM(lost) lost
            FROM pings WHERE ts >= ? AND ts < ? GROUP BY target, b
        """, (since, step, since, until)):
            spark.setdefault(r["target"], [None] * 60)
            if 0 <= r["b"] < 60:
                spark[r["target"]][r["b"]] = [round(r["rtt"], 2) if r["rtt"] is not None else None,
                                              r["lost"]]
        p95 = {}
        for r in rows:
            vals = [v[0] for v in conn.execute(
                "SELECT rtt_ms FROM pings WHERE target=? AND ts>=? AND ts<? AND lost=0 ORDER BY rtt_ms",
                (r["target"], since, until))]
            p95[r["target"]] = percentile(vals, 95)
    return {"since": since, "until": until, "targets": [{
        "name": r["target"], "host": hosts.get(r["target"]),
        "total": r["total"], "lost": r["lost"], "loss_pct": pct(r["lost"], r["total"]),
        "avg": round(r["avg_rtt"], 2) if r["avg_rtt"] is not None else None,
        "min": round(r["min_rtt"], 2) if r["min_rtt"] is not None else None,
        "max": round(r["max_rtt"], 2) if r["max_rtt"] is not None else None,
        "p95": p95.get(r["target"]),
        "spark": spark.get(r["target"], []),
    } for r in rows]}


def q_timeline(q):
    conn = db()
    if conn is None:
        return {"series": {}}
    with conn:
        since, until, span = window(q, conn)
        step = max(span // 300, 1)       # ~300 points per line
        series = {}
        for r in conn.execute("""
            SELECT target, (ts - ?) / ? b, COUNT(*) total, SUM(lost) lost,
                   AVG(CASE WHEN lost=0 THEN rtt_ms END) rtt
            FROM pings WHERE ts >= ? AND ts < ? GROUP BY target, b ORDER BY target, b
        """, (since, step, since, until)):
            series.setdefault(r["target"], []).append(
                [since + r["b"] * step, round(r["rtt"], 2) if r["rtt"] is not None else None,
                 r["lost"], r["total"]])
    return {"since": since, "until": until, "step": step, "series": series}


def q_hourly(q):
    conn = db()
    if conn is None:
        return {"targets": {}}
    with conn:
        since, until, _ = window(q, conn)
        out = {}
        for r in conn.execute("""
            SELECT target, CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER) h,
                   COUNT(*) total, SUM(lost) lost
            FROM pings WHERE ts >= ? AND ts < ? GROUP BY target, h
        """, (since, until)):
            out.setdefault(r["target"], [None] * 24)[r["h"]] = [pct(r["lost"], r["total"]), r["total"]]
    return {"since": since, "until": until, "targets": out}


def q_bursts(q):
    conn = db()
    if conn is None:
        return {"bursts": []}
    try:
        min_len = max(2, min(int(q.get("min", ["3"])[0]), 3600))
    except ValueError:
        min_len = 3
    with conn:
        since, until, _ = window(q, conn, MAX_SAMPLE_WINDOW_S)
        bursts = []
        targets = [r[0] for r in conn.execute(
            "SELECT DISTINCT target FROM pings WHERE ts >= ? AND ts < ?", (since, until))]
        for t in targets:
            start = None
            n = 0
            prev = None
            last_seen = None
            for ts, lost in conn.execute(
                    "SELECT ts, lost FROM pings WHERE target=? AND ts>=? AND ts<? ORDER BY ts",
                    (t, since, until)):
                # A hole in the samples is netmon not running, not the network:
                # it ends a burst rather than stretching it across the hole.
                if last_seen is not None and ts - last_seen > GAP_S and start is not None:
                    if n >= min_len:
                        bursts.append({"target": t, "start": start, "end": prev, "lost": n})
                    start, n = None, 0
                last_seen = ts
                if lost:
                    if start is None:
                        start = ts
                    n += 1
                    prev = ts
                else:
                    if start is not None and n >= min_len:
                        bursts.append({"target": t, "start": start, "end": prev, "lost": n})
                    start, n = None, 0
            if start is not None and n >= min_len:
                bursts.append({"target": t, "start": start, "end": prev, "lost": n,
                               "ongoing": time.time() - prev < GAP_S})
    bursts.sort(key=lambda b: b["start"], reverse=True)
    return {"since": since, "until": until, "min": min_len, "count": len(bursts),
            "bursts": bursts[:200]}


def q_latency(q):
    conn = db()
    if conn is None:
        return {"targets": []}
    with conn:
        since, until, _ = window(q, conn, MAX_SAMPLE_WINDOW_S)
        out = []
        for (t,) in conn.execute(
                "SELECT DISTINCT target FROM pings WHERE ts >= ? AND ts < ? ORDER BY target",
                (since, until)).fetchall():
            seq = [v for (v,) in conn.execute(
                "SELECT rtt_ms FROM pings WHERE target=? AND ts>=? AND ts<? AND lost=0 ORDER BY ts",
                (t, since, until))]
            jitter = (round(sum(abs(a - b) for a, b in zip(seq, seq[1:])) / (len(seq) - 1), 2)
                      if len(seq) > 1 else None)
            seq.sort()
            out.append({"name": t, "samples": len(seq), "p50": percentile(seq, 50),
                        "p95": percentile(seq, 95), "p99": percentile(seq, 99),
                        "max": round(seq[-1], 2) if seq else None, "jitter": jitter})
    return {"since": since, "until": until, "targets": out}


def q_spikes(q):
    conn = db()
    if conn is None:
        return {"spikes": []}
    try:
        over = float(q.get("over", ["100"])[0])
    except ValueError:
        over = 100.0
    with conn:
        since, until, _ = window(q, conn)
        rows = conn.execute("""
            SELECT ts, target, rtt_ms FROM pings
            WHERE ts >= ? AND ts < ? AND lost=0 AND rtt_ms > ?
            ORDER BY rtt_ms DESC LIMIT 50
        """, (since, until, over)).fetchall()
    return {"since": since, "until": until, "over": over,
            "spikes": [{"ts": r["ts"], "target": r["target"], "rtt": round(r["rtt_ms"], 2)}
                       for r in rows]}


def q_csv(q):
    """Same columns as netmon-report --csv / --csv-hourly."""
    conn = db()
    if conn is None:
        return "timestamp,target,packets,lost,loss_pct,avg_rtt_ms,max_rtt_ms\n"
    kind = q.get("kind", ["minute"])[0]
    fmt = "%Y-%m-%d %H:00:00" if kind == "hour" else "%Y-%m-%d %H:%M:00"
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["timestamp", "target", "packets", "lost", "loss_pct", "avg_rtt_ms", "max_rtt_ms"])
    with conn:
        since, until, _ = window(q, conn)
        for r in conn.execute(f"""
            SELECT strftime('{fmt}', ts, 'unixepoch', 'localtime') bucket, target,
                   COUNT(*) total, SUM(lost) lost,
                   AVG(CASE WHEN lost=0 THEN rtt_ms END) avg_rtt,
                   MAX(CASE WHEN lost=0 THEN rtt_ms END) max_rtt
            FROM pings WHERE ts >= ? AND ts < ? GROUP BY bucket, target ORDER BY bucket, target
        """, (since, until)):
            p = 100.0 * r["lost"] / r["total"] if r["total"] else 0
            w.writerow([r["bucket"], r["target"], r["total"], r["lost"], f"{p:.2f}",
                        f"{r['avg_rtt']:.2f}" if r["avg_rtt"] is not None else "",
                        f"{r['max_rtt']:.2f}" if r["max_rtt"] is not None else ""])
    return buf.getvalue()


_mtr_lock = threading.Lock()


def run_mtr(host, cycles):
    if not valid_host(host):
        return 400, {"error": f"'{host}' is not an IP address or host name"}
    if not _mtr_lock.acquire(blocking=False):
        return 409, {"error": "a path test is already running; wait for it to finish"}
    try:
        try:
            r = subprocess.run(["mtr", "-n", "-r", "-c", str(cycles), "--", host],
                               capture_output=True, text=True, timeout=cycles * 2 + 30)
        except FileNotFoundError:
            return 500, {"error": "mtr is not installed (apt install mtr-tiny)"}
        except subprocess.TimeoutExpired:
            return 504, {"error": "mtr took too long and was stopped"}
        hops = []
        for line in r.stdout.splitlines():
            m = re.match(r"\s*(\d+)\.\|--\s+(\S+)\s+([\d.]+)%?\s+(\d+)\s+([\d.]+)\s+([\d.]+)", line)
            if m:
                hops.append({"hop": int(m.group(1)), "host": m.group(2),
                             "loss": float(m.group(3)), "avg": float(m.group(6))})
        # the first hop past the gateway that answers: a sensible isp_edge
        edge = next((h["host"] for h in hops[1:] if h["host"] != "???" and h["loss"] < 100), None)
        return 200, {"output": r.stdout + r.stderr, "rc": r.returncode, "hops": hops,
                     "suggested_isp_edge": edge}
    finally:
        _mtr_lock.release()


# ------------------------------------------------------------------ http

class Handler(BaseHTTPRequestHandler):
    server_version = "netmon-web"

    def log_message(self, fmt, *args):
        pass   # quiet; errors are logged where they happen

    def send(self, code, body, ctype="application/json", extra=None):
        data = body if isinstance(body, bytes) else (
            json.dumps(body).encode() if ctype == "application/json" else body.encode())
        self.send_response(code)
        self.send_header("Content-Type", ctype + ("; charset=utf-8" if "json" in ctype or "text" in ctype else ""))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        key = u.path + "?" + u.query
        try:
            if u.path in ("/", "/index.html"):
                return self.send(200, STATIC.read_bytes(), "text/html")
            if u.path == "/api/status":
                return self.send(200, q_status())
            if u.path == "/api/settings":
                return self.send(200, current_settings())
            routes = {"/api/summary": q_summary, "/api/timeline": q_timeline,
                      "/api/hourly": q_hourly, "/api/bursts": q_bursts,
                      "/api/latency": q_latency, "/api/spikes": q_spikes}
            if u.path in routes:
                fn = routes[u.path]
                # A day of data costs ~1 s on the i3, a week several; the page
                # refreshes the dashboard every 30 s, so keep results that long.
                try:
                    big = float(q.get("hours", ["24"])[0]) > 24
                except ValueError:
                    big = False
                return self.send(200, cached(key, 300 if big else 25, lambda: fn(q)))
            if u.path == "/api/csv":
                name = f"netmon-{q.get('kind', ['minute'])[0]}-{datetime.now():%Y%m%d-%H%M}.csv"
                return self.send(200, q_csv(q), "text/csv",
                                 {"Content-Disposition": f'attachment; filename="{name}"'})
            return self.send(404, {"error": "not found"})
        except sqlite3.Error as e:
            log(f"db error on {u.path}: {e}")
            return self.send(503, {"error": f"database: {e}"})
        except Exception as e:  # noqa: BLE001 - one bad request must not kill the server
            log(f"error on {u.path}: {e!r}")
            return self.send(500, {"error": str(e)})

    def read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 16384:
            raise ValueError("request too large")
        return json.loads(self.rfile.read(n) or b"{}")

    def do_POST(self):
        u = urlparse(self.path)
        # A page on another site could otherwise POST here from a LAN browser.
        if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            return self.send(415, {"error": "send application/json"})
        try:
            body = self.read_json()
        except (ValueError, json.JSONDecodeError):
            return self.send(400, {"error": "body is not valid JSON"})
        try:
            if u.path == "/api/settings":
                s, err = validate_settings(body)
                if err:
                    return self.send(400, {"error": err})
                write_settings(s)
                requested = request_control("apply")
                log(f"settings saved: {len(s['targets'])} targets, interval {s['interval']}s")
                return self.send(200, {"ok": True, "settings": s, "restart_requested": requested})
            if u.path == "/api/control":
                action = body.get("action")
                if action not in ("start", "stop"):
                    return self.send(400, {"error": "action must be start or stop"})
                if not request_control(action):
                    return self.send(429, {"error": "one request every 3 seconds"})
                log(f"control: {action}")
                return self.send(200, {"ok": True, "action": action})
            if u.path == "/api/mtr":
                try:
                    cycles = max(1, min(int(body.get("cycles", 10)), 30))
                except (TypeError, ValueError):
                    cycles = 10
                code, out = run_mtr(str(body.get("host", "8.8.8.8")).strip(), cycles)
                return self.send(code, out)
            return self.send(404, {"error": "not found"})
        except OSError as e:
            log(f"error on {u.path}: {e!r}")
            return self.send(500, {"error": f"could not write to {DATA_DIR}: {e.strerror}"})


def main():
    srv = ThreadingHTTPServer((LISTEN, PORT), Handler)
    srv.daemon_threads = True
    log(f"netmon web on http://{LISTEN}:{PORT}  db={DB_PATH}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
