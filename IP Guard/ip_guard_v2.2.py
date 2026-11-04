#!/usr/bin/env python3
"""
IP Guard v2.1 - whitelist firewall manager with an interactive menu and a Telegram bot.

One file, Python 3 standard library only. Uses its own nftables table "inet ip_guard"
(priority before the panel rules), so a panel Apply/restart does not remove it.

  python3 ip_guard.py            interactive menu (default)
  python3 ip_guard.py status     print the status
  python3 ip_guard.py apply      apply the saved config (used at boot by systemd)
  python3 ip_guard.py confirm    confirm the firewall (stops the auto-rollback timer)
  python3 ip_guard.py rollback   turn the firewall off (used by the rollback timer)
  python3 ip_guard.py bot        run the Telegram bot (used by systemd)
"""

import fcntl
import html
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import textwrap
import threading
import time
import urllib.error
import urllib.request

VERSION = "2.2"
TABLE = "ip_guard"
CONF_DIR = "/etc/ip-guard"
CONF = CONF_DIR + "/config.json"
STATE_DIR = "/var/lib/ip-guard"
PENDING = STATE_DIR + "/pending.json"
STATS = STATE_DIR + "/stats.json"
EVENTS = STATE_DIR + "/events.jsonl"
INSTALL_PATH = "/opt/ip-guard/ip_guard.py"
UNIT_DIR = "/etc/systemd/system"
BOT_UNIT = "ip-guard-bot.service"
BOOT_UNIT = "ip-guard.service"
ROLLBACK_UNIT = "ipguard-rollback"
CF_URLS = ("https://www.cloudflare.com/ips-v4", "https://www.cloudflare.com/ips-v6")
CF_FALLBACK = "/opt/hiddify-manager/services/haproxy/iplists/cloudflare.lst"
ARVAN_URLS = (
    "https://www.arvancloud.ir/en/ips.txt",
    "https://www.arvancloud.ir/fa/ips.txt",
)
FASTLY_URL = "https://api.fastly.com/public-ip-list"
TOP_TIMEOUT = "6h"  # how long a blocked/hit source IP stays in dynamic sets
CDN_HIT_TIMEOUT = "24h"  # how long CDN source IPs stay in hit tracking sets

DEFAULT_CFG = {
    "enabled": False,
    "mode": "all",
    "allow_ping": True,
    "ssh_port": 22,
    "ssh_open": True,
    "ports": [],
    "cloudflare": {"enabled": True, "v4": [], "v6": [], "updated": ""},
    "arvan": {"enabled": True, "v4": [], "v6": [], "updated": ""},
    "fastly": {"enabled": True, "v4": [], "v6": [], "updated": ""},
    "cdn_track": True,
    "rollback_minutes": 20,
    "next_id": 5,
    "whitelist": [
        {"id": 1, "cidr": "94.139.180.216", "label": "iran-relay-1", "enabled": True},
        {"id": 2, "cidr": "94.139.180.191", "label": "iran-relay-2", "enabled": True},
        {"id": 3, "cidr": "91.108.146.241", "label": "iran-relay-3", "enabled": True},
        {"id": 4, "cidr": "185.249.9.49", "label": "iran-relay-4", "enabled": True},
    ],
    "bot": {"token": "", "admins": []},
}


# ============================================================================ config

def load_cfg():
    if not os.path.exists(CONF):
        return json.loads(json.dumps(DEFAULT_CFG))
    with open(CONF, "r", encoding="utf-8") as fh:
        cfg = json.load(fh)
    for k, v in DEFAULT_CFG.items():
        cfg.setdefault(k, json.loads(json.dumps(v)))
    # ensure nested defaults for cloudflare / arvan
    for key in ("cloudflare", "arvan", "fastly"):
        if key not in cfg or not isinstance(cfg[key], dict):
            cfg[key] = json.loads(json.dumps(DEFAULT_CFG[key]))
        else:
            for sk, sv in DEFAULT_CFG[key].items():
                cfg[key].setdefault(sk, json.loads(json.dumps(sv)))
    return cfg


def write_json(path, data, mode=0o600):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def save_cfg(cfg):
    write_json(CONF, cfg)


class Locked:
    """Serialise config changes between the menu, the bot and systemd jobs (re-entrant)."""
    depth = 0
    fh = None

    def __enter__(self):
        if Locked.depth == 0:
            os.makedirs(STATE_DIR, exist_ok=True)
            Locked.fh = open(STATE_DIR + "/lock", "w")
            fcntl.flock(Locked.fh, fcntl.LOCK_EX)
        Locked.depth += 1
        return self

    def __exit__(self, *a):
        Locked.depth -= 1
        if Locked.depth == 0:
            fcntl.flock(Locked.fh, fcntl.LOCK_UN)
            Locked.fh.close()
            Locked.fh = None


def update(fn):
    """Read-modify-apply-save under the lock. Saves only if the apply worked.
    Returns (fn result, ok, message)."""
    with Locked():
        cfg = load_cfg()
        res = fn(cfg)
        ok, msg = apply_cfg(cfg)
        if ok:
            save_cfg(cfg)
    return res, ok, ("Saved and applied." if ok else msg + " Nothing was saved.")


def norm_net(text):
    """Return a normalised network string, or raise ValueError."""
    net = ipaddress.ip_network(text.strip(), strict=False)
    if net.prefixlen < (8 if net.version == 4 else 16):
        raise ValueError("%s is too wide to whitelist." % net)
    return str(net.network_address) if net.num_addresses == 1 else str(net)


# ============================================================================ nftables

def _set(name, kind, items):
    elems = "    elements = { %s }\n" % ", ".join(items) if items else ""
    return "  set %s {\n    type %s\n    flags interval\n    auto-merge\n%s  }\n" % (name, kind, elems)


def _dyn(name, kind):
    return ("  set %s {\n    type %s\n    size 65535\n    flags dynamic,timeout\n    timeout %s\n  }\n"
            % (name, kind, TOP_TIMEOUT))


def render_ruleset(cfg):
    wl4, wl6 = [], []
    for e in cfg["whitelist"]:
        if e["enabled"]:
            (wl6 if ":" in e["cidr"] else wl4).append(e["cidr"])
    cf = cfg["cloudflare"]
    cf4 = cf["v4"] if cf["enabled"] else []
    cf6 = cf["v6"] if cf["enabled"] else []
    av = cfg.get("arvan") or {}
    av4 = av.get("v4", []) if av.get("enabled") else []
    av6 = av.get("v6", []) if av.get("enabled") else []
    fs = cfg.get("fastly") or {}
    fs4 = fs.get("v4", []) if fs.get("enabled") else []
    fs6 = fs.get("v6", []) if fs.get("enabled") else []
    track = bool(cfg.get("cdn_track", True))
    tcp = sorted({p["port"] for p in cfg["ports"] if p["proto"] in ("tcp", "both")})
    udp = sorted({p["port"] for p in cfg["ports"] if p["proto"] in ("udp", "both")})
    ssh = cfg["ssh_port"]

    out = ["table inet %s" % TABLE, "delete table inet %s" % TABLE, "table inet %s {" % TABLE,
           "  counter dropped { }", "  counter ssh_dropped { }",
           _set("wl4", "ipv4_addr", wl4), _set("wl6", "ipv6_addr", wl6),
           _set("cf4", "ipv4_addr", cf4), _set("cf6", "ipv6_addr", cf6),
           _set("av4", "ipv4_addr", av4), _set("av6", "ipv6_addr", av6),
           _set("fs4", "ipv4_addr", fs4), _set("fs6", "ipv6_addr", fs6),
           _dyn("blk4", "ipv4_addr"), _dyn("blk6", "ipv6_addr")]
    # CDN hit tracking sets (source IPs that connected via CDN ranges)
    if track:
        for prefix in ("cf", "av", "fs"):
            for fam, typ in (("4", "ipv4_addr"), ("6", "ipv6_addr")):
                out.append("  set %s_hit%s {" % (prefix, fam))
                out.append("    type %s" % typ)
                out.append("    size 65535")
                out.append("    flags dynamic,timeout")
                out.append("    timeout %s" % CDN_HIT_TIMEOUT)
                out.append("  }")
    out += [
           "  chain blocked {",
           "    update @blk4 { ip saddr counter }",
           "    update @blk6 { ip6 saddr counter }",
           '    counter name "dropped" drop',
           "  }",
           "  chain input {",
           "    type filter hook input priority -20; policy accept;",
           '    iifname "lo" accept',
           "    ct state established,related accept"]
    ssh_drop = '    tcp dport %d counter name "ssh_dropped" goto blocked' % ssh

    def add_cdn_rules():
        if cf4 or cf6:
            if track:
                out.append("    ip saddr @cf4 update @cf_hit4 { ip saddr counter } accept")
                out.append("    ip6 saddr @cf6 update @cf_hit6 { ip6 saddr counter } accept")
            else:
                out.append("    ip saddr @cf4 accept")
                out.append("    ip6 saddr @cf6 accept")
        if av4 or av6:
            if track:
                out.append("    ip saddr @av4 update @av_hit4 { ip saddr counter } accept")
                out.append("    ip6 saddr @av6 update @av_hit6 { ip6 saddr counter } accept")
            else:
                out.append("    ip saddr @av4 accept")
                out.append("    ip6 saddr @av6 accept")
        if fs4 or fs6:
            if track:
                out.append("    ip saddr @fs4 update @fs_hit4 { ip saddr counter } accept")
                out.append("    ip6 saddr @fs6 update @fs_hit6 { ip6 saddr counter } accept")
            else:
                out.append("    ip saddr @fs4 accept")
                out.append("    ip6 saddr @fs6 accept")

    if cfg["mode"] == "all":
        out.append("    ip6 nexthdr icmpv6 accept")  # IPv6 does not work without ICMPv6
        if cfg["allow_ping"]:
            out.append("    ip protocol icmp accept")
        out.append("    udp sport 67 udp dport 68 accept")  # DHCP client replies
        out.append("    udp dport 546 accept")  # DHCPv6 client replies
        out.append("    ip saddr @wl4 accept")
        out.append("    ip6 saddr @wl6 accept")
        out.append(("    tcp dport %d accept" % ssh) if cfg["ssh_open"] else ssh_drop)
        add_cdn_rules()
        out.append("    goto blocked")
    else:
        out.append("    ip saddr @wl4 accept")
        out.append("    ip6 saddr @wl6 accept")
        if not cfg["ssh_open"]:
            out.append(ssh_drop)
        add_cdn_rules()
        if tcp:
            out.append("    tcp dport { %s } goto blocked" % ", ".join(map(str, tcp)))
        if udp:
            out.append("    udp dport { %s } goto blocked" % ", ".join(map(str, udp)))
    out += ["  }", "}"]
    return "\n".join(out) + "\n"


def run(cmd, data=None):
    try:
        return subprocess.run(cmd, input=data, capture_output=True, text=True)
    except OSError as exc:
        return subprocess.CompletedProcess(cmd, 127, "", str(exc))


def table_exists():
    return run(["nft", "list", "table", "inet", TABLE]).returncode == 0


def apply_cfg(cfg):
    """Apply the config. Returns (ok, message)."""
    loaded = table_exists()
    if loaded:
        bank_stats()  # counters live in the table and reset when it is rebuilt
    if not cfg["enabled"]:
        if loaded:
            r = run(["nft", "delete", "table", "inet", TABLE])
            if r.returncode != 0:
                return False, r.stderr.strip()
        return True, "Firewall is OFF: every IP can connect."
    rules = render_ruleset(cfg)
    r = run(["nft", "-c", "-f", "-"], rules)
    if r.returncode != 0:
        return False, "Rule check failed: " + r.stderr.strip()
    r = run(["nft", "-f", "-"], rules)
    if r.returncode != 0:
        return False, "Apply failed: " + r.stderr.strip()
    return True, "Firewall is ON."


# ============================================================================ statistics

def nft_json(*args):
    r = run(["nft", "-j"] + list(args))
    if r.returncode != 0:
        return []
    try:
        return json.loads(r.stdout).get("nftables", [])
    except ValueError:
        return []


def _read_set_counters(set_name):
    """Return {ip: packets} from a dynamic set with counters."""
    out = {}
    for o in nft_json("list", "set", "inet", TABLE, set_name):
        for el in (o.get("set") or {}).get("elem", []):
            e = el.get("elem") if isinstance(el, dict) else None
            if e and "counter" in e:
                out[e["val"]] = e["counter"].get("packets", 0)
    return out


def live_stats():
    s = {"packets": 0, "bytes": 0, "ssh": 0, "top": {},
         "cdn": {"cloudflare": {}, "arvan": {}, "fastly": {}}}
    for o in nft_json("list", "counters", "table", "inet", TABLE):
        ct = o.get("counter") or {}
        if ct.get("name") == "dropped":
            s["packets"], s["bytes"] = ct.get("packets", 0), ct.get("bytes", 0)
        elif ct.get("name") == "ssh_dropped":
            s["ssh"] = ct.get("packets", 0)
    for name in ("blk4", "blk6"):
        for ip, n in _read_set_counters(name).items():
            s["top"][ip] = s["top"].get(ip, 0) + n
    # CDN hit tracking
    mapping = {
        "cloudflare": ("cf_hit4", "cf_hit6"),
        "arvan": ("av_hit4", "av_hit6"),
        "fastly": ("fs_hit4", "fs_hit6"),
    }
    for provider, sets in mapping.items():
        for set_name in sets:
            for ip, n in _read_set_counters(set_name).items():
                s["cdn"][provider][ip] = s["cdn"][provider].get(ip, 0) + n
    return s


