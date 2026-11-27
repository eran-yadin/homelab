#!/usr/bin/env python3
"""Jellyfin family accounts and guest shares, for `homelab jellyfin ...`.

The API key arrives on stdin (never on the command line, where `ps` shows
it). JF_API is Jellyfin's address, JF_SHARES the guest-share state file,
JF_LAN the address to tell people, JF_APPLY=1 when changes are allowed.
"""
import json, os, re, secrets, sys, time, urllib.error, urllib.request

API = os.environ["JF_API"]
SHARES = os.environ["JF_SHARES"]
LAN = os.environ.get("JF_LAN") or API
KEY = sys.stdin.readline().strip()

FAMILY_LIBS = ("Movies", "Shows", "Music")
KID_LIBS = ("Movies", "Shows")
GUEST_LIBS = ("Movies", "Shows")
# Items with no rating are hidden from children: unrated is not the same as safe.
UNRATED_BLOCK = ["Movie", "Series", "Trailer", "Other", "ChannelContent", "LiveTvProgram", "LiveTvChannel"]
NAME_OK = re.compile(r"^[A-Za-z0-9._-]{1,32}$")


def die(msg):
    print(f" err {msg}", file=sys.stderr)
    sys.exit(1)


def api(path, body=None, method=None):
    req = urllib.request.Request(
        API + path, json.dumps(body).encode() if body is not None else None,
        {"Authorization": f'MediaBrowser Token="{KEY}"', "Content-Type": "application/json"},
        method=method or ("POST" if body is not None else "GET"))
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = r.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        if e.code == 503:
            die("Jellyfin is still starting; try again in a minute")
        die(f"Jellyfin answered {e.code}: {e.read().decode(errors='replace')[:200]}")
    except urllib.error.URLError as e:
        die(f"Jellyfin is not answering at {API}: {e.reason}")


def password():
    """Easy to type with a TV remote: kq7m-3hxa-p2vd (no 0/o/1/l/i)."""
    abc = "abcdefghjkmnpqrstuvwxyz23456789"
    return "-".join("".join(secrets.choice(abc) for _ in range(4)) for _ in range(3))


def users():
    return api("/Users")


def find(name):
    for u in users():
        if u["Name"].lower() == name.lower():
            return u
    die(f"no Jellyfin user called {name}")


def folders(names):
    libs = {f["Name"]: f["ItemId"] for f in api("/Library/VirtualFolders")}
    missing = [n for n in names if n not in libs]
    return [libs[n] for n in names if n in libs], missing


def check_name(name):
    if not NAME_OK.match(name or ""):
        die("a name is 1-32 letters, digits, . _ or -")
    if any(u["Name"].lower() == name.lower() for u in users()):
        die(f"{name} already exists")


def new_user(name, policy):
    pw = password()
    u = api("/Users/New", {"Name": name, "Password": pw})
    pol = u["Policy"]
    # Family and kids appear on the login screen (pick your name on the TV);
    # guests pass IsHidden=True in `policy` and log in by typing their name.
    pol.update(IsAdministrator=False, IsHidden=False, EnableContentDeletion=False, EnableRemoteAccess=True,
               EnableMediaPlayback=True, EnableAudioPlaybackTranscoding=True,
               EnableVideoPlaybackTranscoding=True, EnablePlaybackRemuxing=True)
    pol.update(policy)
    api(f"/Users/{u['Id']}/Policy", pol)
    return u, pw


def how_to_login(name, pw):
    print(f"  server:   {LAN}")
    print(f"  user:     {name}")
    print(f"  password: {pw}")


# ------------------------------------------------------------------ users

