#!/usr/bin/env python3
"""homelab hub - web front end over the homelab CLI.

Keeps the original hub's look and its /api/config + /api/status shape, but the
service list is no longer hardcoded here: it comes from the homelab catalog, so
an app added to apps/ shows up without touching this file.

Every state-changing action goes through one command -- `sudo homelab <verb>
<app> --apply` -- which is the only thing this needs sudo for.
"""

from flask import Flask, jsonify, request, send_from_directory
import subprocess, socket, os, re, time, json, shutil, threading

app = Flask(__name__, static_folder=".")

HOMELAB = os.environ.get("HOMELAB_BIN", "/opt/homelab/homelab")
HUB_STATE = os.environ.get("HUB_STATE", "/var/lib/homelab-hub")
FILTERS_FILE = os.path.join(HUB_STATE, "filters.json")

# `homelab update self --detach` runs as this transient unit and writes here.
# The unit is what makes the update survive the hub restart it causes.
UPDATE_UNIT = "homelab-self-update"
UPDATE_LOG = os.path.join(HUB_STATE, "update.log")
UPDATE_DONE = re.compile(r"^__HOMELAB_UPDATE_DONE__ rc=(\d+)", re.M)
VERSION_FILE = os.path.join(os.path.dirname(HOMELAB), "VERSION")


def homelab_version():
    """Written by `homelab deploy`; a tag name, or tag-N-ghash past a tag."""
    try:
        with open(VERSION_FILE) as f:
            return f.read().strip() or "unknown"
    except Exception:
        return "unknown"

MAX_FILTERS = 24
MAX_NAME = 40
HOSTNAME = socket.gethostname()
SYSTEMCTL = shutil.which("systemctl") or "/usr/bin/systemctl"

# Actions the UI is allowed to ask for. Anything else is rejected before it
# reaches a subprocess.
APP_ACTIONS = {"start", "stop", "restart", "update", "install", "delete"}
# What the hub itself stands on. Removing any of these from the hub would cut
# off the page doing the removing (or the network it is reached over); do it
# from a shell, deliberately.
NOT_REMOVABLE = {"hub", "caddy", "docker", "tailscale"}


def removable(a):
    """Adopted containers can go (the container only, data kept); an adopted
    service such as cockpit is an OS package and is left to apt."""
    if a["app"] in NOT_REMOVABLE:
        return False
    return not a.get("adopted") or a.get("kind") == "container"
SYSTEM_ACTIONS = {"reboot", "poweroff"}


# --------------------------------------------------------------- addresses