def load_stats():
    try:
        with open(STATS) as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        d = {}
    d.setdefault("since", int(time.time()))
    for k in ("packets", "bytes", "ssh"):
        d.setdefault(k, 0)
    d.setdefault("top", {})
    d.setdefault("cdn", {"cloudflare": {}, "arvan": {}, "fastly": {}})
    for p in ("cloudflare", "arvan", "fastly"):
        d["cdn"].setdefault(p, {})
    return d


def bank_stats():
    live = live_stats()
    has_cdn = any(live.get("cdn", {}).get(p) for p in ("cloudflare", "arvan", "fastly"))
    if not (live["packets"] or live["top"] or has_cdn):
        return
    d = load_stats()
    for k in ("packets", "bytes", "ssh"):
        d[k] += live[k]
    for ip, n in live["top"].items():
        d["top"][ip] = d["top"].get(ip, 0) + n
    d["top"] = dict(sorted(d["top"].items(), key=lambda kv: -kv[1])[:200])
    for p in ("cloudflare", "arvan", "fastly"):
        for ip, n in live.get("cdn", {}).get(p, {}).items():
            d["cdn"][p][ip] = d["cdn"][p].get(ip, 0) + n
        d["cdn"][p] = dict(sorted(d["cdn"][p].items(), key=lambda kv: -kv[1])[:200])
    write_json(STATS, d, 0o644)


def get_stats():
    d, live = load_stats(), live_stats()
    for k in ("packets", "bytes", "ssh"):
        d[k] += live[k]
    top = dict(d["top"])
    for ip, n in live["top"].items():
        top[ip] = top.get(ip, 0) + n
    d["top"] = sorted(top.items(), key=lambda kv: -kv[1])[:10]
    cdn = {}
    for p in ("cloudflare", "arvan", "fastly"):
        merged = dict(d.get("cdn", {}).get(p, {}))
        for ip, n in live.get("cdn", {}).get(p, {}).items():
            merged[ip] = merged.get(ip, 0) + n
        cdn[p] = sorted(merged.items(), key=lambda kv: -kv[1])[:15]
    d["cdn"] = cdn
    return d


def reset_stats():
    if table_exists():
        run(["nft", "reset", "counters", "table", "inet", TABLE])
        for name in ("blk4", "blk6", "cf_hit4", "cf_hit6", "av_hit4", "av_hit6", "fs_hit4", "fs_hit6"):
            run(["nft", "flush", "set", "inet", TABLE, name])
    write_json(STATS, {"since": int(time.time()), "packets": 0, "bytes": 0, "ssh": 0, "top": {},
                       "cdn": {"cloudflare": {}, "arvan": {}, "fastly": {}}}, 0o644)


# ============================================================================ server info

_IPS = {"t": 0, "v4": None, "v6": None}


def _route_src(target, six):
    r = run(["ip", "-j"] + (["-6"] if six else []) + ["route", "get", target])
    try:
        return json.loads(r.stdout)[0].get("prefsrc")
    except (ValueError, IndexError, AttributeError):
        return None


def _public(ip):
    try:
        return bool(ip) and ipaddress.ip_address(ip).is_global
    except ValueError:
        return False


def server_ips():
    """Public IPv4/IPv6 of this server (cached for 10 minutes)."""
    if time.time() - _IPS["t"] < 600:
        return _IPS["v4"], _IPS["v6"]
    v4 = _route_src("1.1.1.1", False)
    v6 = _route_src("2606:4700:4700::1111", True)
    if not _public(v4):  # behind NAT: ask an outside service
        try:
            with urllib.request.urlopen("https://api.ipify.org", timeout=5) as r:
                v4 = r.read().decode().strip()
        except (urllib.error.URLError, OSError, ValueError):
            pass
    _IPS.update(t=time.time(), v4=v4 if _public(v4) else None, v6=v6 if _public(v6) else None)
    return _IPS["v4"], _IPS["v6"]


def _cpu_snap():
    with open("/proc/stat") as fh:
        vals = [int(x) for x in fh.readline().split()[1:]]
    return sum(vals), vals[3] + (vals[4] if len(vals) > 4 else 0)


def sysinfo():
    info = {"host": socket.gethostname(), "up": 0, "load": (0, 0, 0), "cpu": 0, "ncpu": os.cpu_count() or 1,
            "mem_total": 0, "mem_used": 0, "disk_total": 0, "disk_used": 0}
    try:
        with open("/proc/uptime") as fh:
            info["up"] = float(fh.read().split()[0])
        info["load"] = os.getloadavg()
        t1, i1 = _cpu_snap()
        time.sleep(0.25)
        t2, i2 = _cpu_snap()
        info["cpu"] = round(100 * (1 - (i2 - i1) / max(1, t2 - t1)))
        mem = {}
        with open("/proc/meminfo") as fh:
            for line in fh:
                k, v = line.split(":", 1)
                mem[k] = int(v.split()[0]) * 1024
        info["mem_total"] = mem.get("MemTotal", 0)
        info["mem_used"] = info["mem_total"] - mem.get("MemAvailable", 0)
        du = shutil.disk_usage("/")
        info["disk_total"], info["disk_used"] = du.total, du.used
    except (OSError, ValueError):
        pass
    return info