def cmd_user(args):
    what = args[0] if args else "list"
    if what == "list":
        shares = load_shares()
        print(f"{'USER':<18} {'KIND':<26} LAST SEEN")
        for u in users():
            pol = u["Policy"]
            if pol.get("IsAdministrator"):
                kind = "admin"
            elif u["Name"] in shares:
                kind = "guest, ends " + time.strftime("%d/%m %H:%M", time.localtime(shares[u["Name"]]["until"]))
            elif pol.get("MaxParentalRating") is not None:
                kind = f"kid, ratings up to {pol['MaxParentalRating']}"
            else:
                kind = "family"
            print(f"{u['Name']:<18} {kind:<26} {str(u.get('LastActivityDate') or '-')[:16].replace('T', ' ')}")
    elif what == "add":
        if len(args) < 2:
            die("usage: homelab jellyfin user add NAME [--kid AGE]")
        name, kid = args[1], None
        if "--kid" in args:
            i = args.index("--kid")
            age = args[i + 1] if i + 1 < len(args) else "10"
            if not age.isdigit() or not 0 < int(age) < 19:
                die("--kid takes an age, 1 to 18")
            kid = int(age)
        check_name(name)
        if kid is None:
            ids, missing = folders(FAMILY_LIBS)
            policy = dict(EnableAllFolders=True, EnableContentDownloading=True)
        else:
            ids, missing = folders(KID_LIBS)
            if not ids:
                die("no Movies or Shows library yet: add them in Jellyfin first (Dashboard > Libraries)")
            policy = dict(EnableAllFolders=False, EnabledFolders=ids, MaxParentalRating=kid,
                          BlockUnratedItems=UNRATED_BLOCK, EnableContentDownloading=False,
                          EnableLiveTvAccess=False)
        u, pw = new_user(name, policy)
        print(f"  ok {name} created" + (f": child account, ratings up to {kid}, Movies + Shows only" if kid else ": family account"))
        how_to_login(name, pw)
        print("  (the password is shown this once; `homelab jellyfin user password NAME` makes a new one)")
    elif what == "password":
        if len(args) < 2:
            die("usage: homelab jellyfin user password NAME")
        u = find(args[1])
        if u["Policy"].get("IsAdministrator"):
            die("not for an admin account: change that one in Jellyfin itself")
        pw = password()
        api(f"/Users/{u['Id']}/Password", {"ResetPassword": True})
        api(f"/Users/{u['Id']}/Password", {"CurrentPw": "", "NewPw": pw})
        print(f"  ok new password for {u['Name']}: {pw}")
    elif what == "remove":
        if len(args) < 2:
            die("usage: homelab jellyfin user remove NAME")
        u = find(args[1])
        if u["Policy"].get("IsAdministrator"):
            die("will not remove an admin account here")
        api(f"/Users/{u['Id']}", method="DELETE")
        shares = load_shares()
        shares.pop(u["Name"], None)
        save_shares(shares)
        print(f"  ok removed {u['Name']}")
    else:
        die("usage: homelab jellyfin user list | add | password | remove")


# ------------------------------------------------------------------ shares

def load_shares():
    try:
        with open(SHARES) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_shares(d):
    os.makedirs(os.path.dirname(SHARES), exist_ok=True)
    tmp = SHARES + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, SHARES)


def end_share(name, shares):
    for u in users():
        if u["Name"] == name and not u["Policy"].get("IsAdministrator"):
            api(f"/Users/{u['Id']}", method="DELETE")
    shares.pop(name, None)


def cmd_share(args):
    what = args[0] if args else "list"
    shares = load_shares()
    now = time.time()
    if what == "list":
        if not shares:
            print("no guest shares")
        for n, s in sorted(shares.items()):
            left = max(0, int((s["until"] - now) / 60))
            print(f"{n:<18} ends {time.strftime('%d/%m %H:%M', time.localtime(s['until']))}  ({left // 60}h {left % 60}m left)")
    elif what == "stop":
        if len(args) < 2:
            die("usage: homelab jellyfin share stop NAME | stop all")
        names = list(shares) if args[1] == "all" else [args[1]]
        for n in names:
            if n not in shares:
                die(f"no guest share called {n}")
            end_share(n, shares)
            print(f"  ok share {n} ended, guest account removed")
        save_shares(shares)
    elif what == "expire":
        done = [n for n, s in shares.items() if s["until"] <= now]
        for n in done:
            end_share(n, shares)
            print(f"  ok share {n} expired, guest account removed")
        if done:
            save_shares(shares)
    else:
        name, hours = what, 24
        if "--hours" in args:
            i = args.index("--hours")
            h = args[i + 1] if i + 1 < len(args) else ""
            if not h.isdigit() or not 0 < int(h) <= 24 * 14:
                die("--hours takes 1 to 336 (two weeks)")
            hours = int(h)
        check_name(name)
        ids, missing = folders(GUEST_LIBS)
        if not ids:
            die("no Movies or Shows library yet: add them in Jellyfin first (Dashboard > Libraries)")
        u, pw = new_user(name, dict(IsHidden=True, EnableAllFolders=False, EnabledFolders=ids,
                                    EnableContentDownloading=False, MaxActiveSessions=2,
                                    LoginAttemptsBeforeLockout=5, EnableLiveTvAccess=False))
        shares[name] = {"until": int(now + hours * 3600), "created": int(now), "id": u["Id"]}
        save_shares(shares)
        print(f"  ok guest {name} for {hours} h (Movies + Shows, no downloads, 2 streams), ends "
              + time.strftime("%d/%m %H:%M", time.localtime(shares[name]["until"])))
        how_to_login(name, pw)
        print("  reachable from home and over Tailscale; a public link is not set up yet")


def main():
    if not KEY:
        die("no API key")
    args = sys.argv[1:]
    if not args:
        die("usage: user ... | share ...")
    {"user": cmd_user, "share": cmd_share}.get(args[0], lambda a: die("user or share"))(args[1:])


if __name__ == "__main__":
    main()