def local_ip():
    """The LAN address other machines would use to reach this box."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


_ts_cache = {"at": 0.0, "val": (None, None)}


def tailscale_info():
    """Tailscale IP and MagicDNS name, or None if tailscale isn't up.

    Returns (ip, dns_name). Either may be None. Cached for 30 s: the page
    polls often now that status is cheap, and this is a subprocess.
    """
    now = time.time()
    if now - _ts_cache["at"] < 30:
        return _ts_cache["val"]
    _ts_cache["val"] = _tailscale_info()
    _ts_cache["at"] = now
    return _ts_cache["val"]


def _tailscale_info():
    if not shutil.which("tailscale"):
        return None, None
    try:
        r = subprocess.run(["tailscale", "status", "--json"],
                           capture_output=True, text=True, timeout=4)
        if r.returncode != 0:
            return None, None
        d = json.loads(r.stdout)
        me = d.get("Self") or {}
        ips = me.get("TailscaleIPs") or []
        ip = next((a for a in ips if ":" not in a), None)     # prefer IPv4
        dns = (me.get("DNSName") or "").rstrip(".") or None
        return ip, dns
    except Exception:
        return None, None


# --------------------------------------------------------------- catalog

_catalog_cache = {"at": 0, "data": None}


def run_homelab(args, timeout=20):
    return subprocess.run([HOMELAB] + args, capture_output=True,
                          text=True, timeout=timeout)


def catalog(force=False):
    """`homelab list --json`, cached briefly - it shells out per app."""
    now = time.time()
    if not force and _catalog_cache["data"] and now - _catalog_cache["at"] < 30:
        return _catalog_cache["data"]
    try:
        r = run_homelab(["list", "--json"])
        data = json.loads(r.stdout) if r.returncode == 0 else []
    except Exception:
        data = []
    _catalog_cache.update(at=now, data=data)
    return data


def _status_lines(args, timeout):
    """`homelab status ... --json` prints one JSON object per app."""
    out = []
    try:
        r = run_homelab(["status"] + args + ["--json"], timeout=timeout)
        for line in r.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    except Exception:
        pass
    return out


# ------------------------------------------------------------ status cache
# A full `homelab status --all` takes a second or more on the NUC. Every page
# and every tab used to run one per poll. Now one background thread keeps the
# answer and requests read it. The thread stops refreshing when no page has
# asked for a while, so an unwatched hub costs nothing.
STATUS_INTERVAL = 30       # seconds between background refreshes
STATUS_INTERVAL_EVENTS = 120   # ...while docker events keep the cache current
STATUS_IDLE_AFTER = 120    # no request for this long -> stop refreshing
_status = {"services": {}, "at": 0.0, "asked": time.time()}
_status_lock = threading.Lock()      # guards _status
_refresh_lock = threading.Lock()     # one full refresh at a time


def refresh_all():
    with _refresh_lock:
        rows = _status_lines(["--all"], timeout=60)
        if rows:
            with _status_lock:
                _status["services"] = {r["app"]: r for r in rows}
                _status["at"] = time.time()


def refresh_one(app_id):
    """Re-read one app (after a button press) and fold it into the cache."""
    rows = _status_lines([app_id], timeout=30)
    with _status_lock:
        for r in rows:
            _status["services"][r["app"]] = r
    return rows[0] if rows else None


def app_statuses():
    """Statuses for the page. Cached; only a stale cache is refreshed inline,
    which happens on the first visit after the hub sat unwatched."""
    _status["asked"] = time.time()
    if time.time() - _status["at"] > STATUS_INTERVAL + 10:
        refresh_all()
    with _status_lock:
        return list(_status["services"].values())


def _status_loop():
    # With the event stream up, polling is only the safety net: it catches
    # what emits no docker event (systemd apps such as amp or netmon) and
    # anything the stream missed. Without it, poll as before.
    last = 0.0
    while True:
        every = STATUS_INTERVAL_EVENTS if _events["up"] else STATUS_INTERVAL
        if (time.time() - _status["asked"] < STATUS_IDLE_AFTER
                and time.time() - last >= every):
            try:
                refresh_all()
            except Exception:
                pass
            last = time.time()
        time.sleep(5)


# ------------------------------------------------------------ docker events
# A container that starts, stops, dies or changes health refreshes its app
# within a couple of seconds, instead of waiting for the next poll. Compose
# labels every container with its project, which is the app name; a bare
# container (feishin) has no label, so it triggers a full refresh instead.
EVENT_DEBOUNCE = 1.5       # `up` on a multi-container app fires a burst
_events = {"up": False, "pending": set(), "all": False, "last": 0.0}
_events_cv = threading.Condition()


def _events_reader():
    """Read `docker events` forever; reconnect with backoff when it drops
    (docker restarting, say). While it is down the poll interval is short."""
    backoff = 1
    argv = ["docker", "events", "--format", "{{json .}}",
            "--filter", "type=container",
            "--filter", "event=start", "--filter", "event=stop",
            "--filter", "event=die", "--filter", "event=destroy",
            "--filter", "event=health_status"]
    while True:
        started = time.time()
        try:
            p = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, text=True)
            _events["up"] = True
            for line in p.stdout:
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                attrs = (ev.get("Actor") or {}).get("Attributes") or {}
                proj = attrs.get("com.docker.compose.project")
                with _events_cv:
                    if proj:
                        _events["pending"].add(proj)
                    else:
                        _events["all"] = True
                    _events["last"] = time.time()
                    _events_cv.notify()
            p.wait()
        except Exception:
            pass
        _events["up"] = False
        # a stream that lived a while was healthy; start the backoff over
        backoff = 1 if time.time() - started > 60 else min(backoff * 2, 60)
        time.sleep(backoff)


def _events_worker():
    """Wait for a burst to settle, then re-read only the apps it touched."""
    while True:
        with _events_cv:
            while not _events["pending"] and not _events["all"]:
                _events_cv.wait()
            while time.time() - _events["last"] < EVENT_DEBOUNCE:
                _events_cv.wait(EVENT_DEBOUNCE)
            apps, everything = _events["pending"], _events["all"]
            _events["pending"], _events["all"] = set(), False
        try:
            known = {a["app"] for a in catalog()}
            if everything:
                refresh_all()
            else:
                for a in sorted(apps & known):
                    refresh_one(a)
        except Exception:
            pass


def urls_for(port, lip, tsip, tsdns):
    if not port:
        return {}
    u = {"local": f"http://{lip}:{port}"}
    host = tsdns or tsip
    if host:
        u["tailscale"] = f"http://{host}:{port}"
    return u


# -------------------------------------------------------------- filters
#
# Custom filters live on the server, not in localStorage, so the same view
# follows you from the laptop to the phone.

def load_filters():
    try:
        with open(FILTERS_FILE) as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except FileNotFoundError:
        return []
    except Exception:
        return []


def clean_filters(raw):
    """Validate what a client sent. This is written to disk, so be strict."""
    if not isinstance(raw, list):
        raise ValueError("expected a list of filters")
    known = {a["app"] for a in catalog()}
    out, seen = [], set()
    for item in raw[:MAX_FILTERS]:
        if not isinstance(item, dict):
            raise ValueError("each filter must be an object")
        name = str(item.get("name", "")).strip()
        name = "".join(c for c in name if c.isprintable())[:MAX_NAME]
        if not name:
            raise ValueError("every filter needs a name")
        fid = str(item.get("id", ""))
        fid = "".join(c for c in fid if c.isalnum())[:16]
        if not fid or fid in seen:
            fid = os.urandom(4).hex()
        seen.add(fid)
        apps = item.get("apps")
        if not isinstance(apps, list):
            raise ValueError(f"filter '{name}' has no app list")
        # silently drop apps that no longer exist rather than failing the save
        apps = [a for a in dict.fromkeys(str(x) for x in apps) if a in known]
        out.append({"id": fid, "name": name, "apps": apps})
    return out


def save_filters(data):
    os.makedirs(HUB_STATE, exist_ok=True)
    tmp = FILTERS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, FILTERS_FILE)      # atomic: never a half-written file


@app.route("/api/filters", methods=["GET"])
def api_filters_get():
    return jsonify(load_filters())


@app.route("/api/filters", methods=["PUT"])
def api_filters_put():
    try:
        cleaned = clean_filters(request.json)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    try:
        save_filters(cleaned)
    except OSError as e:
        return jsonify({"error": f"could not write {FILTERS_FILE}: {e}"}), 500
    return jsonify(cleaned)


# --------------------------------------------------------------- system

def read_system():
    """CPU / memory / disk / uptime, from /proc so there is no psutil dependency."""
    sys = {}
    try:
        with open("/proc/meminfo") as f:
            mi = {}
            for line in f:
                k, _, v = line.partition(":")
                mi[k] = int(v.split()[0]) * 1024
        total = mi.get("MemTotal", 0)
        avail = mi.get("MemAvailable", 0)
        used = total - avail
        sys["ram_total"] = round(total / 1024**3, 1)
        sys["ram_used"] = round(used / 1024**3, 1)
        sys["ram_pct"] = round(used / total * 100, 1) if total else 0
    except Exception:
        sys.update(ram_total=0, ram_used=0, ram_pct=0)

    try:
        st = os.statvfs("/")
        tot = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        used = tot - free
        sys["disk_total"] = round(tot / 1024**3, 1)
        sys["disk_used"] = round(used / 1024**3, 1)
        sys["disk_pct"] = round(used / tot * 100, 1) if tot else 0
    except Exception:
        sys.update(disk_total=0, disk_used=0, disk_pct=0)

    # Load average as a percentage of available cores reads more usefully on a
    # 2-core box than an instantaneous sample.
    try:
        load1 = os.getloadavg()[0]
        cores = os.cpu_count() or 1
        sys["cpu"] = round(min(load1 / cores * 100, 100), 1)
        sys["load"] = round(load1, 2)
        sys["cores"] = cores
    except Exception:
        sys["cpu"] = 0

    try:
        with open("/proc/stat") as f:
            for line in f:
                if line.startswith("btime"):
                    sys["boot_time"] = int(line.split()[1])
                    break
    except Exception:
        pass

    try:
        with open("/proc/uptime") as f:
            secs = int(float(f.read().split()[0]))
        d, rem = divmod(secs, 86400)
        h, m = divmod(rem // 60, 60)
        sys["uptime"] = f"{d}d {h}h {m}m" if d else f"{h}h {m}m"
    except Exception:
        sys["uptime"] = "?"

    temps = {}
    try:
        import glob
        best = 0.0
        for z in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
            with open(z) as f:
                best = max(best, int(f.read().strip()) / 1000.0)
        if best:
            temps["cpu"] = round(best, 1)
    except Exception:
        pass
    sys["temps"] = temps
    return sys


# --------------------------------------------------------------- api

@app.route("/api/config")
def api_config():
    lip = local_ip()
    tsip, tsdns = tailscale_info()
    out = []
    for a in catalog():
        port = None
        ports = (a.get("ports") or "").split()
        if ports:
            try:
                port = int(ports[0])
            except ValueError:
                port = None
        out.append({
            "id": a["app"],
            "name": a.get("title") or a["app"],
            "desc": a.get("desc", ""),
            "group": a.get("category", "misc"),
            "kind": a.get("kind", ""),
            "port": port,
            "urls": urls_for(port, lip, tsip, tsdns),
            "presence": a.get("presence", "unknown"),
            "stateful": bool(a.get("stateful")),
            "removable": removable(a),
            "adopted": bool(a.get("adopted")),
        })
    return jsonify(out)


@app.route("/api/status")
def api_status():
    # ?app=<id>: re-read just that one, now -- what the page asks for after
    # it changed something, instead of waiting on every app.
    one = request.args.get("app")
    if one:
        if one not in {a["app"] for a in catalog()}:
            return jsonify({"error": f"unknown app: {one}"}), 404
        row = refresh_one(one)
        return jsonify({"services": [row] if row else []})
    tsip, tsdns = tailscale_info()
    return jsonify({
        "services": app_statuses(),
        "system": read_system(),
        "net": {
            "hostname": HOSTNAME,
            "version": homelab_version(),
            "local_ip": local_ip(),
            "tailscale_ip": tsip,
            "tailscale_name": tsdns,
            "tailscale_up": bool(tsip),
        },
    })


@app.route("/api/control", methods=["POST"])
def api_control():
    data = request.json or {}
    app_id = data.get("service") or data.get("app")
    action = data.get("action")

    if action not in APP_ACTIONS:
        return jsonify({"error": f"invalid action: {action}"}), 400

    known = {a["app"]: a for a in catalog()}
    if app_id not in known:
        return jsonify({"error": f"unknown app: {app_id}"}), 404
    entry = known[app_id]

    # `update` on an app that holds data backs up and then asks. Non-
    # interactive, it stops with exit 3 having changed nothing; the page shows
    # what it printed and asks the person, then calls again with confirm.
    argv = ["sudo", "-n", HOMELAB, action, app_id, "--apply"]
    if action == "update" and data.get("confirm"):
        argv.append("--yes")

    # delete keeps the data unless purge is asked for. Purging an app that
    # holds data makes the engine ask for the app name on stdin; the page
    # collects it from the person and we hand it through unchanged, so the
    # engine's own check is the one that decides.
    stdin = None
    if action == "delete":
        if not removable(entry):
            return jsonify({"error": f"{app_id} can't be removed from the hub"}), 403
        if data.get("purge"):
            if entry.get("adopted"):
                return jsonify({"error": f"{app_id} is adopted; its data is not homelab's to delete"}), 403
            argv.append("--purge")
            if entry.get("stateful"):
                if data.get("confirm") != app_id:
                    return jsonify({"error": "type the app name to delete its data"}), 400
                stdin = app_id + "\n"

    # install can take many minutes (image pulls, builds)
    timeout = 1800 if action in ("install", "update") else 120
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           input=stdin if stdin is not None else "")
        _catalog_cache["at"] = 0          # presence may have changed
        status = refresh_one(app_id)       # the page repaints this card from it
        output = (r.stderr + r.stdout).strip()[-3000:]
        if r.returncode == 3:
            return jsonify({"success": False, "needs_confirm": True, "output": output})
        # exit 2 means "already in that state" - a success, not a failure
        ok = r.returncode in (0, 2)
        return jsonify({
            "success": ok,
            "noop": r.returncode == 2,
            "output": output[-1500:],
            "status": status,
        })
    except subprocess.TimeoutExpired:
        return jsonify({"success": False, "error": f"{action} timed out"}), 504
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500


def sudo_permits(argv):
    """Would sudo let us run this, without a password?"""
    try:
        r = subprocess.run(["sudo", "-n", "-l"] + argv,
                           capture_output=True, text=True, timeout=5)
        return r.returncode == 0
    except Exception:
        return False


@app.route("/api/system", methods=["POST"])
def api_system():
    data = request.json or {}
    action = data.get("action")
    if action not in SYSTEM_ACTIONS:
        return jsonify({"error": "invalid action"}), 400

    # Check permission BEFORE reporting success. Otherwise a missing sudoers
    # rule looks identical to a working reboot: the UI says "scheduled", the
    # machine never goes down, and nothing anywhere says why.
    if not sudo_permits([SYSTEMCTL, action]):
        return jsonify({
            "success": False,
            "error": f"not allowed to run '{SYSTEMCTL} {action}'. "
                     f"Is /etc/sudoers.d/homelab-hub installed for user "
                     f"{os.environ.get('USER', '?')}?",
        }), 403

    # Delayed on purpose: the HTTP response has to reach the browser before the
    # box goes down, or the UI shows a network error instead of saying what it
    # did -- and cannot then tell you it is waiting for the reboot.
    def go():
        time.sleep(3)
        r = subprocess.run(["sudo", "-n", SYSTEMCTL, action],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"[hub] {action} failed rc={r.returncode}: "
                  f"{(r.stderr or r.stdout).strip()}", flush=True)

    threading.Thread(target=go, daemon=True).start()
    return jsonify({"success": True, "action": action,
                    "message": f"{action} in 3 seconds"})


# ------------------------------------------------------------ self-update
#
# The Update button. The update itself is `homelab update self --detach`,
# which hands the work to a transient systemd unit and returns at once. It has
# to be that way: the update restarts this very service, and a restart kills
# every child the service has. So this never owns the update. It starts it,
# and then only reads a log file and asks systemd whether the unit is still
# there -- both of which work again the moment the hub is back.

def update_running():
    try:
        r = subprocess.run([SYSTEMCTL, "is-active", "--quiet", UPDATE_UNIT],
                           capture_output=True, timeout=5)
        return r.returncode == 0
    except Exception:
        return False


def read_update_log():
    try:
        with open(UPDATE_LOG, "r", errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return ""
    except Exception as e:
        return f"(cannot read {UPDATE_LOG}: {e})\n"


@app.route("/api/update/start", methods=["POST"])
def api_update_start():
    if update_running():
        return jsonify({"started": False, "running": True,
                        "message": "an update is already running"})
    argv = [HOMELAB, "update", "self", "--apply", "--detach"]
    if not sudo_permits(argv):
        return jsonify({"started": False,
                        "error": f"not allowed to run '{HOMELAB}' without a "
                                 f"password. Is /etc/sudoers.d/homelab-hub "
                                 f"installed?"}), 403
    try:
        r = subprocess.run(["sudo", "-n"] + argv, capture_output=True,
                           text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return jsonify({"started": False, "error": "starting the update timed out"}), 504
    if r.returncode != 0:
        return jsonify({"started": False,
                        "error": (r.stderr or r.stdout).strip()[-1500:]}), 500
    return jsonify({"started": True})


@app.route("/api/update/log")
def api_update_log():
    """The whole log each time. It is a few KB, and the browser tab may have
    been closed and reopened, so there is no cursor to keep."""
    text = read_update_log()
    m = UPDATE_DONE.search(text)
    running = update_running()
    return jsonify({
        "log": text,
        "running": running,
        "done": m is not None,
        "rc": int(m.group(1)) if m else None,
        "version": homelab_version(),
    })


@app.route("/update")
def update_page():
    return send_from_directory(".", "update.html")


@app.route("/docs")
def docs():
    """How the app store works, and how to add to it."""
    return send_from_directory(".", "docs.html")


@app.route("/")
def index():
    return send_from_directory(".", "index.html")


if __name__ == "__main__":
    threading.Thread(target=_status_loop, daemon=True, name="status").start()
    if shutil.which("docker"):
        threading.Thread(target=_events_reader, daemon=True, name="events").start()
        threading.Thread(target=_events_worker, daemon=True, name="events-worker").start()
    print(f"homelab hub on http://{local_ip()}:7070")
    app.run(host="0.0.0.0", port=7070, debug=False)