def fmt_bytes(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%d %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0


def fmt_uptime(sec):
    d, rem = divmod(int(sec), 86400)
    h, rem = divmod(rem, 3600)
    return "%dd %dh %dm" % (d, h, rem // 60)


def svc_state(unit):
    return run(["systemctl", "is-active", unit]).stdout.strip() or "unknown"


def install_outdated():
    try:
        with open(INSTALL_PATH, "rb") as a, open(os.path.abspath(__file__), "rb") as b:
            return a.read() != b.read()
    except OSError:
        return False


# ============================================================================ rollback timer

def script_path():
    return INSTALL_PATH if os.path.exists(INSTALL_PATH) else os.path.abspath(__file__)


def pending_info():
    try:
        with open(PENDING, "r") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def start_rollback(minutes):
    stop_timer()
    os.makedirs(STATE_DIR, exist_ok=True)
    seconds = int(minutes) * 60
    r = run(["systemd-run", "--unit=" + ROLLBACK_UNIT, "--on-active=%ds" % seconds,
             sys.executable, script_path(), "rollback"])
    if r.returncode != 0:
        return False, "Could not start the rollback timer: " + r.stderr.strip()
    with open(PENDING, "w") as fh:
        json.dump({"deadline": int(time.time()) + seconds}, fh)
    return True, ""


def stop_timer():
    run(["systemctl", "stop", ROLLBACK_UNIT + ".timer", ROLLBACK_UNIT + ".service"])


def clear_pending():
    stop_timer()
    try:
        os.unlink(PENDING)
    except OSError:
        pass


def minutes_left():
    p = pending_info()
    return max(0, (p["deadline"] - int(time.time())) // 60) if p else None


# ============================================================================ core actions

def ssh_client_ip():
    parts = os.environ.get("SSH_CONNECTION", "").split()
    return parts[0] if parts else None


def covered(cfg, ip):
    addr = ipaddress.ip_address(ip)
    return any(e["enabled"] and addr in ipaddress.ip_network(e["cidr"]) for e in cfg["whitelist"])


def add_whitelist(cfg, text, label=""):
    cidr = norm_net(text)
    if any(e["cidr"] == cidr for e in cfg["whitelist"]):
        raise ValueError("%s is already in the list." % cidr)
    entry = {"id": cfg["next_id"], "cidr": cidr, "label": label.strip()[:40], "enabled": True,
             "added": time.strftime("%Y-%m-%d %H:%M")}
    cfg["next_id"] += 1
    cfg["whitelist"].append(entry)
    return entry


def find_entry(cfg, eid):
    for e in cfg["whitelist"]:
        if e["id"] == int(eid):
            return e
    raise ValueError("No entry with id %s." % eid)


def fw_on(cfg):
    """Switch ON with the safety timer. Call under the lock. Returns (ok, message)."""
    if cfg["cloudflare"]["enabled"] and not cfg["cloudflare"]["v4"]:
        ok, msg = fetch_cloudflare(cfg)  # empty ranges would cut every CDN config
        if not ok:
            return False, "Cloudflare ranges are empty and could not be fetched (%s)." % msg
    if cfg.get("arvan", {}).get("enabled") and not cfg.get("arvan", {}).get("v4"):
        ok, msg = fetch_arvan(cfg)
        if not ok:
            return False, "Arvan Cloud ranges are empty and could not be fetched (%s)." % msg
    if cfg.get("fastly", {}).get("enabled") and not cfg.get("fastly", {}).get("v4"):
        ok, msg = fetch_fastly(cfg)
        if not ok:
            return False, "Fastly ranges are empty and could not be fetched (%s)." % msg
    ip = ssh_client_ip()
    note_ = ""
    if ip and not covered(cfg, ip):
        add_whitelist(cfg, ip, "ssh-session-auto")
        note_ = " Your SSH IP %s was added to the whitelist." % ip
    cfg["enabled"] = True
    ok, msg = apply_cfg(cfg)
    if not ok:
        return False, msg
    save_cfg(cfg)
    ok, tmsg = start_rollback(cfg["rollback_minutes"])
    if not ok:
        cfg["enabled"] = False
        apply_cfg(cfg)
        save_cfg(cfg)
        return False, tmsg + " The firewall was switched OFF again."
    return True, "Firewall ON.%s Confirm within %d min or it switches OFF by itself." % (
        note_, cfg["rollback_minutes"])


def fetch_cloudflare(cfg):
    v4, v6, how = [], [], "cloudflare.com"
    try:
        for url in CF_URLS:
            with urllib.request.urlopen(url, timeout=15) as r:
                for line in r.read().decode().split():
                    net = norm_net(line)
                    (v6 if ":" in net else v4).append(net)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        v4, v6, how = [], [], "the panel's local list (web failed: %s)" % exc
        try:
            with open(CF_FALLBACK) as fh:
                for line in fh:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        net = norm_net(line)
                        (v6 if ":" in net else v4).append(net)
        except (OSError, ValueError) as exc2:
            return False, "Could not read Cloudflare ranges: %s" % exc2
    if not v4:
        return False, "No IPv4 ranges found; nothing changed."
    cfg["cloudflare"].update({"v4": v4, "v6": v6, "updated": time.strftime("%Y-%m-%d %H:%M")})
    return True, "Cloudflare ranges updated from %s: %d IPv4, %d IPv6." % (how, len(v4), len(v6))


def fetch_arvan(cfg):
    """Fetch Arvan Cloud CDN IP ranges from official ips.txt."""
    v4, v6, how, last_err = [], [], "arvancloud.ir", None
    for url in ARVAN_URLS:
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                body = r.read().decode("utf-8", "replace")
            for line in body.splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                # some pages embed extra text; take the first token that looks like a CIDR/IP
                token = line.split()[0]
                try:
                    net = norm_net(token)
                except ValueError:
                    continue
                (v6 if ":" in net else v4).append(net)
            if v4 or v6:
                how = url
                break
        except (urllib.error.URLError, OSError, ValueError) as exc:
            last_err = exc
            continue
    # dedupe while preserving order
    def uniq(seq):
        seen, out = set(), []
        for x in seq:
            if x not in seen:
                seen.add(x)
                out.append(x)
        return out
    v4, v6 = uniq(v4), uniq(v6)
    if not v4 and not v6:
        return False, "Could not fetch Arvan Cloud ranges%s." % (
            (" (last error: %s)" % last_err) if last_err else "")
    cfg.setdefault("arvan", {"enabled": True, "v4": [], "v6": [], "updated": ""})
    cfg["arvan"].update({"v4": v4, "v6": v6, "updated": time.strftime("%Y-%m-%d %H:%M")})
    return True, "Arvan Cloud ranges updated from %s: %d IPv4, %d IPv6." % (how, len(v4), len(v6))


def fetch_fastly(cfg):
    """Fetch Fastly CDN IP ranges from the official public-ip-list API."""
    try:
        with urllib.request.urlopen(FASTLY_URL, timeout=20) as r:
            data = json.loads(r.read().decode())
        v4, v6 = [], []
        for line in data.get("addresses") or []:
            try:
                v4.append(norm_net(line))
            except ValueError:
                pass
        for line in data.get("ipv6_addresses") or []:
            try:
                v6.append(norm_net(line))
            except ValueError:
                pass
        # dedupe
        def uniq(seq):
            seen, out = set(), []
            for x in seq:
                if x not in seen:
                    seen.add(x)
                    out.append(x)
            return out
        v4, v6 = uniq(v4), uniq(v6)
        if not v4 and not v6:
            return False, "No Fastly ranges found; nothing changed."
        cfg.setdefault("fastly", {"enabled": True, "v4": [], "v6": [], "updated": ""})
        cfg["fastly"].update({"v4": v4, "v6": v6, "updated": time.strftime("%Y-%m-%d %H:%M")})
        return True, "Fastly ranges updated: %d IPv4, %d IPv6." % (len(v4), len(v6))
    except (urllib.error.URLError, OSError, ValueError, KeyError) as exc:
        return False, "Could not fetch Fastly ranges: %s" % exc


# ---------------------------------------------------------------------------- events

EVENT_FA = {
    "fw_on": "🟢 فایروال روشن شد (باید تا {minutes} دقیقه تایید شود)",
    "fw_off": "🔴 فایروال خاموش شد؛ همه‌ی IPها مجازند",
    "fw_confirm": "✅ فایروال تایید شد؛ بازگشت خودکار لغو شد",
    "fw_rollback": "⚠️ فایروال تایید نشد و خودکار خاموش شد",
    "wl_add": "➕ به لیست سفید اضافه شد:\n{items}",
    "wl_del": "🗑 از لیست سفید حذف شد: {cidr} {label}",
    "wl_on": "🟢 فعال شد: {cidr} {label}",
    "wl_off": "⚪ غیرفعال شد: {cidr} {label}",
    "wl_label": "✏️ برچسب {cidr} شد: {label}",
    "mode": "🧱 حالت بلاک: {mode}",
    "ping": "📶 پینگ از همه: {state}",
    "ssh": "🔑 SSH: {state}",
    "ssh_port": "🔑 پورت SSH: {port}",
    "ports": "🔌 پورت‌های محدود: {ports}",
    "cf_update": "☁️ رنج‌های کلادفلر بروز شد: {v4} IPv4 و {v6} IPv6",
    "cf_allow": "☁️ کلادفلر: {state}",
    "arvan_update": "🟣 رنج‌های آروان‌کلاد بروز شد: {v4} IPv4 و {v6} IPv6",
    "arvan_allow": "🟣 آروان‌کلاد: {state}",
    "fastly_update": "⚡ رنج‌های Fastly بروز شد: {v4} IPv4 و {v6} IPv6",
    "fastly_allow": "⚡ Fastly: {state}",
    "cdn_track": "📡 ردیابی CDN: {state}",
    "rollback": "⏳ زمان بازگشت خودکار: {minutes} دقیقه",
    "stats_reset": "📊 آمار بلاک صفر شد",
    "install": "📦 فایل‌های سیستم نصب/بروزرسانی شد",
}


class _Blank(dict):
    def __missing__(self, key):
        return ""


def fmt_who(who):
    return {"terminal": "🖥 ترمینال", "system": "⚙️ سیستم"}.get(who, "👤 " + who)


def fmt_event(rec):
    k, a = rec.get("kind", ""), _Blank({x: html.escape(str(y)) for x, y in rec.items()})
    if k == "mode":
        a["mode"] = "همه‌ی IPها به جز لیست سفید" if rec.get("mode") == "all" else "فقط پورت‌های انتخابی"
    elif k in ("ping", "cf_allow", "arvan_allow", "fastly_allow", "cdn_track"):
        a["state"] = "مجاز" if rec.get("on") else "غیرمجاز"
    elif k == "ssh":
        a["state"] = "باز برای همه" if rec.get("on") else "بسته (فقط لیست سفید)"
    elif k == "wl_add":
        a["items"] = "\n".join("• <code>%s</code> %s" % (html.escape(c_), html.escape(l_))
                               for c_, l_ in rec.get("items", []))
    elif k == "ports":
        a["ports"] = html.escape(rec.get("ports") or "-")
    return EVENT_FA.get(k, html.escape(k)).format_map(a)


def notify_admins(cfg, text, skip=None):
    if not cfg["bot"]["token"]:
        return
    api = TG(cfg["bot"]["token"])
    for admin in cfg["bot"]["admins"]:
        if admin == skip:
            continue
        try:
            api.call("sendMessage", _timeout=15, chat_id=admin, text=text, parse_mode="HTML",
                     disable_web_page_preview=True)
        except (urllib.error.URLError, OSError, ValueError):
            pass


def event(kind, who="terminal", skip=None, **kw):
    """Log a change and tell every bot admin (except `skip`, the admin who made it)."""
    rec = dict(kw, t=int(time.time()), kind=kind, who=who)
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(EVENTS, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        with open(EVENTS, encoding="utf-8") as fh:
            lines = fh.readlines()
        if len(lines) > 400:
            with open(EVENTS, "w", encoding="utf-8") as fh:
                fh.writelines(lines[-300:])
    except OSError:
        pass
    cfg = load_cfg()
    if cfg["bot"]["token"] and cfg["bot"]["admins"]:
        text = "🔔 <b>%s</b>\n%s\n<i>%s · %s</i>" % (
            html.escape(socket.gethostname()), fmt_event(rec), html.escape(fmt_who(who)),
            time.strftime("%H:%M:%S"))
        threading.Thread(target=notify_admins, args=(cfg, text, skip)).start()


def recent_events(n=15):
    try:
        with open(EVENTS, encoding="utf-8") as fh:
            lines = fh.readlines()[-n:]
    except OSError:
        return []
    out = []
    for line in reversed(lines):
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


# ---------------------------------------------------------------------------- actions used by menu and bot

def _desc(e):
    return {"cidr": e["cidr"], "label": e.get("label", "")}


def act_wl_add(pairs, who="terminal", skip=None):
    added, errors = [], []

    def fn(cfg):
        for text, label in pairs:
            try:
                added.append(add_whitelist(cfg, text, label))
            except ValueError as exc:
                errors.append(str(exc))
    _, ok, msg = update(fn)
    if ok and added:
        event("wl_add", who, skip, items=[[e["cidr"], e["label"]] for e in added])
    return (added if ok else []), errors, ok, msg


def act_wl_remove(eid, who="terminal", skip=None):
    def fn(cfg):
        e = find_entry(cfg, eid)
        cfg["whitelist"].remove(e)
        return e
    e, ok, msg = update(fn)
    if ok:
        event("wl_del", who, skip, **_desc(e))
    return ok, msg


def act_wl_toggle(eid, who="terminal", skip=None):
    def fn(cfg):
        e = find_entry(cfg, eid)
        e["enabled"] = not e["enabled"]
        return dict(e)
    e, ok, msg = update(fn)
    if ok:
        event("wl_on" if e["enabled"] else "wl_off", who, skip, **_desc(e))
    return e, ok, msg


def act_wl_label(eid, label, who="terminal", skip=None):
    def fn(cfg):
        e = find_entry(cfg, eid)
        e["label"] = label.strip()[:40]
        return dict(e)
    e, ok, msg = update(fn)
    if ok:
        event("wl_label", who, skip, **_desc(e))
    return ok, msg


def act_fw_on(who="terminal", skip=None):
    with Locked():
        cfg = load_cfg()
        ok, msg = fw_on(cfg)
    if ok:
        event("fw_on", who, skip, minutes=cfg["rollback_minutes"])
    return ok, msg


def act_fw_off(who="terminal", skip=None):
    def fn(cfg):
        cfg["enabled"] = False
    _, ok, msg = update(fn)
    if ok:
        clear_pending()
        event("fw_off", who, skip)
    return ok, msg


def act_confirm(who="terminal", skip=None):
    if pending_info() is None:
        return False, "Nothing to confirm."
    clear_pending()
    event("fw_confirm", who, skip)
    return True, "Confirmed. Auto-rollback cancelled; the firewall stays ON."


def act_ssh(open_, who="terminal", skip=None):
    ip = ssh_client_ip()

    def fn(cfg):
        if not open_ and ip and not covered(cfg, ip):
            add_whitelist(cfg, ip, "ssh-session-auto")
        cfg["ssh_open"] = open_
    _, ok, msg = update(fn)
    if ok:
        event("ssh", who, skip, on=open_)
    return ok, msg


def act_set(key, value, kind, who="terminal", skip=None, **kw):
    _, ok, msg = update(lambda cfg: cfg.__setitem__(key, value))
    if ok:
        event(kind, who, skip, **kw)
    return ok, msg


def act_ports(ports, who="terminal", skip=None):
    _, ok, msg = update(lambda cfg: cfg.__setitem__("ports", ports))
    if ok:
        event("ports", who, skip, ports=", ".join("%d/%s" % (p["port"], p["proto"]) for p in ports))
    return ok, msg


def act_cf_update(who="terminal", skip=None):
    res, ok, msg = update(fetch_cloudflare)
    if ok and res[0]:
        cf = load_cfg()["cloudflare"]
        event("cf_update", who, skip, v4=len(cf["v4"]), v6=len(cf["v6"]))
        return True, res[1]
    return False, res[1] if not res[0] else msg


def act_cf_allow(on, who="terminal", skip=None):
    _, ok, msg = update(lambda cfg: cfg["cloudflare"].__setitem__("enabled", on))
    if ok:
        event("cf_allow", who, skip, on=on)
    return ok, msg


def act_arvan_update(who="terminal", skip=None):
    res, ok, msg = update(fetch_arvan)
    if ok and res[0]:
        av = load_cfg().get("arvan") or {}
        event("arvan_update", who, skip, v4=len(av.get("v4", [])), v6=len(av.get("v6", [])))
        return True, res[1]
    return False, res[1] if not res[0] else msg


def act_arvan_allow(on, who="terminal", skip=None):
    def fn(cfg):
        cfg.setdefault("arvan", {"enabled": True, "v4": [], "v6": [], "updated": ""})
        cfg["arvan"]["enabled"] = on
    _, ok, msg = update(fn)
    if ok:
        event("arvan_allow", who, skip, on=on)
    return ok, msg


def act_fastly_update(who="terminal", skip=None):
    res, ok, msg = update(fetch_fastly)
    if ok and res[0]:
        fs = load_cfg().get("fastly") or {}
        event("fastly_update", who, skip, v4=len(fs.get("v4", [])), v6=len(fs.get("v6", [])))
        return True, res[1]
    return False, res[1] if not res[0] else msg


def act_fastly_allow(on, who="terminal", skip=None):
    def fn(cfg):
        cfg.setdefault("fastly", {"enabled": True, "v4": [], "v6": [], "updated": ""})
        cfg["fastly"]["enabled"] = on
    _, ok, msg = update(fn)
    if ok:
        event("fastly_allow", who, skip, on=on)
    return ok, msg


def act_cdn_track(on, who="terminal", skip=None):
    _, ok, msg = update(lambda cfg: cfg.__setitem__("cdn_track", on))
    if ok:
        event("cdn_track", who, skip, on=on)
    return ok, msg


def act_reset_stats(who="terminal", skip=None):
    with Locked():
        reset_stats()
    event("stats_reset", who, skip)


def status_text(cfg):
    st = get_stats()
    av = cfg.get("arvan") or {}
    lines = ["Firewall      : %s" % ("ON" if cfg["enabled"] else "OFF"),
             "nft table     : %s" % ("loaded" if table_exists() else "not loaded"),
             "Block mode    : %s" % ("ALL (every IP except whitelist/Cloudflare/Arvan)" if cfg["mode"] == "all"
                                     else "listed ports: " + (", ".join("%d/%s" % (p["port"], p["proto"])
                                                                        for p in cfg["ports"]) or "none")),
             "Ping          : %s" % ("everyone" if cfg["allow_ping"] else "whitelist only"),
             "SSH (port %d) : %s" % (cfg["ssh_port"], "open to everyone" if cfg["ssh_open"]
                                     else "whitelist only"),
             "Whitelist     : %d enabled / %d total" % (
                 sum(e["enabled"] for e in cfg["whitelist"]), len(cfg["whitelist"])),
             "Cloudflare    : %s, %d v4 + %d v6, updated %s" % (
                 "allowed" if cfg["cloudflare"]["enabled"] else "not allowed",
                 len(cfg["cloudflare"]["v4"]), len(cfg["cloudflare"]["v6"]),
                 cfg["cloudflare"]["updated"] or "never"),
             "Arvan Cloud   : %s, %d v4 + %d v6, updated %s" % (
                 "allowed" if av.get("enabled") else "not allowed",
                 len(av.get("v4", [])), len(av.get("v6", [])),
                 av.get("updated") or "never"),
             "Fastly        : %s, %d v4 + %d v6, updated %s" % (
                 "allowed" if (cfg.get("fastly") or {}).get("enabled") else "not allowed",
                 len((cfg.get("fastly") or {}).get("v4", [])),
                 len((cfg.get("fastly") or {}).get("v6", [])),
                 (cfg.get("fastly") or {}).get("updated") or "never"),
             "CDN tracking  : %s" % ("ON" if cfg.get("cdn_track", True) else "OFF"),
             "Blocked       : %s packets since %s" % (
                 "{:,}".format(st["packets"]), time.strftime("%Y-%m-%d %H:%M", time.localtime(st["since"]))),
             "Auto-rollback : %d min" % cfg["rollback_minutes"]]
    left = minutes_left()
    if left is not None:
        lines.append("PENDING       : confirm within %d min or the firewall turns OFF" % left)
    return "\n".join(lines)


# ============================================================================ telegram bot
# The bot UI is Persian on purpose (user's choice); the terminal UI is English.

class TG:
    def __init__(self, token):
        self.base = "https://api.telegram.org/bot%s/" % token

    def call(self, method, _timeout=40, **params):
        req = urllib.request.Request(self.base + method, json.dumps(params).encode(),
                                     {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=_timeout) as r:
            return json.loads(r.read().decode())


SEP = "┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄"
PER_PAGE = 8
E = html.escape


def kb(rows):
    return {"inline_keyboard": [[{"text": t, "callback_data": d} for t, d in row] for row in rows]}


def fa_uptime(sec):
    d, rem = divmod(int(sec), 86400)
    h, rem = divmod(rem, 3600)
    return "%d روز، %d ساعت، %d دقیقه" % (d, h, rem // 60)


def fa_time(ts):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))


def bot_home(cfg):
    si, (v4, v6), st, left = sysinfo(), server_ips(), get_stats(), minutes_left()
    on = cfg["enabled"]
    mem_pct = 100 * si["mem_used"] // max(1, si["mem_total"])
    av = cfg.get("arvan") or {}
    lines = ["🛡 <b>IP Guard v%s</b>  ·  <code>%s</code>" % (VERSION, E(si["host"])), SEP,
             "🌐 IPv4: <code>%s</code>" % (v4 or "—"),
             "🌐 IPv6: <code>%s</code>" % (v6 or "—"),
             "⏱ آپتایم: %s" % fa_uptime(si["up"]),
             "⚙️ CPU: %d%%  ·  Load: %.2f  ·  %d هسته" % (si["cpu"], si["load"][0], si["ncpu"]),
             "🧠 RAM: %s / %s  (%d%%)" % (fmt_bytes(si["mem_used"]), fmt_bytes(si["mem_total"]), mem_pct),
             "💾 دیسک: %s / %s" % (fmt_bytes(si["disk_used"]), fmt_bytes(si["disk_total"])),
             SEP,
             "🔥 فایروال: %s" % ("🟢 <b>روشن</b>" if on else "🔴 <b>خاموش</b> (همه مجازند)"),
             "🧱 حالت: %s" % ("همه‌ی IPها به جز لیست سفید" if cfg["mode"] == "all" else "فقط پورت‌های انتخابی")]
    if left is not None:
        lines.append("⏳ <b>منتظر تایید: %d دقیقه مانده</b>" % left)
    lines += ["🔑 SSH (پورت %d): %s" % (cfg["ssh_port"], "🟡 باز برای همه" if cfg["ssh_open"] else "🔒 فقط لیست سفید"),
              "📶 پینگ: %s" % ("همه" if cfg["allow_ping"] else "فقط لیست سفید"),
              "📋 لیست سفید: %d فعال از %d" % (sum(e["enabled"] for e in cfg["whitelist"]), len(cfg["whitelist"])),
              "☁️ کلادفلر: %s  ·  %d رنج  ·  %s" % (
                  "مجاز" if cfg["cloudflare"]["enabled"] else "غیرمجاز",
                  len(cfg["cloudflare"]["v4"]) + len(cfg["cloudflare"]["v6"]), cfg["cloudflare"]["updated"] or "—"),
              "🟣 آروان‌کلاد: %s  ·  %d رنج  ·  %s" % (
                  "مجاز" if av.get("enabled") else "غیرمجاز",
                  len(av.get("v4", [])) + len(av.get("v6", [])), av.get("updated") or "—"),
              "⚡ Fastly: %s  ·  %d رنج  ·  %s" % (
                  "مجاز" if (cfg.get("fastly") or {}).get("enabled") else "غیرمجاز",
                  len((cfg.get("fastly") or {}).get("v4", [])) + len((cfg.get("fastly") or {}).get("v6", [])),
                  (cfg.get("fastly") or {}).get("updated") or "—"),
              "📡 ردیابی CDN: %s" % ("فعال" if cfg.get("cdn_track", True) else "خاموش"),
              "🚫 بلاک‌شده: <b>%s</b> بسته (%s)" % ("{:,}".format(st["packets"]), fmt_bytes(st["bytes"])),
              SEP, "📦 نسخه: <code>v%s</code>  ·  🕒 %s" % (VERSION, time.strftime("%Y-%m-%d %H:%M:%S"))]
    rows = [[("🔄 بروزرسانی", "h"), ("📊 آمار بلاک", "s")],
            [("📋 لیست سفید", "w:0"), ("➕ افزودن IP", "a")],
            [("🔴 خاموش کردن فایروال" if on else "🟢 روشن کردن فایروال", "f")]]
    if left is not None:
        rows.insert(2, [("✅ تایید فایروال (%d دقیقه مانده)" % left, "fc")])
    rows += [[("🔑 " + ("بستن SSH" if cfg["ssh_open"] else "باز کردن SSH"), "k"),
              ("🧱 تغییر حالت بلاک", "m")],
             [("☁️ کلادفلر", "cfm"), ("🟣 آروان", "avm"), ("⚡ Fastly", "fsm")],
             [("📡 گزارش CDN", "cdn"), ("📜 رویدادها", "v")],
             [("🌐 IP سرور", "ip"), ("❓ راهنما", "g")]]
    return "\n".join(lines), rows


def bot_ip():
    _IPS["t"] = 0  # force a fresh lookup
    v4, v6 = server_ips()
    text = ("🌐 <b>IP سرور</b>\n%s\nنام سرور: <code>%s</code>\nIPv4: <code>%s</code>\nIPv6: <code>%s</code>"
            % (SEP, E(socket.gethostname()), v4 or "پیدا نشد", v6 or "پیدا نشد"))
    return text, [[("🏠 منوی اصلی", "h")]]


def bot_wl(cfg, page=0):
    wl = cfg["whitelist"]
    pages = max(1, (len(wl) + PER_PAGE - 1) // PER_PAGE)
    page = min(max(0, page), pages - 1)
    text = ("📋 <b>لیست سفید</b>\n%s\n%d مورد  ·  %d فعال  ·  صفحه %d از %d\n\n"
            "روی هر مورد بزنید تا جزئیات و گزینه‌ها را ببینید.\n"
            "برای افزودن، IP را مستقیم در چت بفرستید."
            % (SEP, len(wl), sum(e["enabled"] for e in wl), page + 1, pages))
    rows = [[("%s %s  ·  %s" % ("🟢" if e["enabled"] else "⚪", e["cidr"], e.get("label") or "—"),
              "e:%d:%d" % (e["id"], page))] for e in wl[page * PER_PAGE:(page + 1) * PER_PAGE]]
    nav = []
    if page > 0:
        nav.append(("◀️ قبلی", "w:%d" % (page - 1)))
    if page < pages - 1:
        nav.append(("بعدی ▶️", "w:%d" % (page + 1)))
    if nav:
        rows.append(nav)
    rows.append([("➕ افزودن", "a"), ("🏠 منوی اصلی", "h")])
    return text, rows


def bot_entry(cfg, eid, page):
    e = find_entry(cfg, eid)
    text = ("🔹 <b>جزئیات مورد</b>\n%s\nشناسه: <code>%d</code>\nآدرس: <code>%s</code>\nبرچسب: %s\n"
            "وضعیت: %s\nتاریخ افزودن: %s"
            % (SEP, e["id"], e["cidr"], E(e.get("label") or "—"),
               "🟢 فعال" if e["enabled"] else "⚪ غیرفعال", e.get("added", "—")))
    rows = [[("⚪ غیرفعال کن" if e["enabled"] else "🟢 فعال کن", "et:%d:%d" % (e["id"], page)),
             ("✏️ تغییر برچسب", "el:%d:%d" % (e["id"], page))],
            [("🗑 حذف", "ed:%d:%d" % (e["id"], page))],
            [("🔙 لیست", "w:%d" % page), ("🏠 منوی اصلی", "h")]]
    return text, rows


def bot_stats(cfg):
    st = get_stats()
    lines = ["📊 <b>آمار بلاک</b>", SEP, "از: %s" % fa_time(st["since"]), "",
             "🚫 کل بسته‌های بلاک‌شده: <b>%s</b> (%s)" % ("{:,}".format(st["packets"]), fmt_bytes(st["bytes"])),
             "🔑 بسته‌های بلاک‌شده‌ی SSH: <b>%s</b>" % "{:,}".format(st["ssh"])]
    if not cfg["enabled"]:
        lines.append("\nℹ️ فایروال خاموش است؛ الان چیزی بلاک نمی‌شود.")
    if st["top"]:
        lines += ["", "<b>بیشترین IPهای بلاک‌شده:</b>"]
        for i, (ip, n) in enumerate(st["top"], 1):
            lines.append("%d. <code>%s</code> — %s بسته" % (i, ip, "{:,}".format(n)))
        lines.append("\nاگر یکی از این‌ها سرور خودتان است، با دکمه‌ی زیر مجازش کنید.")
    rows = [[("➕ مجاز کردن %s" % ip, "aw:%s" % ip)] for ip, _ in st["top"][:5]]
    rows += [[("🔄 بروزرسانی", "s"), ("🗑 صفر کردن آمار", "sr")], [("🏠 منوی اصلی", "h")]]
    return "\n".join(lines), rows


def bot_events():
    evs = recent_events(15)
    lines = ["📜 <b>آخرین رویدادها</b>", SEP]
    for r in evs:
        lines.append("🕒 %s  ·  %s\n%s\n" % (fa_time(r.get("t", 0)), E(fmt_who(r.get("who", ""))), fmt_event(r)))
    if not evs:
        lines.append("هنوز رویدادی ثبت نشده.")
    return "\n".join(lines)[:4000], [[("🔄 بروزرسانی", "v"), ("🏠 منوی اصلی", "h")]]




def bot_cdn_provider(cfg, key):
    """Detail view for one CDN provider: status, update, allow/deny."""
    meta = {
        "cloudflare": ("☁️ Cloudflare", "cfu", "cfa"),
        "arvan": ("🟣 آروان‌کلاد", "avu", "ava"),
        "fastly": ("⚡ Fastly", "fsu", "fsa"),
    }
    title, upd, tog = meta[key]
    p = cfg.get(key) or {}
    en = bool(p.get("enabled"))
    text = (
        "%s\n%s\nوضعیت: %s\nرنج‌ها: %d IPv4 + %d IPv6\nآخرین آپدیت: %s\n\n"
        "با «آپدیت رنج» لیست رسمی از اینترنت گرفته می‌شود.\n"
        "اگر غیرمجاز شود، ترافیک این CDN هنگام روشن بودن فایروال بلاک می‌شود."
        % (title, SEP,
           "🟢 مجاز" if en else "🔴 غیرمجاز",
           len(p.get("v4", [])), len(p.get("v6", [])),
           p.get("updated") or "—")
    )
    rows = [
        [("🔄 آپدیت رنج‌ها", upd)],
        [("🔴 غیرمجاز کن" if en else "🟢 مجاز کن", tog)],
        [("📡 گزارش دسترسی", "cdn"), ("🏠 منوی اصلی", "h")],
    ]
    return text, rows


def bot_cdn_report(cfg):
    st = get_stats()
    track = cfg.get("cdn_track", True)
    lines = ["📡 <b>گزارش دسترسی CDN</b>", SEP,
             "ردیابی: %s" % ("🟢 فعال" if track else "🔴 خاموش"),
             "از: %s" % fa_time(st["since"]), ""]
    labels = {"cloudflare": "☁️ Cloudflare", "arvan": "🟣 آروان‌کلاد", "fastly": "⚡ Fastly"}
    any_hits = False
    for key, title in labels.items():
        rows_data = st.get("cdn", {}).get(key) or []
        en = (cfg.get(key) or {}).get("enabled")
        lines.append("%s  (%s)" % (title, "مجاز" if en else "غیرمجاز"))
        if rows_data:
            any_hits = True
            for i, (ip, n) in enumerate(rows_data[:10], 1):
                lines.append("  %d. <code>%s</code> — %s بسته" % (i, ip, "{:,}".format(n)))
        else:
            lines.append("  — هنوز دسترسی ثبت نشده")
        lines.append("")
    if not track:
        lines.append("ℹ️ ردیابی خاموش است؛ برای دیدن IPهای CDN آن را روشن کنید.")
    elif not any_hits and cfg["enabled"]:
        lines.append("ℹ️ هنوز ترافیک CDN ثبت نشده. بعد از اتصال کلاینت‌ها دوباره چک کنید.")
    elif not cfg["enabled"]:
        lines.append("ℹ️ فایروال خاموش است؛ ردیابی فقط وقتی فایروال روشن است کار می‌کند.")
    rows = [[("🔄 بروزرسانی", "cdn")],
            [("🟢 روشن کردن ردیابی" if not track else "🔴 خاموش کردن ردیابی", "cdt")],
            [("🗑 صفر کردن آمار CDN", "cdr")],
            [("🏠 منوی اصلی", "h")]]
    return "\n".join(lines)[:4000], rows

BOT_HELP = """❓ <b>راهنما</b>
┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
<b>فایروال روشن:</b> فقط IPهای لیست سفید و CDNهای مجاز (کلادفلر، آروان‌کلاد، Fastly) می‌توانند به سرور وصل شوند. بقیه بلاک می‌شوند.
<b>فایروال خاموش:</b> هیچ چیزی بلاک نمی‌شود.

<b>تایید:</b> بعد از روشن کردن فایروال، تا زمان مشخص‌شده باید «تایید» را بزنید؛ وگرنه فایروال خودش خاموش می‌شود تا اگر اشتباهی شده، دسترسی قطع نماند.

<b>افزودن IP:</b> IP یا رنج را مستقیم در چت بفرستید. می‌توانید چند خط بفرستید؛ برچسب را بعد از فاصله بنویسید:
<code>1.2.3.4 relay-5
5.6.7.0/24 office</code>
ربات قبل از افزودن، پیش‌نمایش و دکمه‌ی تایید نشان می‌دهد.

<b>SSH:</b> «بستن» یعنی فقط لیست سفید می‌تواند SSH بزند. قبل از بستن مطمئن شوید IP خودتان در لیست است.

<b>کلادفلر / آروان / Fastly:</b> کانفیگ‌های CDN از IPهای این سرویس‌ها به سرور می‌رسند؛ گاهی رنج‌ها را آپدیت کنید.
<b>گزارش CDN:</b> وقتی ردیابی فعال باشد، IPهایی از رنج CDN که به سرور وصل شده‌اند ثبت و گزارش می‌شوند.

<b>دستورها:</b>
/start داشبورد
/ip آی‌پی سرور
/wl لیست سفید
/stats آمار بلاک
/cdn گزارش دسترسی CDN
/add افزودن IP
/help راهنما

همه‌ی تغییرات (از ترمینال یا ربات) به همه‌ی ادمین‌ها گزارش می‌شود."""


def parse_ip_lines(text):
    """Each line: IP/CIDR [label]. Returns (valid pairs, invalid tokens)."""
    ok, bad = [], []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("/"):
            continue
        parts = line.split(None, 1)
        try:
            ok.append((norm_net(parts[0]), parts[1].strip()[:40] if len(parts) > 1 else ""))
        except ValueError:
            bad.append(parts[0])
    return ok, bad


def add_preview(cfg, pairs, bad):
    have = {e["cidr"] for e in cfg["whitelist"]}
    new, dup, seen = [], [], set()
    for cidr, label in pairs:
        if cidr in have or cidr in seen:
            dup.append(cidr)
        else:
            seen.add(cidr)
            new.append((cidr, label))
    lines = ["➕ <b>افزودن به لیست سفید</b>", SEP]
    lines += ["• <code>%s</code> %s" % (c_, E(l_)) for c_, l_ in new]
    if dup:
        lines.append("\n⚠️ از قبل در لیست است: " + "، ".join("<code>%s</code>" % d for d in dup))
    if bad:
        lines.append("\n❌ نامعتبر: " + "، ".join("<code>%s</code>" % E(b) for b in bad[:10]))
    if new:
        lines.append("\nاضافه شوند؟")
        rows = [[("✅ افزودن %d مورد" % len(new), "ac"), ("❌ لغو", "h")]]
    else:
        lines.append("\nچیزی برای افزودن نیست.")
        rows = [[("🏠 منوی اصلی", "h")]]
    return "\n".join(lines), rows, new


ADD_HELP = ("➕ <b>افزودن IP</b>\n%s\nIP یا رنج را همین‌جا بفرستید. برای چند مورد، هر کدام در یک خط؛ "
            "برچسب اختیاری را بعد از فاصله بنویسید:\n<code>1.2.3.4 relay-5\n5.6.7.0/24 office</code>" % SEP)


def bot_handle(api, state, upd):
    """Handle one Telegram update. state: chat_id -> pending input."""
    msg = upd.get("message")
    cb = upd.get("callback_query")
    src = (cb or msg or {}).get("from", {})
    chat = ((cb or {}).get("message") or msg or {}).get("chat", {}).get("id")
    cfg = load_cfg()
    if chat is None or src.get("id") not in cfg["bot"]["admins"]:
        return
    uid = src["id"]
    who = "%s (%d)" % ("@" + src["username"] if src.get("username") else src.get("first_name", "?"), uid)
    mid = cb["message"]["message_id"] if cb else None
    toast = [""]

    def show(view):
        text, rows = view[0], view[1]
        p = {"chat_id": chat, "text": text, "parse_mode": "HTML", "reply_markup": kb(rows),
             "disable_web_page_preview": True}
        if mid:
            try:
                api.call("editMessageText", message_id=mid, **p)
                return
            except urllib.error.HTTPError as exc:
                if "not modified" in exc.read().decode("utf-8", "replace"):
                    return
        api.call("sendMessage", **p)

    def result(ok, good, err_msg):
        toast[0] = good if ok else "❌ " + err_msg

    def confirm(question, yes_data, back="h"):
        show(("❓ " + question, [[("✅ بله", yes_data), ("❌ لغو", back)]]))

    try:
        if cb:
            d = cb["data"]
            arg = d.split(":")[1:]
            state.pop(chat, None)
            if d == "h":
                show(bot_home(cfg))
            elif d == "ip":
                show(bot_ip())
            elif d == "g":
                show((BOT_HELP, [[("🏠 منوی اصلی", "h")]]))
            elif d == "v":
                show(bot_events())
            elif d == "s":
                show(bot_stats(cfg))
            elif d == "sr":
                confirm("آمار بلاک صفر شود؟", "src", "s")
            elif d == "src":
                act_reset_stats(who, uid)
                toast[0] = "✅ آمار صفر شد"
                show(bot_stats(load_cfg()))
            elif d.startswith("w:"):
                show(bot_wl(cfg, int(arg[0])))
            elif d.startswith("e:"):
                show(bot_entry(cfg, arg[0], int(arg[1])))
            elif d.startswith("et:"):
                e, ok, m = act_wl_toggle(arg[0], who, uid)
                result(ok, "🟢 فعال شد" if ok and e["enabled"] else "⚪ غیرفعال شد", m)
                show(bot_entry(load_cfg(), arg[0], int(arg[1])))
            elif d.startswith("el:"):
                state[chat] = {"mode": "label", "eid": int(arg[0]), "page": int(arg[1])}
                e = find_entry(cfg, arg[0])
                show(("✏️ برچسب جدید برای <code>%s</code> را بفرستید (حداکثر ۴۰ حرف)." % e["cidr"],
                      [[("❌ لغو", "e:%s:%s" % (arg[0], arg[1]))]]))
            elif d.startswith("ed:"):
                e = find_entry(cfg, arg[0])
                confirm("<code>%s</code> %s از لیست سفید حذف شود؟\nاگر فایروال روشن باشد، فوراً دسترسی‌اش قطع می‌شود."
                        % (e["cidr"], E(e.get("label", ""))), "edc:%s:%s" % (arg[0], arg[1]),
                        "e:%s:%s" % (arg[0], arg[1]))
            elif d.startswith("edc:"):
                ok, m = act_wl_remove(arg[0], who, uid)
                result(ok, "🗑 حذف شد", m)
                show(bot_wl(load_cfg(), int(arg[1])))
            elif d == "a":
                state[chat] = {"mode": "add"}
                show((ADD_HELP, [[("❌ لغو", "h")]]))
            elif d.startswith("aw:"):
                text, rows, new = add_preview(cfg, [(norm_net(d[3:]), "from-stats")], [])
                PREVIEWS[chat] = new
                show((text, rows))
            elif d == "ac":
                items = PREVIEWS.pop(chat, [])
                toast[0] = "این پیش‌نمایش منقضی شده؛ دوباره بفرستید."
                if items:
                    added, errors, ok, m = act_wl_add(items, who, uid)
                    result(ok, "✅ %d مورد اضافه شد" % len(added), m)
                    cfg2 = load_cfg()
                    show(bot_wl(cfg2, (len(cfg2["whitelist"]) - 1) // PER_PAGE))
                else:
                    show(bot_home(cfg))
            elif d == "f":
                if cfg["enabled"]:
                    confirm("فایروال <b>خاموش</b> شود؟ همه‌ی IPها مجاز می‌شوند.", "foff")
                else:
                    confirm("فایروال <b>روشن</b> شود؟\nبعد از روشن شدن تا %d دقیقه باید «تایید» را بزنید، "
                            "وگرنه خودش خاموش می‌شود." % cfg["rollback_minutes"], "fon")
            elif d == "fon":
                ok, m = act_fw_on(who, uid)
                result(ok, "🟢 فایروال روشن شد؛ تست کنید و تایید بزنید", m)
                show(bot_home(load_cfg()))
            elif d == "foff":
                ok, m = act_fw_off(who, uid)
                result(ok, "🔴 فایروال خاموش شد", m)
                show(bot_home(load_cfg()))
            elif d == "fc":
                ok, m = act_confirm(who, uid)
                result(ok, "✅ تایید شد", m)
                show(bot_home(load_cfg()))
            elif d == "k":
                if cfg["ssh_open"]:
                    confirm("SSH برای همه <b>بسته</b> شود و فقط لیست سفید بتواند وصل شود؟\n"
                            "اگر IP خودتان در لیست نباشد، دسترسی SSH شما قطع می‌شود.", "kc")
                else:
                    confirm("SSH برای <b>همه</b> باز شود؟", "ko")
            elif d in ("kc", "ko"):
                ok, m = act_ssh(d == "ko", who, uid)
                result(ok, "🔑 SSH باز شد" if d == "ko" else "🔒 SSH بسته شد", m)
                show(bot_home(load_cfg()))
            elif d == "m":
                if cfg["mode"] == "all":
                    confirm("حالت به «فقط پورت‌های انتخابی» تغییر کند؟\nدر این حالت فقط پورت‌هایی که در منوی ترمینال "
                            "تعریف شده‌اند محدود می‌شوند.", "mp")
                else:
                    confirm("حالت به «همه‌ی IPها به جز لیست سفید» تغییر کند؟", "ma")
            elif d in ("ma", "mp"):
                mode = "all" if d == "ma" else "ports"
                ok, m = act_set("mode", mode, "mode", who, uid, mode=mode)
                result(ok, "🧱 حالت تغییر کرد", m)
                show(bot_home(load_cfg()))
            elif d == "c":
                ok, m = act_cf_update(who, uid)
                result(ok, "☁️ کلادفلر بروز شد", m)
                show(bot_home(load_cfg()))
            elif d == "av":
                ok, m = act_arvan_update(who, uid)
                result(ok, "🟣 آروان‌کلاد بروز شد", m)
                show(bot_home(load_cfg()))
            elif d == "fs":
                ok, m = act_fastly_update(who, uid)
                result(ok, "⚡ Fastly بروز شد", m)
                show(bot_home(load_cfg()))
            elif d == "cfm":
                show(bot_cdn_provider(cfg, "cloudflare"))
            elif d == "avm":
                show(bot_cdn_provider(cfg, "arvan"))
            elif d == "fsm":
                show(bot_cdn_provider(cfg, "fastly"))
            elif d == "cfu":
                ok, m = act_cf_update(who, uid)
                result(ok, "☁️ کلادفلر بروز شد", m)
                show(bot_cdn_provider(load_cfg(), "cloudflare"))
            elif d == "avu":
                ok, m = act_arvan_update(who, uid)
                result(ok, "🟣 آروان‌کلاد بروز شد", m)
                show(bot_cdn_provider(load_cfg(), "arvan"))
            elif d == "fsu":
                ok, m = act_fastly_update(who, uid)
                result(ok, "⚡ Fastly بروز شد", m)
                show(bot_cdn_provider(load_cfg(), "fastly"))
            elif d == "cfa":
                on = not cfg["cloudflare"]["enabled"]
                ok, m = act_cf_allow(on, who, uid)
                result(ok, "☁️ کلادفلر " + ("مجاز شد" if on else "غیرمجاز شد"), m)
                show(bot_cdn_provider(load_cfg(), "cloudflare"))
            elif d == "ava":
                on = not (cfg.get("arvan") or {}).get("enabled", True)
                ok, m = act_arvan_allow(on, who, uid)
                result(ok, "🟣 آروان " + ("مجاز شد" if on else "غیرمجاز شد"), m)
                show(bot_cdn_provider(load_cfg(), "arvan"))
            elif d == "fsa":
                on = not (cfg.get("fastly") or {}).get("enabled", True)
                ok, m = act_fastly_allow(on, who, uid)
                result(ok, "⚡ Fastly " + ("مجاز شد" if on else "غیرمجاز شد"), m)
                show(bot_cdn_provider(load_cfg(), "fastly"))
            elif d == "cdn":
                show(bot_cdn_report(cfg))
            elif d == "cdt":
                on = not cfg.get("cdn_track", True)
                ok, m = act_cdn_track(on, who, uid)
                result(ok, "📡 ردیابی CDN " + ("فعال شد" if on else "خاموش شد"), m)
                show(bot_cdn_report(load_cfg()))
            elif d == "cdr":
                with Locked():
                    d = load_stats()
                    d["cdn"] = {"cloudflare": {}, "arvan": {}, "fastly": {}}
                    write_json(STATS, d, 0o644)
                    if table_exists():
                        for name in ("cf_hit4", "cf_hit6", "av_hit4", "av_hit6", "fs_hit4", "fs_hit6"):
                            run(["nft", "flush", "set", "inet", TABLE, name])
                toast[0] = "✅ آمار CDN صفر شد"
                show(bot_cdn_report(load_cfg()))
            else:
                show(bot_home(cfg))
            return

        text = (msg or {}).get("text", "").strip()
        st = state.pop(chat, None) or {}
        if text.startswith("/"):
            cmd, _, rest = text.partition(" ")
            cmd = cmd.split("@")[0].lower()
            if cmd == "/ip":
                show(bot_ip())
            elif cmd == "/wl":
                show(bot_wl(cfg))
            elif cmd == "/stats":
                show(bot_stats(cfg))
            elif cmd == "/cdn":
                show(bot_cdn_report(cfg))
            elif cmd == "/help":
                show((BOT_HELP, [[("🏠 منوی اصلی", "h")]]))
            elif cmd == "/add" and not rest.strip():
                state[chat] = {"mode": "add"}
                show((ADD_HELP, [[("❌ لغو", "h")]]))
            elif cmd == "/add":
                text_, rows, new = add_preview(cfg, *parse_ip_lines(rest.replace(",", "\n")))
                PREVIEWS[chat] = new
                show((text_, rows))
            else:
                show(bot_home(cfg))
            return
        if st.get("mode") == "label" and text:
            ok, m = act_wl_label(st["eid"], text, who, uid)
            api.call("sendMessage", chat_id=chat, text="✏️ برچسب ذخیره شد." if ok else "❌ " + m)
            show(bot_entry(load_cfg(), st["eid"], st["page"]))
            return
        pairs, bad = parse_ip_lines(text)
        if pairs or st.get("mode") == "add":
            text_, rows, new = add_preview(cfg, pairs, bad)
            PREVIEWS[chat] = new
            show((text_, rows))
        else:
            show(bot_home(cfg))
    except ValueError as exc:
        toast[0] = "❌ %s" % exc
        if not cb:
            api.call("sendMessage", chat_id=chat, text="❌ %s" % exc)
    finally:
        if cb:
            try:
                api.call("answerCallbackQuery", callback_query_id=cb["id"], text=toast[0][:190])
            except (urllib.error.URLError, OSError, ValueError):
                pass


PREVIEWS = {}  # chat_id -> pairs waiting for the "add" button

BOT_COMMANDS = [("start", "داشبورد"), ("ip", "آی‌پی سرور"), ("wl", "لیست سفید"),
                ("stats", "آمار بلاک"), ("cdn", "گزارش CDN"), ("add", "افزودن IP"), ("help", "راهنما")]


def run_bot():
    cfg = load_cfg()
    if not cfg["bot"]["token"] or not cfg["bot"]["admins"]:
        sys.exit("Bot is not configured. Use the menu: Telegram bot -> token / admins.")
    api = TG(cfg["bot"]["token"])
    try:
        api.call("setMyCommands", commands=[{"command": c_, "description": d_} for c_, d_ in BOT_COMMANDS])
    except (urllib.error.URLError, OSError, ValueError) as exc:
        print("setMyCommands failed: %r" % exc, flush=True)
    offset, state = 0, {}
    print("Bot started. Admins: %s" % cfg["bot"]["admins"], flush=True)
    while True:
        try:
            data = api.call("getUpdates", _timeout=45, offset=offset, timeout=30,
                            allowed_updates=["message", "callback_query"])
            for upd in data.get("result", []):
                offset = upd["update_id"] + 1
                try:
                    bot_handle(api, state, upd)
                except Exception as exc:  # keep the bot alive on a bad update
                    print("handler error: %r" % exc, flush=True)
        except (urllib.error.URLError, OSError, ValueError) as exc:
            print("poll error: %r" % exc, flush=True)
            time.sleep(5)


# ============================================================================ install

SERVICE_BOOT = """[Unit]
Description=IP Guard firewall (apply saved config at boot)
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 {path} apply

[Install]
WantedBy=multi-user.target
"""

SERVICE_BOT = """[Unit]
Description=IP Guard Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 {path} bot
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"""


def install_system(who="terminal"):
    os.makedirs(os.path.dirname(INSTALL_PATH), exist_ok=True)
    me = os.path.abspath(__file__)
    if me != INSTALL_PATH:
        shutil.copy2(me, INSTALL_PATH)
    os.chmod(INSTALL_PATH, 0o700)
    for name, tpl in ((BOOT_UNIT, SERVICE_BOOT), (BOT_UNIT, SERVICE_BOT)):
        with open(os.path.join(UNIT_DIR, name), "w") as fh:
            fh.write(tpl.format(path=INSTALL_PATH))
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "enable", BOOT_UNIT])
    extra = ""
    with Locked():
        cfg = load_cfg()
        ip = ssh_client_ip()
        if ip and not covered(cfg, ip):
            add_whitelist(cfg, ip, "ssh-session-auto")
            extra = " Your SSH IP %s was added to the whitelist." % ip
        save_cfg(cfg)
    if svc_state(BOT_UNIT) == "active":
        run(["systemctl", "restart", BOT_UNIT])  # load the new code
        extra += " Bot restarted."
    event("install", who)
    return "Installed to %s, boot service enabled.%s" % (INSTALL_PATH, extra)


# ============================================================================ terminal UI

TTY = sys.stdout.isatty()
USE_COLOR = TTY and not os.environ.get("NO_COLOR")
UTF = (getattr(sys.stdout, "encoding", "") or "").lower().startswith("utf")
BX = "╭╮╰╯─│├┤" if UTF else "++++-|++"
DOT, ARROW, OK, BAD, WARN = ("●", "›", "✔", "✖", "▲") if UTF else ("*", ">", "+", "x", "!")
ANSI = re.compile(r"\033\[[0-9;]*m")
NOTES = []


def c(text, code):
    return "\033[%sm%s\033[0m" % (code, text) if USE_COLOR else str(text)


def vlen(s):
    return len(ANSI.sub("", s))


def pad(s, n):
    if vlen(s) > n and not ANSI.search(s):
        s = s[:n - 1] + "…"
    return s + " " * max(0, n - vlen(s))


def width():
    return max(60, min(shutil.get_terminal_size((80, 24)).columns - 2, 78))


def box(lines, title="", right="", color="36"):
    """Draw a framed panel. A None line draws a separator."""
    w = width()
    tl, tr, bl, br, h, v, ml, mr = BX
    t = " %s " % title if title else ""
    rt = " %s " % right if right else ""
    fill = max(0, w - 4 - len(t) - len(rt))
    print(" " + c(tl + h, color) + c(t, "1;37") + c(h * fill, color) + c(rt, "90") + c(h + tr, color))
    for ln in lines:
        if ln is None:
            print(" " + c(ml + h * (w - 2) + mr, color))
        else:
            print(" " + c(v, color) + " " + pad(ln, w - 4) + " " + c(v, color))
    print(" " + c(bl + h * (w - 2) + br, color))


def kv(key, value, kw=12):
    return c(key.ljust(kw), "90") + value


def wrap(text, color="37"):
    out = []
    for para in text.split("\n"):
        out += [c(x, color) for x in (textwrap.wrap(para, width() - 4) or [""])]
    return out


def clear():
    if TTY:
        sys.stdout.write("\033[3J\033[2J\033[H")
        sys.stdout.flush()


def note(msg, kind="ok"):
    NOTES.append((msg, kind))


def report(ok, msg, good=None):
    note((good or msg) if ok else msg, "ok" if ok else "err")


def flush_notes():
    marks = {"ok": (OK, "1;32"), "err": (BAD, "1;31"), "warn": (WARN, "1;33")}
    for msg, kind in NOTES:
        mark, col = marks.get(kind, marks["ok"])
        for i, line in enumerate(textwrap.wrap(msg, width() - 4) or [""]):
            print(" " + c(mark if i == 0 else " ", col) + " " + c(line, col))
    if NOTES:
        print()
    del NOTES[:]


def on_off(flag, yes="ON", no="OFF"):
    return c(DOT + " " + yes, "1;32") if flag else c(DOT + " " + no, "1;31")


def screen(*path):
    """Clear, draw the header panel and the breadcrumb, then pending notes."""
    clear()
    cfg = load_cfg()
    left = minutes_left()
    wl_on = sum(e["enabled"] for e in cfg["whitelist"])
    av = cfg.get("arvan") or {}
    fs = cfg.get("fastly") or {}
    parts = [on_off(cfg["enabled"], "FIREWALL ON", "FIREWALL OFF"),
             c("Mode ", "90") + c("ALL" if cfg["mode"] == "all" else "PORTS", "1;37"),
             c("SSH ", "90") + (c("open", "1;33") if cfg["ssh_open"] else c("locked", "1;32")),
             c("WL ", "90") + c(str(wl_on), "1;37"),
             c("CF ", "90") + c(str(len(cfg["cloudflare"]["v4"]) + len(cfg["cloudflare"]["v6"]))
                                if cfg["cloudflare"]["enabled"] else "off", "1;37"),
             c("AV ", "90") + c(str(len(av.get("v4", [])) + len(av.get("v6", [])))
                                if av.get("enabled") else "off", "1;37"),
             c("FS ", "90") + c(str(len(fs.get("v4", [])) + len(fs.get("v6", [])))
                                if fs.get("enabled") else "off", "1;37")]
    lines = ["  ".join(parts)]
    if left is not None:
        lines.append(c("%s Confirm pending: %d min left, then it switches OFF  (Firewall menu)" % (WARN, left), "1;33"))
    box(lines, "IP GUARD v" + VERSION, socket.gethostname())
    print(" " + c((" %s " % ARROW).join(("Main",) + path), "1;35"))
    print()
    flush_notes()


def menu(rows, title="Options"):
    """rows: (key, label[, value]); None = separator. Returns the user's choice."""
    lines = []
    for row in rows:
        if row is None:
            lines.append(None)
            continue
        key, label = row[0], row[1]
        val = row[2] if len(row) > 2 else ""
        lines.append(c("%2s" % key, "1;31" if key == "0" else "1;33") + "   " + pad(c(label, "1;37"), 22) + val)
    box(lines, title, color="34")
    return ask("\n " + c(ARROW, "1;36") + " " + c("Select: ", "1;37"))


def ask(prompt, default=None):
    try:
        v = input(prompt).strip()
    except EOFError:
        raise KeyboardInterrupt
    return v if v or default is None else default


def field(label, default=None):
    return ask(" " + c(ARROW, "36") + " " + label + (c(" [%s]" % default, "90") if default else "") + ": ", default)


def yes(prompt):
    return ask(" " + c("? ", "1;33") + c(prompt, "1;33") + c(" (y/n): ", "90")).lower() in ("y", "yes")


def pause():
    ask("\n " + c("Press Enter to go back...", "90"))


# ============================================================================ screens

def fw_value(cfg):
    left = minutes_left()
    v = on_off(cfg["enabled"])
    return v + (c("  confirm pending %dm" % left, "1;33") if left is not None else "")


def menu_firewall():
    while True:
        cfg = load_cfg()
        left = minutes_left()
        screen("Firewall")
        state = on_off(cfg["enabled"], "ON - blocking", "OFF - every IP can connect")
        lines = [kv("State", state),
                 kv("Mode", "ALL - every IP except whitelist/Cloudflare/Arvan" if cfg["mode"] == "all"
                    else "LISTED PORTS (%d)" % len(cfg["ports"])),
                 kv("Safety", "%d min auto-rollback after switching ON" % cfg["rollback_minutes"])]
        if left is not None:
            lines.append(kv("Pending", c("%d min left - confirm or it switches OFF" % left, "1;33")))
        box(lines, "Firewall")
        rows = [("1", "Switch OFF" if cfg["enabled"] else "Switch ON")]
        if left is not None:
            rows.append(("2", "Confirm", c("keep it ON", "90")))
        rows.append(("0", "Back"))
        ch = menu(rows)
        if ch == "1" and cfg["enabled"]:
            if yes("Switch the firewall OFF (allow every IP)?"):
                report(*act_fw_off(), good="Firewall OFF. Every IP can connect.")
        elif ch == "1":
            if cfg["mode"] == "ports" and not cfg["ports"] and cfg["ssh_open"]:
                note("Mode is LISTED PORTS with no ports and SSH is open: nothing would be blocked.", "warn")
            if yes("Switch the firewall ON now?"):
                report(*act_fw_on())
        elif ch == "2" and left is not None:
            report(*act_confirm())
        elif ch == "0":
            return


def wl_table(cfg):
    wl = cfg["whitelist"]
    nw = min(39, max([len(e["cidr"]) for e in wl] + [7]))
    lw = max(6, width() - 4 - (5 + 6 + nw + 2))
    lines = [c("%-4s %-5s  %-*s  %s" % ("ID", "ST", nw, "NETWORK", "LABEL"), "1;36"), None]
    for e in wl:
        st = c(DOT + " on ", "1;32") if e["enabled"] else c(DOT + " off", "90")
        lines.append("%-4d %s  %-*s  %s" % (e["id"], st, nw, e["cidr"], c((e.get("label") or "-")[:lw], "90")))
    if not wl:
        lines.append(c("(empty)", "90"))
    return lines


def menu_whitelist():
    while True:
        cfg = load_cfg()
        screen("Whitelist")
        box(wl_table(cfg), "Whitelist", "%d of %d enabled" % (sum(e["enabled"] for e in cfg["whitelist"]),
                                                              len(cfg["whitelist"])))
        ch = menu([("1", "Add"), ("2", "Paste a list"), ("3", "Enable / disable"),
                   ("4", "Rename label"), ("5", "Remove"), ("0", "Back")])
        try:
            if ch == "1":
                cidr = field("IP or CIDR")
                if not cidr:
                    continue
                label = field("Label (optional)")
                added, errors, ok, msg = act_wl_add([(cidr, label)])
                for err in errors:
                    note(err, "err")
                if added:
                    note("Added %s." % added[0]["cidr"])
                elif not ok:
                    note(msg, "err")
            elif ch == "2":
                print(" " + c("One IP/CIDR per line, optional label after a space. Empty line to finish.", "90"))
                pairs = []
                while True:
                    line = ask("   ")
                    if not line:
                        break
                    parts = line.split(None, 1)
                    pairs.append((parts[0], parts[1] if len(parts) > 1 else ""))
                if pairs:
                    added, errors, ok, msg = act_wl_add(pairs)
                    for err in errors:
                        note(err, "warn")
                    note("%d added." % len(added) if ok else msg, "ok" if ok else "err")
            elif ch == "3":
                eid = field("ID")
                if eid:
                    e, ok, msg = act_wl_toggle(eid)
                    report(ok, msg, "%s is now %s." % (e["cidr"], "enabled" if e["enabled"] else "disabled"))
            elif ch == "4":
                eid = field("ID")
                if eid:
                    find_entry(cfg, eid)
                    report(*act_wl_label(eid, field("New label")), good="Label saved.")
            elif ch == "5":
                eid = field("ID")
                if eid:
                    e = find_entry(cfg, eid)
                    if yes("Remove %s %s?" % (e["cidr"], e.get("label", ""))):
                        report(*act_wl_remove(eid), good="Removed %s." % e["cidr"])
            elif ch == "0":
                return
        except ValueError as exc:
            note(str(exc), "err")


def menu_mode():
    while True:
        cfg = load_cfg()
        screen("Block mode")
        ports = ", ".join("%d/%s" % (p["port"], p["proto"]) for p in cfg["ports"]) or "none"
        box([kv("Mode", c("ALL", "1;32") + "  every IP except whitelist/Cloudflare/Arvan is blocked"
                if cfg["mode"] == "all" else c("LISTED PORTS", "1;33") + "  only the ports below are protected"),
             kv("Ports", ports + (c("  (ignored in ALL mode)", "90") if cfg["mode"] == "all" else "")),
             kv("Ping", "everyone" if cfg["allow_ping"] else "whitelist only")], "Block mode")
        ch = menu([("1", "Switch mode", c("to " + ("LISTED PORTS" if cfg["mode"] == "all" else "ALL"), "90")),
                   ("2", "Ping", c("to " + ("whitelist only" if cfg["allow_ping"] else "everyone"), "90")),
                   ("3", "Add port"), ("4", "Remove port"), ("0", "Back")])
        try:
            if ch == "1":
                new = "ports" if cfg["mode"] == "all" else "all"
                if yes("Switch the block mode to %s?" % ("LISTED PORTS" if new == "ports" else "ALL")):
                    report(*act_set("mode", new, "mode", mode=new), good="Mode is now %s." % new.upper())
            elif ch == "2":
                on = not cfg["allow_ping"]
                report(*act_set("allow_ping", on, "ping", on=on),
                       good="Ping: %s." % ("everyone" if on else "whitelist only"))
            elif ch == "3":
                port = int(field("Port (1-65535)"))
                proto = field("Protocol tcp/udp/both", "both").lower()
                if not 1 <= port <= 65535 or proto not in ("tcp", "udp", "both"):
                    raise ValueError("Invalid port or protocol.")
                if port == cfg["ssh_port"]:
                    raise ValueError("Use the SSH menu for the SSH port.")
                ports_ = [p for p in cfg["ports"] if p["port"] != port] + [{"port": port, "proto": proto}]
                report(*act_ports(ports_), good="Port %d/%s added." % (port, proto))
            elif ch == "4":
                port = int(field("Port"))
                report(*act_ports([p for p in cfg["ports"] if p["port"] != port]), good="Port %d removed." % port)
            elif ch == "0":
                return
        except ValueError as exc:
            note(str(exc) if "invalid literal" not in str(exc) else "Numbers only.", "err")


def menu_ssh():
    while True:
        cfg = load_cfg()
        ip = ssh_client_ip()
        screen("SSH access")
        lines = [kv("Port", str(cfg["ssh_port"])),
                 kv("Access", c("open to everyone", "1;33") if cfg["ssh_open"] else c("whitelist only", "1;32"))]
        if ip:
            lines.append(kv("Your IP", ip + "  " + (c("whitelisted", "32") if covered(cfg, ip)
                                                    else c("not whitelisted", "1;31"))))
        box(lines, "SSH access")
        ch = menu([("1", "Open to everyone"), ("2", "Whitelist only"), ("0", "Back")])
        if ch == "1":
            report(*act_ssh(True), good="SSH is open to everyone.")
        elif ch == "2":
            if ip and not covered(cfg, ip):
                note("Your IP %s will be added to the whitelist first." % ip, "warn")
            if yes("Allow SSH only from the whitelist?"):
                report(*act_ssh(False), good="SSH: whitelist only.")
        elif ch == "0":
            return


def menu_cloudflare():
    while True:
        cf = load_cfg()["cloudflare"]
        screen("Cloudflare")
        box([kv("Access", c("allowed", "1;32") if cf["enabled"] else c("not allowed", "1;31")),
             kv("Ranges", "%d IPv4 + %d IPv6" % (len(cf["v4"]), len(cf["v6"]))),
             kv("Updated", cf["updated"] or c("never", "1;31"))], "Cloudflare ranges")
        ch = menu([("1", "Update ranges now"),
                   ("2", "Deny Cloudflare" if cf["enabled"] else "Allow Cloudflare"), ("0", "Back")])
        if ch == "1":
            report(*act_cf_update())
        elif ch == "2":
            on = not cf["enabled"]
            if on or yes("Deny Cloudflare? Every CDN config will stop working while the firewall is ON."):
                report(*act_cf_allow(on), good="Cloudflare is now %s." % ("allowed" if on else "denied"))
        elif ch == "0":
            return


def menu_arvan():
    while True:
        av = load_cfg().get("arvan") or {"enabled": True, "v4": [], "v6": [], "updated": ""}
        screen("Arvan Cloud")
        box([kv("Access", c("allowed", "1;32") if av.get("enabled") else c("not allowed", "1;31")),
             kv("Ranges", "%d IPv4 + %d IPv6" % (len(av.get("v4", [])), len(av.get("v6", [])))),
             kv("Updated", av.get("updated") or c("never", "1;31")),
             kv("Source", "arvancloud.ir/en/ips.txt")], "Arvan Cloud ranges")
        ch = menu([("1", "Update ranges now"),
                   ("2", "Deny Arvan Cloud" if av.get("enabled") else "Allow Arvan Cloud"), ("0", "Back")])
        if ch == "1":
            report(*act_arvan_update())
        elif ch == "2":
            on = not av.get("enabled")
            if on or yes("Deny Arvan Cloud? Every Arvan CDN config will stop working while the firewall is ON."):
                report(*act_arvan_allow(on), good="Arvan Cloud is now %s." % ("allowed" if on else "denied"))
        elif ch == "0":
            return


def menu_fastly():
    while True:
        fs = load_cfg().get("fastly") or {"enabled": True, "v4": [], "v6": [], "updated": ""}
        screen("Fastly")
        box([kv("Access", c("allowed", "1;32") if fs.get("enabled") else c("not allowed", "1;31")),
             kv("Ranges", "%d IPv4 + %d IPv6" % (len(fs.get("v4", [])), len(fs.get("v6", [])))),
             kv("Updated", fs.get("updated") or c("never", "1;31")),
             kv("Source", "api.fastly.com/public-ip-list")], "Fastly ranges")
        ch = menu([("1", "Update ranges now"),
                   ("2", "Deny Fastly" if fs.get("enabled") else "Allow Fastly"), ("0", "Back")])
        if ch == "1":
            report(*act_fastly_update())
        elif ch == "2":
            on = not fs.get("enabled")
            if on or yes("Deny Fastly? Every Fastly CDN config will stop working while the firewall is ON."):
                report(*act_fastly_allow(on), good="Fastly is now %s." % ("allowed" if on else "denied"))
        elif ch == "0":
            return


def menu_cdn_report():
    while True:
        cfg = load_cfg()
        st = get_stats()
        track = cfg.get("cdn_track", True)
        screen("CDN access report")
        lines = [kv("Tracking", on_off(track, "ON", "OFF")),
                 kv("Since", time.strftime("%Y-%m-%d %H:%M", time.localtime(st["since"])))]
        if not cfg["enabled"]:
            lines.append(c("Firewall is OFF: CDN hits are only counted while the firewall is ON.", "1;33"))
        labels = [("cloudflare", "Cloudflare"), ("arvan", "Arvan Cloud"), ("fastly", "Fastly")]
        for key, title in labels:
            hits = st.get("cdn", {}).get(key) or []
            en = (cfg.get(key) or {}).get("enabled")
            lines.append(None)
            lines.append(c("%s  (%s)" % (title, "allowed" if en else "denied"), "1;36"))
            if hits:
                for i, (ip, n) in enumerate(hits[:10], 1):
                    lines.append("  %-3d %-40s %s" % (i, ip, "{:,}".format(n)))
            else:
                lines.append(c("  (no hits yet)", "90"))
        box(lines, "CDN source IPs that reached this server")
        ch = menu([("1", "Refresh"),
                   ("2", "Toggle tracking", c("to " + ("OFF" if track else "ON"), "90")),
                   ("3", "Reset CDN counters"),
                   ("0", "Back")])
        if ch == "1":
            continue
        elif ch == "2":
            report(*act_cdn_track(not track), good="CDN tracking is now %s." % ("ON" if not track else "OFF"))
        elif ch == "3" and yes("Reset all CDN hit counters?"):
            with Locked():
                d = load_stats()
                d["cdn"] = {"cloudflare": {}, "arvan": {}, "fastly": {}}
                write_json(STATS, d, 0o644)
                if table_exists():
                    for name in ("cf_hit4", "cf_hit6", "av_hit4", "av_hit6", "fs_hit4", "fs_hit6"):
                        run(["nft", "flush", "set", "inet", TABLE, name])
            note("CDN counters reset.")
        elif ch == "0":
            return


def menu_bot():
    while True:
        b = load_cfg()["bot"]
        svc = svc_state(BOT_UNIT)
        screen("Telegram bot")
        box([kv("Token", c("set  ...%s" % b["token"][-6:], "1;32") if b["token"] else c("not set", "1;31")),
             kv("Admins", c(", ".join(map(str, b["admins"])), "1;37") if b["admins"] else c("none", "1;31")),
             kv("Service", c(svc, "1;32" if svc == "active" else "1;31"))], "Telegram bot")
        ch = menu([("1", "Set token"), ("2", "Add admin"), ("3", "Remove admin"), None,
                   ("4", "Start / restart"), ("5", "Test connection"), ("6", "Stop"), None,
                   ("7", "Setup guide"), ("0", "Back")])
        if ch == "1":
            t = field("Bot token")
            if re.match(r"^\d+:[\w-]{20,}$", t):
                update(lambda cf: cf["bot"].__setitem__("token", t))
                note("Token saved. Use Start / restart to apply it.")
            elif t:
                note("That does not look like a bot token.", "err")
        elif ch == "2":
            i = field("Numeric Telegram ID")
            if i.lstrip("-").isdigit():
                update(lambda cf: cf["bot"]["admins"].append(int(i)) if int(i) not in cf["bot"]["admins"] else None)
                note("Admin %s saved." % i)
            elif i:
                note("Numbers only.", "err")
        elif ch == "3":
            i = field("ID to remove")
            if i.lstrip("-").isdigit() and int(i) in b["admins"]:
                update(lambda cf: cf["bot"]["admins"].remove(int(i)))
                note("Removed %s." % i)
            elif i:
                note("Not in the list.", "err")
        elif ch == "4":
            if not b["token"] or not b["admins"]:
                note("Set the token and at least one admin first.", "err")
                continue
            install_system()
            run(["systemctl", "enable", BOT_UNIT])
            run(["systemctl", "restart", BOT_UNIT])
            time.sleep(1.5)
            st = svc_state(BOT_UNIT)
            if st == "active":
                note("Bot is running. Send /start to it in Telegram.")
            else:
                note("Service is '%s'. Check: journalctl -u %s -n 30 --no-pager" % (st, BOT_UNIT), "err")
        elif ch == "5":
            if not b["token"]:
                note("Set the token first.", "err")
                continue
            try:
                me = TG(b["token"]).call("getMe", _timeout=15)
                notify_admins(load_cfg(), "✅ IP Guard: <b>%s</b> — اتصال ربات برقرار است." % E(socket.gethostname()))
                note("OK: @%s. A test message was sent to the admins." % me["result"]["username"])
            except (urllib.error.URLError, OSError, ValueError, KeyError) as exc:
                note("Failed: %s" % exc, "err")
        elif ch == "6":
            if yes("Stop the bot and disable it at boot?"):
                run(["systemctl", "disable", "--now", BOT_UNIT])
                note("Bot stopped.", "warn")
        elif ch == "7":
            show_help(HELP[7])
        elif ch == "0":
            return


def menu_stats():
    while True:
        cfg = load_cfg()
        st = get_stats()
        screen("Statistics")
        lines = [kv("Since", time.strftime("%Y-%m-%d %H:%M", time.localtime(st["since"]))),
                 kv("Blocked", c("{:,}".format(st["packets"]), "1;37") + " packets  (%s)" % fmt_bytes(st["bytes"])),
                 kv("SSH", "{:,}".format(st["ssh"]) + " packets")]
        if not cfg["enabled"]:
            lines.append(c("Firewall is OFF: nothing is being blocked now.", "1;33"))
        lines += [None, c("%-4s %-40s %s" % ("#", "TOP BLOCKED SOURCES", "PACKETS"), "1;36")]
        for i, (ip, n) in enumerate(st["top"], 1):
            lines.append("%-4d %-40s %s" % (i, ip, "{:,}".format(n)))
        if not st["top"]:
            lines.append(c("(none yet)", "90"))
        box(lines, "Blocked traffic")
        ch = menu([("1", "Refresh"), ("2", "Whitelist a source", c("by #", "90")), ("3", "Reset counters"),
                   ("0", "Back")])
        if ch == "2" and st["top"]:
            n = field("# from the list")
            if n.isdigit() and 1 <= int(n) <= len(st["top"]):
                added, errors, ok, msg = act_wl_add([(st["top"][int(n) - 1][0], "from-stats")])
                note("Added %s." % added[0]["cidr"] if added else (errors or [msg])[0], "ok" if added else "err")
        elif ch == "3" and yes("Reset all block counters?"):
            act_reset_stats()
            note("Counters reset.")
        elif ch == "0":
            return


def menu_settings():
    while True:
        cfg = load_cfg()
        installed = os.path.exists(INSTALL_PATH)
        screen("Settings")
        inst = (c("outdated - run Install", "1;33") if install_outdated() else c("installed", "1;32")) \
            if installed else c("not installed", "1;31")
        box([kv("Rollback", "%d min" % cfg["rollback_minutes"]),
             kv("SSH port", str(cfg["ssh_port"])),
             kv("System", inst + c("  " + INSTALL_PATH, "90"))], "Settings")
        ch = menu([("1", "Rollback minutes"), ("2", "SSH port number"), ("3", "Install / update"), ("0", "Back")])
        if ch == "1":
            v = field("Minutes (1-240)", str(cfg["rollback_minutes"]))
            if v.isdigit() and 1 <= int(v) <= 240:
                report(*act_set("rollback_minutes", int(v), "rollback", minutes=int(v)), good="Saved.")
            else:
                note("Enter a number from 1 to 240.", "err")
        elif ch == "2":
            v = field("SSH port", str(cfg["ssh_port"]))
            if v.isdigit() and 1 <= int(v) <= 65535:
                report(*act_set("ssh_port", int(v), "ssh_port", port=int(v)), good="Saved.")
            else:
                note("Enter a port from 1 to 65535.", "err")
        elif ch == "3":
            note(install_system())
        elif ch == "0":
            return


HELP = [
    ("How it works",
     "IP Guard keeps its own nftables table (inet ip_guard), separate from the panel rules, so a panel "
     "restart or Apply does not remove it.\n"
     "Firewall ON + mode ALL: a new incoming connection is accepted only from an enabled whitelist entry, "
     "a Cloudflare range (if allowed), an Arvan Cloud range (if allowed), or to SSH while SSH is open. "
     "Everything else is dropped and counted in Statistics.\n"
     "Replies to connections the server opened itself always pass, so outgoing traffic (updates, the "
     "Telegram bot, tunnels started from this server) keeps working.\n"
     "Firewall OFF: the table is removed and every IP can connect."),
    ("Quick start",
     "1. Whitelist: add every server that must reach this one (relays, your own IP).\n"
     "2. Cloudflare / Arvan Cloud: update the ranges so CDN configs keep working.\n"
     "3. Block mode: ALL.\n"
     "4. Firewall: switch ON, test configs and relays from outside, then Confirm.\n"
     "5. Settings > Install / update: once, so the firewall comes back after a reboot.\n"
     "6. Telegram bot (optional): manage everything from Telegram."),
    ("Whitelist",
     "Entries can always connect, on every port, even with the firewall ON.\n"
     "Formats: 1.2.3.4   1.2.3.0/24   2001:db8::1   2001:db8::/48. Ranges wider than /8 (IPv4) or /16 "
     "(IPv6) are refused.\n"
     "A disabled entry stays in the list but has no access. Changes apply immediately when the firewall "
     "is ON. Your current SSH IP is added automatically when you switch the firewall ON or lock SSH."),
    ("Block mode & ping",
     "ALL: every IP outside the whitelist/Cloudflare/Arvan is blocked on every port. This is the normal mode.\n"
     "LISTED PORTS: only the listed ports are protected; all other ports stay open.\n"
     "Ping: everyone, or whitelist only. IPv6 control messages (ICMPv6) and DHCP replies are always allowed, "
     "otherwise the server loses its network."),
    ("Safety timer",
     "After switching ON you have the rollback time (Settings) to choose Confirm in the Firewall menu or in "
     "the bot. If you do not, the firewall switches OFF by itself and the bot admins get a message. A reboot "
     "before confirming also ends with the firewall OFF. So a wrong rule can never lock you out for good.\n"
     "Emergency, from the server console: python3 /opt/ip-guard/ip_guard.py rollback"),
    ("SSH access",
     "Open: anyone can reach the SSH port, even with the firewall ON.\n"
     "Whitelist only: only whitelisted IPs can reach SSH. Your current IP is added first so you are not cut "
     "off. Open it from the bot when you need to log in from a new IP, then lock it again.\n"
     "If SSH runs on another port, set it in Settings (this does not change the SSH server itself)."),
    ("Cloudflare, Arvan & Fastly",
     "CDN configs reach this server from the CDN provider's own IPs, not from your users. Keep the CDNs "
     "you use allowed or every related CDN config stops working while the firewall is ON.\n"
     "Cloudflare: cloudflare.com/ips-v4 and ips-v6 (panel local fallback).\n"
     "Arvan Cloud: https://www.arvancloud.ir/en/ips.txt\n"
     "Fastly: https://api.fastly.com/public-ip-list\n"
     "Update them now and then. CDN IPs never get SSH access.\n"
     "CDN report: when tracking is ON, source IPs that connected from each CDN range are counted and "
     "shown in the CDN report menu / bot. Use it to see which Arvan/Cloudflare/Fastly edge IPs hit you."),
    ("Telegram bot setup",
     "1. In Telegram open @BotFather, send /newbot, choose a name and a username ending in 'bot'. "
     "Copy the token (123456789:AA...). Use a NEW bot; never reuse another bot's token.\n"
     "2. Telegram bot > Set token: paste it.\n"
     "3. Open @userinfobot, press Start, copy your numeric Id. Telegram bot > Add admin. Only admins get "
     "answers; everybody else is ignored.\n"
     "4. Open your new bot and press Start once (a bot cannot message you first).\n"
     "5. Telegram bot > Start / restart, then Test connection.\n"
     "The bot shows the server IPs and load, block statistics, manages the whitelist (send IPs straight "
     "into the chat), the firewall, SSH, Cloudflare and Arvan Cloud, and reports every change to all admins.\n"
     "Logs: journalctl -u ip-guard-bot.service -n 30 --no-pager"),
    ("Command line & files",
     "python3 ip_guard.py            menu\n"
     "python3 ip_guard.py status     short status\n"
     "python3 ip_guard.py confirm    confirm the firewall\n"
     "python3 ip_guard.py rollback   switch the firewall OFF now\n"
     "Config: /etc/ip-guard/config.json   State: /var/lib/ip-guard/\n"
     "Installed copy: /opt/ip-guard/ip_guard.py   Services: ip-guard.service (boot), ip-guard-bot.service\n"
     "After replacing this file, run Settings > Install / update so the services use the new version."),
]


def show_help(topic):
    screen("Help", topic[0])
    box(wrap(topic[1]), topic[0], color="35")
    pause()


def menu_help():
    while True:
        screen("Help")
        ch = menu([(str(i), t) for i, (t, _) in enumerate(HELP, 1)] + [("0", "Back")], "Help topics")
        if ch.isdigit() and 1 <= int(ch) <= len(HELP):
            show_help(HELP[int(ch) - 1])
        elif ch == "0":
            return


def main_menu():
    if os.geteuid() != 0:
        sys.exit("Run as root.")
    if shutil.which("nft") is None:
        sys.exit("nft (nftables) is not installed.")
    try:
        while True:
            cfg = load_cfg()
            if install_outdated():
                note("The installed copy is older than this file: Settings > Install / update.", "warn")
            screen()
            si, (v4, v6), st = sysinfo(), server_ips(), get_stats()
            bot = svc_state(BOT_UNIT) if cfg["bot"]["token"] else "not set"
            av = cfg.get("arvan") or {}
            box([kv("IPv4", c(v4 or "-", "1;37")),
                 kv("IPv6", c(v6 or "-", "1;37")),
                 kv("Uptime", fmt_uptime(si["up"]) + c("   load ", "90") + "%.2f %.2f %.2f" % si["load"]),
                 kv("CPU / RAM", "%d%%  /  %s of %s" % (si["cpu"], fmt_bytes(si["mem_used"]),
                                                        fmt_bytes(si["mem_total"]))),
                 kv("Blocked", c("{:,}".format(st["packets"]), "1;37") + " packets since "
                    + time.strftime("%m-%d %H:%M", time.localtime(st["since"])))], "Server")
            wl_on = sum(e["enabled"] for e in cfg["whitelist"])
            cf = cfg["cloudflare"]
            fs = cfg.get("fastly") or {}
            ch = menu([
                ("1", "Firewall", fw_value(cfg)),
                ("2", "Whitelist", "%d of %d enabled" % (wl_on, len(cfg["whitelist"]))),
                ("3", "Block mode", ("ALL" if cfg["mode"] == "all" else "LISTED PORTS (%d)" % len(cfg["ports"]))
                 + c("  ping: " + ("everyone" if cfg["allow_ping"] else "whitelist"), "90")),
                ("4", "SSH access", c("open to everyone", "1;33") if cfg["ssh_open"] else c("whitelist only", "1;32")),
                ("5", "Cloudflare", ("allowed" if cf["enabled"] else c("denied", "1;31"))
                 + c("  %d ranges" % (len(cf["v4"]) + len(cf["v6"])), "90")),
                ("6", "Arvan Cloud", ("allowed" if av.get("enabled") else c("denied", "1;31"))
                 + c("  %d ranges" % (len(av.get("v4", [])) + len(av.get("v6", []))), "90")),
                ("7", "Fastly", ("allowed" if fs.get("enabled") else c("denied", "1;31"))
                 + c("  %d ranges" % (len(fs.get("v4", [])) + len(fs.get("v6", []))), "90")),
                ("8", "CDN report", c("track " + ("ON" if cfg.get("cdn_track", True) else "OFF"), "90")),
                ("9", "Telegram bot", c(bot, "1;32" if bot == "active" else "1;31")),
                ("s", "Statistics", "{:,}".format(st["packets"]) + c(" blocked", "90")),
                ("t", "Settings", c("rollback %d min" % cfg["rollback_minutes"], "90")),
                ("h", "Help"),
                None,
                ("0", "Exit")], "Main menu")
            action = {"1": menu_firewall, "2": menu_whitelist, "3": menu_mode, "4": menu_ssh,
                      "5": menu_cloudflare, "6": menu_arvan, "7": menu_fastly, "8": menu_cdn_report,
                      "9": menu_bot, "s": menu_stats, "t": menu_settings, "h": menu_help}.get(ch)
            if action:
                action()
            elif ch == "0":
                break
    except KeyboardInterrupt:
        pass
    clear()


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "menu"
    if cmd == "menu":
        main_menu()
    elif cmd == "status":
        print(status_text(load_cfg()))
    elif cmd == "apply":
        with Locked():
            cfg = load_cfg()
            if pending_info():  # an unconfirmed switch-on survived a reboot: go back to OFF
                cfg["enabled"] = False
                save_cfg(cfg)
                clear_pending()
            print(apply_cfg(cfg)[1])
    elif cmd == "confirm":
        print(act_confirm()[1])
    elif cmd == "rollback":
        with Locked():
            cfg = load_cfg()
            cfg["enabled"] = False
            ok, msg = apply_cfg(cfg)
            save_cfg(cfg)
            try:
                os.unlink(PENDING)
            except OSError:
                pass
            print(msg)
        event("fw_rollback", "system")
    elif cmd == "bot":
        run_bot()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
