#!/usr/bin/env python3
"""
tunnel-manager: interactive menu to create and manage Hysteria2 tunnels
between an IRAN server (this machine, run as root) and a KHARJ server (over SSH).

Tunnel types:
  direct   Hysteria server on KHARJ, Hysteria client on IRAN (tcpForwarding/udpForwarding)
  reverse  Hysteria server on IRAN + rbridge relay, Hysteria client + rbridge on KHARJ
  both     direct + reverse behind a haproxy load balancer on IRAN (TCP, roundrobin)

Passwords for SSH are asked on every run and never written to disk.
"""

import getpass
import json
import os
import random
import re
import secrets
import shlex
import shutil
import socket
import string
import subprocess
import sys
import time
from datetime import datetime, timezone

try:
    import paramiko
except ImportError:
    paramiko = None

# ---------------------------------------------------------------- constants
VERSION = "0.8.2"
BASE_DIR = "/etc/tunnel-manager"
TUNNEL_DIR = os.path.join(BASE_DIR, "tunnels")
HAP_DIR = os.path.join(BASE_DIR, "haproxy")
BACKUP_DIR = "/var/backups/tunnel-manager"
HY_BIN = "/usr/local/bin/hysteria"
RB_BIN = "/usr/local/bin/tm-rbridge"
REMOTE_BASE = "/etc/tunnel-manager"
PORT_MIN, PORT_MAX = 20000, 60000
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,19}$")

RAM_PRESETS = [128, 256, 512, 1024, 2048, 4096]
MASQ_PRESETS = {
    "1": ("bing", "https://www.bing.com"),
    "2": ("microsoft", "https://www.microsoft.com"),
    "3": ("wikipedia", "https://en.wikipedia.org"),
    "4": ("apple", "https://www.apple.com"),
}

# ---------------------------------------------------------------- colors
class C:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    DIM = "\033[2m"
    RED = "\033[91m"
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    BLUE = "\033[94m"
    MAGENTA = "\033[95m"
    CYAN = "\033[96m"
    WHITE = "\033[97m"


def paint(text, *styles):
    return "".join(styles) + text + C.RESET


LOGO = r"""
  ████████╗██╗   ██╗███╗   ██╗███╗   ██╗███████╗██╗
  ╚══██╔══╝██║   ██║████╗  ██║████╗  ██║██╔════╝██║
     ██║   ██║   ██║██╔██╗ ██║██╔██╗ ██║█████╗  ██║
     ██║   ██║   ██║██║╚██╗██║██║╚██╗██║██╔══╝  ██║
     ██║   ╚██████╔╝██║ ╚████║██║ ╚████║███████╗███████╗
     ╚═╝    ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝╚══════╝
           H Y S T E R I A 2   T U N N E L   M A N A G E R
"""


def clear():
    os.system("clear")


def banner(subtitle=""):
    clear()
    print(paint(LOGO, C.CYAN, C.BOLD))
    print(paint(f"  script v{VERSION}", C.DIM))
    if subtitle:
        print(paint("  " + subtitle, C.YELLOW, C.BOLD))
    print(paint("  " + "-" * 60, C.BLUE))
    print()


QUIET = False


def set_quiet(value):
    global QUIET
    QUIET = value


def info(msg, always=False):
    if QUIET and not always:
        return
    print(paint("  [i] ", C.BLUE, C.BOLD) + msg)


def warn(msg):
    print(paint("  [!] ", C.YELLOW, C.BOLD) + paint(msg, C.YELLOW))


def ok(msg, always=False):
    if QUIET and not always:
        return
    print(paint("  [✔] ", C.GREEN, C.BOLD) + paint(msg, C.GREEN))


def fail(msg, always=False):
    if QUIET and not always:
        return
    print(paint("  [✖] ", C.RED, C.BOLD) + paint(msg, C.RED))


def header(msg, always=False):
    if QUIET and not always:
        return
    print()
    print(paint("  ── " + msg + " ", C.MAGENTA, C.BOLD))


def ask(prompt, default=None):
    suffix = f" [{default}]" if default not in (None, "") else ""
    val = input(paint("  ? ", C.CYAN, C.BOLD) + prompt + paint(suffix, C.DIM) + ": ").strip()
    return val if val else (default if default is not None else "")


def ask_yes(prompt, default=False):
    d = "Y/n" if default else "y/N"
    val = input(paint("  ? ", C.CYAN, C.BOLD) + prompt + paint(f" [{d}]", C.DIM) + ": ").strip().lower()
    if not val:
        return default
    return val in ("y", "yes")


def pause():
    input(paint("\n  Press Enter to continue...", C.DIM))


class StopError(Exception):
    """Raised when a step fails. The current operation stops here."""


# ---------------------------------------------------------------- local helpers
def sh(args, check=False, input_text=None):
    """Run a local command. Returns (rc, combined output)."""
    try:
        p = subprocess.run(
            args, capture_output=True, text=True, input=input_text, timeout=600
        )
        out = (p.stdout or "") + (p.stderr or "")
        if check and p.returncode != 0:
            raise StopError(out.strip() or f"command failed: {' '.join(args)}")
        return p.returncode, out.strip()
    except FileNotFoundError:
        if check:
            raise StopError(f"command not found: {args[0]}")
        return 127, f"command not found: {args[0]}"


def local_port_used(port, proto="tcp"):
    """True if the port is already bound on this machine (bind test)."""
    kind = socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM
    s = socket.socket(socket.AF_INET, kind)
    try:
        s.bind(("0.0.0.0", port))
        return False
    except OSError:
        return True
    finally:
        s.close()


def pick_random_port(used_set, proto_list=("tcp",), exclude=()):
    for _ in range(2000):
        p = random.randint(PORT_MIN, PORT_MAX)
        if p in used_set or p in exclude:
            continue
        if all(not local_port_used(p, pr) for pr in proto_list):
            return p
    raise StopError("could not find a free random port")


def write_local(path, content, mode=0o600):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        os.makedirs(BACKUP_DIR, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, os.path.join(BACKUP_DIR, stamp + "-" + os.path.basename(path)))
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, mode)


def load_json(path):
    with open(path) as f:
        return json.load(f)


def save_json(path, data):
    write_local(path, json.dumps(data, indent=2))


def list_tunnels():
    if not os.path.isdir(TUNNEL_DIR):
        return []
    out = []
    for fn in sorted(os.listdir(TUNNEL_DIR)):
        if fn.endswith(".json"):
            out.append(load_json(os.path.join(TUNNEL_DIR, fn)))
    return out


def tunnel_path(name):
    return os.path.join(TUNNEL_DIR, name + ".json")


def used_ports_local():
    """Ports reserved by our own tunnels, so random picks never collide with them."""
    used = set()
    for t in list_tunnels():
        for key in ("public_port", "target_port"):
            if isinstance(t.get(key), int):
                used.add(t[key])
        for part in t.get("parts", {}).values():
            for v in part.values():
                if isinstance(v, int):
                    used.add(v)
    return used


# ---------------------------------------------------------------- remote (Kharej)
class Remote:
    """
    SSH mode: every step runs over SSH and is checked by exit code.
    Manual mode: every step is printed; the operator runs it on the KHARJ
    terminal and confirms with y (done) or n (failed, stop).
    """

    def __init__(self):
        self.mode = "none"          # none | ssh | manual
        self.client = None
        self.host = ""
        self.port = 22
        self.user = "root"

    # --- connection
    def connect_ssh(self, host, port, user, password):
        if paramiko is None:
            raise StopError("paramiko is not installed (run dependency check first)")
        cli = paramiko.SSHClient()
        cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            cli.connect(host, port=port, username=user, password=password,
                        timeout=15, banner_timeout=15, auth_timeout=15,
                        look_for_keys=False, allow_agent=False)
        except Exception as e:
            raise StopError(f"SSH to {host}:{port} failed: {e}")
        self.client = cli
        self.host, self.port, self.user = host, port, user
        self.mode = "ssh"
        ok(f"SSH connected to {user}@{host}:{port}")

    def set_manual(self):
        self.mode = "manual"
        self.client = None

    def close(self):
        if self.client:
            self.client.close()
        self.client = None
        self.mode = "none"

    # --- primitive
    def _exec(self, cmd):
        _, stdout, stderr = self.client.exec_command(cmd, timeout=900)
        out = stdout.read().decode(errors="replace")
        err = stderr.read().decode(errors="replace")
        rc = stdout.channel.recv_exit_status()
        return rc, (out + err).strip()

    def probe(self, cmd):
        """Quick read-only query. Returns (rc, output). Works only in ssh mode."""
        if self.mode != "ssh":
            return 1, ""
        return self._exec(cmd)

    # --- main API: run one named step
    def step(self, desc, cmd):
        if self.mode == "ssh":
            if not QUIET:
                print(paint("  ➜ ", C.BLUE, C.BOLD) + desc)
            rc, out = self._exec(cmd)
            if rc != 0:
                fail(f"{desc} (exit {rc})")
                if out and not QUIET:
                    print(paint("    " + out[-800:].replace("\n", "\n    "), C.RED))
                detail = out.strip().splitlines()[-1][:160] if out.strip() else ""
                raise StopError(f"{desc}: {detail}" if detail else desc)
            ok(desc)
            return out
        if self.mode == "manual":
            print()
            print(paint(f"  STEP: {desc}", C.YELLOW, C.BOLD))
            print(paint("  Run this on the KHARJ terminal:", C.DIM))
            print(paint("  " + "─" * 58, C.BLUE))
            for line in cmd.splitlines():
                print(paint("  " + line, C.WHITE))
            print(paint("  " + "─" * 58, C.BLUE))
            if ask_yes("Did this step finish successfully?", default=False):
                ok(desc)
                return ""
            fail(desc)
            raise StopError(desc)
        raise StopError("no connection to KHARJ (not in SSH or manual mode)")

    def write_file(self, desc, path, content, mode="600"):
        """Write a file on KHARJ. SSH: via SFTP. Manual: shown as a heredoc."""
        if self.mode == "ssh":
            if not QUIET:
                print(paint("  ➜ ", C.BLUE, C.BOLD) + desc)
            try:
                sftp = self.client.open_sftp()
                d = os.path.dirname(path)
                self._exec(f"mkdir -p {d}")
                with sftp.open(path, "w") as f:
                    f.write(content)
                sftp.chmod(path, int(mode, 8))
                sftp.close()
            except Exception as e:
                fail(f"{desc}: {e}")
                raise StopError(f"{desc}: {e}")
            ok(desc)
            return
        cmd = (
            f"mkdir -p {os.path.dirname(path)}\n"
            f"cat > {path} <<'TM_EOF'\n{content}TM_EOF\n"
            f"chmod {mode} {path}"
        )
        self.step(desc, cmd)

    def upload_binary(self, desc, local_path, remote_path):
        if self.mode == "ssh":
            if not QUIET:
                print(paint("  ➜ ", C.BLUE, C.BOLD) + desc)
            try:
                sftp = self.client.open_sftp()
                sftp.put(local_path, remote_path)
                sftp.chmod(remote_path, 0o755)
                sftp.close()
            except Exception as e:
                fail(f"{desc}: {e}")
                raise StopError(desc)
            ok(desc)
            return
        self.step(desc, f"# copy this file to KHARJ at {remote_path}, then: chmod 755 {remote_path}")


REMOTE = Remote()



# ---------------------------------------------------------------- config generators
def yaml_str(s):
    """Quote a value for YAML safely."""
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def rbridge_yaml(role, t, memory_mb, rules):
    """rbridge config. rules: list of dicts (see reverse tunnel builder)."""
    lines = [
        f"role: {role}",
        f"memory_limit_mb: {memory_mb}",
        "hysteria:",
        f"  port: {t['hy_port']}",
        "  password: " + yaml_str(t["rb_password"]),
    ]
    if role == "kharej":
        lines.append(f"  server: {t['iran_ip']}:{t['hy_port']}")
        lines.append("kharej_rules:")
        for r in rules:
            lines += [
                f"  - name: {r['name']}",
                f"    pool_listen: {r['pool_listen']}",
                f"    iran_internal: {r['internal']}",
                f"    target: {r['target']}",
            ]
    else:
        lines.append("iran_rules:")
        for r in rules:
            lines += [
                f"  - name: {r['name']}",
                f"    listen: {r['listen']}",
                f"    internal: {r['internal']}",
            ]
    return "\n".join(lines) + "\n"


def haproxy_cfg(name, front_port, backends):
    """backends: list of (label, 127.0.0.1:port, weight). Pure TCP, roundrobin."""
    lines = [
        "# managed by tunnel-manager; do not edit by hand",
        "global",
        "    maxconn 4096",
        "defaults",
        "    mode tcp",
        "    timeout connect 10s",
        "    timeout client 1h",
        "    timeout server 1h",
        "    timeout tunnel 1h",
        f"frontend ft_{name}",
        f"    bind 0.0.0.0:{front_port}",
        f"    default_backend bk_{name}",
        f"backend bk_{name}",
        "    balance roundrobin",
    ]
    for label, addr, weight in backends:
        lines.append(f"    server {label} {addr} weight {weight}")
    return "\n".join(lines) + "\n"


def unit_file(desc, exec_cmd, extra=""):
    return (
        "[Unit]\n"
        f"Description={desc}\n"
        "After=network-online.target\n"
        "Wants=network-online.target\n\n"
        "[Service]\n"
        f"ExecStart={exec_cmd}\n"
        "Restart=always\n"
        "RestartSec=3\n"
        "LimitNOFILE=65536\n"
        f"{extra}"
        "\n[Install]\n"
        "WantedBy=multi-user.target\n"
    )


def pin_from_cert(cert_path):
    """Returns the SHA-256 fingerprint in the colon format Hysteria expects for pinSHA256."""
    rc, out = sh(["openssl", "x509", "-in", cert_path, "-noout", "-fingerprint", "-sha256"], check=True)
    m = re.search(r"Fingerprint=([0-9A-F:]+)", out)
    if not m:
        raise StopError("could not read certificate fingerprint")
    return m.group(1)


def make_self_signed(cert_dir, cn):
    """Creates a self-signed EC cert for the masquerade SNI. Uses openssl locally."""
    os.makedirs(cert_dir, exist_ok=True)
    cert = os.path.join(cert_dir, "cert.pem")
    key = os.path.join(cert_dir, "key.pem")
    sh(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
        "-nodes", "-keyout", key, "-out", cert, "-days", "3650", "-subj", f"/CN={cn}",
        "-addext", f"subjectAltName=DNS:{cn}"], check=True)
    os.chmod(key, 0o600)
    return cert, key


# ---------------------------------------------------------------- service checks, rbridge on IRAN, certificate reuse
def verify_local_unit(unit):
    """Stops with the last log lines when a unit on IRAN is not running."""
    state = ""
    for _ in range(10):
        _, state = sh(["systemctl", "is-active", unit])
        if state.strip() not in ("activating", "reloading"):
            break
        time.sleep(1)
    if state.strip() == "active":
        ok(f"{unit} is running on IRAN")
        return
    _, logs = sh(["journalctl", "-u", unit, "-n", "15", "--no-pager"])
    for line in logs.splitlines()[-15:]:
        print(paint("    " + line, C.RED))
    raise StopError(f"{unit} is not running on IRAN (state: {state.strip() or 'unknown'})")


RB_RELEASE_URL = "https://github.com/URT19/Tunnel-Lab/releases/download/rbridge-v1.0/rbridge-linux-x86_64"
RB_FILE_NAME = "rbridge-linux-x86_64"


def is_linux_binary(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def rbridge_file_ok(path):
    return os.path.isfile(path) and os.path.getsize(path) > 0 and is_linux_binary(path)


def make_executable(path):
    os.chmod(path, 0o755)


def find_rbridge_on_server():
    """Looks for the binary on IRAN and returns the valid matches."""
    _, out = sh(["timeout", "90", "find", "/", "-xdev", "-type", "f", "-name", RB_FILE_NAME])
    return [line.strip() for line in out.splitlines() if line.strip().startswith("/") and rbridge_file_ok(line.strip())]


def download_rbridge(dest):
    tmp = dest + ".part"
    rc, _ = sh(["curl", "-fsSL", "--max-time", "180", "-o", tmp, RB_RELEASE_URL])
    if rc != 0 or not rbridge_file_ok(tmp):
        if os.path.exists(tmp):
            os.remove(tmp)
        return False
    os.replace(tmp, dest)
    return True


def ensure_rbridge_iran():
    """Makes sure rbridge exists on IRAN at RB_BIN: local copy, then search, then download,
    then waits for the user to place the file. Never stops with an error in that last case."""
    header("rbridge binary on IRAN")
    if rbridge_file_ok(RB_BIN):
        if not os.access(RB_BIN, os.X_OK):
            make_executable(RB_BIN)
            ok(f"execute permission set on {RB_BIN}")
        ok(f"rbridge is ready at {RB_BIN}")
        return

    info(f"searching this server for {RB_FILE_NAME} ...")
    for cand in find_rbridge_on_server():
        shutil.copy2(cand, RB_BIN)
        make_executable(RB_BIN)
        ok(f"found {cand}, installed at {RB_BIN}")
        return

    info("not found on this server. Downloading from GitHub ...")
    if download_rbridge(RB_BIN):
        make_executable(RB_BIN)
        ok(f"downloaded to {RB_BIN}")
        return

    while True:
        warn(f"{RB_FILE_NAME} could not be found or downloaded.")
        info(f"Place the file at this path: {RB_BIN}", always=True)
        info(f"Download it yourself if needed: {RB_RELEASE_URL}", always=True)
        info("Type y after placing the file, so the script checks it. Type c to cancel.", always=True)
        answer = ask("y / c", default="").lower()
        if answer == "c":
            info("cancelled. Run the script again when the file is ready.", always=True)
            info("Or press Ctrl+C to quit at any time.", always=True)
            sys.exit(0)
        if answer == "y":
            if rbridge_file_ok(RB_BIN):
                make_executable(RB_BIN)
                ok(f"rbridge is ready at {RB_BIN}")
                return
            warn(f"no valid Linux binary at {RB_BIN} yet.")
        else:
            warn("type y or c.")


CERT_ROOTS_IRAN = [f"{BASE_DIR}/acme", "/etc/letsencrypt/live"]
CERT_ROOTS_KHARJ = [f"{REMOTE_BASE}/acme", "/etc/letsencrypt/live"]
MIN_CERT_LIFETIME_SECONDS = 30 * 24 * 3600


def cert_search_script(domain, roots=None):
    """Shell script that lists certificates for DOMAIN.
    Output lines: CAND|cert_path|key_path|enddate|valid|match|self_signed"""
    roots_txt = " ".join(roots)
    return f'''
D="{domain}"
for f in $(grep -RlI "BEGIN CERTIFICATE" {roots_txt} 2>/dev/null); do
  openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed 's/^ *//' | grep -qxF "DNS:$D" || continue
  key=""
  if grep -q "PRIVATE KEY" "$f" 2>/dev/null; then
    key="$f"
  else
    d=$(dirname "$f")
    for k in privkey.pem key.pem "$D.key"; do
      if [ -z "$key" ] && [ -f "$d/$k" ]; then key="$d/$k"; fi
    done
  fi
  end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)
  if openssl x509 -in "$f" -noout -checkend {MIN_CERT_LIFETIME_SECONDS} >/dev/null 2>&1; then valid=yes; else valid=no; fi
  if [ "$(openssl x509 -in "$f" -noout -issuer_hash 2>/dev/null)" = "$(openssl x509 -in "$f" -noout -subject_hash 2>/dev/null)" ]; then self=yes; else self=no; fi
  match=no
  if [ -n "$key" ]; then
    a=$(openssl x509 -in "$f" -noout -pubkey 2>/dev/null | md5sum)
    b=$(openssl pkey -in "$key" -pubout 2>/dev/null | md5sum)
    if [ "$a" = "$b" ]; then match=yes; fi
  fi
  echo "CAND|$f|$key|$end|$valid|$match|$self"
done
true
'''


def search_certificates(side, domain, roots=None):
    """Certificates for DOMAIN on SIDE. Returns None when the search cannot run (manual mode)."""
    roots = CERT_ROOTS_KHARJ if side == "KHARJ" else CERT_ROOTS_IRAN
    script = cert_search_script(domain, roots)
    if side == "KHARJ":
        if REMOTE.mode != "ssh":
            return None
        _, out = REMOTE.probe(script)
    else:
        _, out = sh(["bash", "-c", script])
    found = []
    for line in out.splitlines():
        parts = line.strip().split("|")
        if len(parts) == 7 and parts[0] == "CAND":
            found.append({"cert": parts[1], "key": parts[2], "end": parts[3],
                          "valid": parts[4] == "yes", "match": parts[5] == "yes",
                          "self": parts[6] == "yes"})
    return found


def usable_certs(found):
    """Certificates that a public client can verify: trusted issuer, key matches, not expiring soon."""
    return [c for c in (found or []) if c["valid"] and c["match"] and not c["self"]]


def days_left(end_text):
    try:
        end = datetime.strptime(" ".join(end_text.split()), "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    except ValueError:
        return "?"
    return max(0, (end - datetime.now(timezone.utc)).days)


def resolve_certificate(side, domain):
    """Searches SIDE for a certificate for DOMAIN and asks before reusing it.
    Returns (cert_path, key_path) to reuse, or None to request a new certificate."""
    header(f"Existing certificate check: {domain} on {side}")
    found = search_certificates(side, domain)
    if found is None:
        warn("manual mode: certificates on KHARJ cannot be searched. A new one will be requested.")
        return None
    usable = usable_certs(found)
    if not usable:
        info("no usable certificate for this domain. A new one will be requested.")
        return None
    print()
    print("    0) request a new certificate")
    for i, c in enumerate(usable, 1):
        print(f"    {i}) {domain}, {days_left(c['end'])} days left")
    while True:
        raw = ask("Choose a number", default="1")
        if raw.isdigit() and int(raw) <= len(usable):
            break
        warn(f"enter a number from 0 to {len(usable)}")
    choice = int(raw)
    if choice == 0:
        info("requesting a new certificate")
        return None
    c = usable[choice - 1]
    ok(f"reusing existing certificate for {domain}")
    return c["cert"], c["key"]


def remember_issued_cert(t, bench_cert):
    """After the first ACME issue in a benchmark, keep that certificate for the next tests."""
    if t["profile"] != "max-stealth":
        return
    for part in t["parts"]:
        if part in bench_cert:
            continue
        side = "KHARJ" if part == "direct" else "IRAN"
        usable = usable_certs(search_certificates(side, t["domains"][part]))
        if usable:
            bench_cert[part] = (usable[0]["cert"], usable[0]["key"])
            ok(f"{part}: certificate from this run is saved for the next tests")
        else:
            info(f"{part}: no usable certificate found after issue; the next test requests again")


def dead_units(t):
    """Units of a tunnel that are not active right now, as 'SIDE unit (state)'."""
    dead = []
    for where, unit in unit_names(t):
        if where == "IRAN":
            _, state = sh(["systemctl", "is-active", unit])
        elif REMOTE.mode == "ssh":
            _, state = REMOTE.probe(f"systemctl is-active {unit}")
        else:
            continue
        if state.strip() != "active":
            dead.append(f"{where} {unit} ({state.strip() or 'unknown'})")
    return dead


def unit_log_tail(t, lines=8):
    """Last log lines of every unit of a tunnel, from both servers."""
    chunks = []
    for where, unit in unit_names(t):
        if where == "IRAN":
            _, out = sh(["journalctl", "-u", unit, "-n", str(lines), "--no-pager"])
        elif REMOTE.mode == "ssh":
            _, out = REMOTE.probe(f"journalctl -u {unit} -n {lines} --no-pager")
        else:
            out = ""
        if out.strip():
            chunks.append(f"[{where}] {unit}\n" + out.strip())
    return "\n".join(chunks)



def random_secret(n=32):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(n))


# ---------------------------------------------------------------- masquerade check
def masq_test_remote(url):
    """Checks that KHARJ can fetch the URL with HTTP 200 before we accept it."""
    rc, out = REMOTE.probe(
        f"curl -sk -o /dev/null -m 15 -w '%{{http_code}}' {url}"
    )
    return rc == 0 and out.strip() == "200"


def masq_test_local(url):
    rc, out = sh(["curl", "-sk", "-o", "/dev/null", "-m", "15", "-w", "%{http_code}", url])
    return rc == 0 and out.strip() == "200"



# ---------------------------------------------------------------- service helpers
def local_unit_write(unit_name, text):
    write_local(f"/etc/systemd/system/{unit_name}", text, mode=0o644)


def local_service(action, unit_name):
    rc, out = sh(["systemctl", action, unit_name])
    if rc != 0:
        raise StopError(f"systemctl {action} {unit_name} failed: {out[-400:]}")
    if action in ("start", "restart"):
        time.sleep(3)
        verify_local_unit(unit_name)


def remote_unit_step(name_unit, text, desc):
    REMOTE.write_file(f"write unit {name_unit} on KHARJ", f"/etc/systemd/system/{name_unit}", text, mode="644")
    REMOTE.step(f"start {name_unit} on KHARJ",
                f"systemctl daemon-reload && systemctl enable --now {name_unit}")
    if REMOTE.mode != "ssh":
        return
    state = ""
    for _ in range(10):
        time.sleep(1)
        _, state = REMOTE.probe(f"systemctl is-active {name_unit}")
        if state.strip() not in ("activating", "reloading"):
            break
    if state.strip() != "active":
        _, logs = REMOTE.probe(f"journalctl -u {name_unit} -n 15 --no-pager")
        for line in logs.splitlines()[-15:]:
            print(paint("    " + line, C.RED))
        raise StopError(f"{name_unit} is not running on KHARJ (state: {state.strip() or 'unknown'})")
    ok(f"{name_unit} is running on KHARJ")


def ufw_open_local(port, proto):
    rc, out = sh(["ufw", "status"])
    if rc == 0 and "Status: active" in out:
        sh(["ufw", "allow", f"{port}/{proto}"])
        ok(f"ufw: opened {port}/{proto} on IRAN")


def ufw_open_remote(port, proto):
    REMOTE.probe(f"ufw allow {port}/{proto} >/dev/null 2>&1 || true")


# ---------------------------------------------------------------- port wizard
def ask_port(label, explain, used, proto_list=("tcp",), where="IRAN", default_random=True, exclude=()):
    """Asks for a port; 'r' or Enter means a random free port. Explains the port first."""
    header(label)
    for line in explain:
        print(paint("    " + line, C.DIM))
    while True:
        raw = ask(f"Port on {where} (number, or r for random)", default="r")
        if raw.lower() == "r":
            for _ in range(20):
                p = pick_random_port(used, proto_list=proto_list, exclude=exclude)
                if where == "KHARJ" and REMOTE.mode == "ssh" and any(remote_port_used(p, pr) for pr in proto_list):
                    continue
                break
            ok(f"random free port: {p}")
            return p
        if raw.isdigit() and 1 <= int(raw) <= 65535:
            p = int(raw)
            if p in used or p in exclude:
                fail(f"port {p} is already used by another tunnel in this script")
                continue
            if where == "IRAN" and any(local_port_used(p, pr) for pr in proto_list):
                fail(f"port {p} is already in use on IRAN")
                continue
            if where == "KHARJ" and REMOTE.mode == "ssh":
                if any(remote_port_used(p, pr) for pr in proto_list):
                    fail(f"port {p} is already in use on KHARJ")
                    continue
            ok(f"port {p} is free on {where}")
            return p
        fail("not a valid port")


def ask_ram():
    header("Memory budget for pooled streams (reverse tunnels)")
    print(paint("    Presets (MB): " + ", ".join(str(x) for x in RAM_PRESETS), C.DIM))
    while True:
        raw = ask("Memory in MB", default="256")
        if raw.isdigit() and int(raw) in RAM_PRESETS:
            return int(raw)
        fail("choose one of the presets")


def ask_masquerade():
    header("Masquerade (what a probing censor sees when it connects to the port)")
    print(paint("    The server answers normal web requests with a real site, so it looks ordinary.", C.DIM))
    print("    1) bing      (https://www.bing.com)")
    print("    2) microsoft (https://www.microsoft.com)")
    print("    3) wikipedia (https://en.wikipedia.org)")
    print("    4) apple     (https://www.apple.com)")
    print("    5) custom URL (must return HTTP 200 from KHARJ)")
    print("    6) static text page (string type)")
    choice = ask("Choose", default="1")
    if choice in MASQ_PRESETS:
        _, url = MASQ_PRESETS[choice]
    elif choice == "5":
        url = ask("Full URL, e.g. https://example.com")
        if not url.startswith("https://"):
            raise StopError("custom URL must start with https://")
    elif choice == "6":
        return {"type": "string", "content": "<html><body>Welcome</body></html>", "sni": "localhost"}
    else:
        raise StopError("invalid masquerade choice")

    info(f"checking {url} from KHARJ (must return HTTP 200)...")
    if REMOTE.mode == "ssh":
        if not masq_test_remote(url):
            raise StopError(f"{url} did not return HTTP 200 from KHARJ")
    else:
        warn("manual mode: URL cannot be tested from here; check it on KHARJ yourself")
    ok(f"masquerade accepted: {url}")
    host = re.sub(r"^https?://", "", url).split("/")[0]
    return {"type": "proxy", "url": url, "sni": host}


# ---------------------------------------------------------------- dependencies (IRAN)
def ensure_local_deps(need_haproxy=False):
    header("Checking dependencies on IRAN")
    pkgs = {"iperf3": "iperf3", "openssl": "openssl", "curl": "curl"}
    if need_haproxy:
        pkgs["haproxy"] = "haproxy"
    missing = [p for cmd, p in pkgs.items() if shutil.which(cmd) is None]
    if paramiko is None:
        missing.append("python3-paramiko")
    if missing:
        info("installing with apt: " + " ".join(missing))
        rc, out = sh(["apt-get", "update", "-y"])
        if rc != 0:
            warn("apt-get update failed; the network may need a SOCKS5 proxy for apt")
        rc, out = sh(["apt-get", "install", "-y"] + missing)
        if rc != 0:
            raise StopError("apt install failed: " + out[-500:])
    ok("iperf3, openssl, curl present" + (", haproxy present" if need_haproxy else ""))
    if need_haproxy and shutil.which("haproxy") is None:
        raise StopError("haproxy is still missing")
    if paramiko is None:
        raise StopError("paramiko still missing")


def ensure_hysteria_local():
    if os.path.exists(HY_BIN):
        ok("hysteria binary present on IRAN")
        return
    info("installing hysteria on IRAN with the official script")
    rc, out = sh(["bash", "-c", "bash <(curl -fsSL https://get.hy2.sh/)"])
    if rc != 0:
        warn("download failed. A SOCKS5 proxy can be used for this download.")
        if ask_yes("Use a SOCKS5 proxy (host:port)?", default=True):
            proxy = ask("SOCKS5 proxy (host:port)", default="127.0.0.1:1080")
            rc, out = sh(["bash", "-c",
                          f"curl -fsSL --socks5-hostname {proxy} https://get.hy2.sh/ -o /root/hy2-install.sh && bash /root/hy2-install.sh"])
            if rc != 0:
                raise StopError("hysteria install through SOCKS5 failed: " + out[-400:])
        else:
            raise StopError("hysteria install failed: " + out[-400:])
    if not os.path.exists(HY_BIN):
        raise StopError(f"{HY_BIN} not found after install")
    ok("hysteria installed on IRAN")


def ensure_remote_deps(need_rbridge):
    if REMOTE.mode != "ssh":
        warn("manual mode: install these on KHARJ yourself if they are missing:")
    REMOTE.step("install iperf3, openssl, curl on KHARJ if missing",
                "command -v iperf3 >/dev/null && command -v openssl >/dev/null && command -v curl >/dev/null || "
                "(apt-get update -y && apt-get install -y iperf3 openssl curl)")
    REMOTE.step("install hysteria on KHARJ if missing",
                "command -v hysteria >/dev/null 2>&1 || bash -c 'bash <(curl -fsSL https://get.hy2.sh/)'")
    if need_rbridge:
        if REMOTE.mode == "ssh":
            rc, _ = REMOTE.probe("test -x " + RB_BIN)
            if rc != 0:
                path = ask("Path to the rbridge binary on THIS server (linux x86_64)", default="/root/tm/rbridge-linux-x86_64")
                if not os.path.isfile(path):
                    raise StopError(f"file not found: {path}")
                REMOTE.upload_binary("upload rbridge to KHARJ", path, RB_BIN)
            else:
                ok("rbridge binary present on KHARJ")
        else:
            REMOTE.step("rbridge binary present on KHARJ", f"test -x {RB_BIN} || echo 'copy rbridge to {RB_BIN} first'")
    if REMOTE.mode == "ssh":
        rc, out = REMOTE.probe("command -v systemd-run")
        if rc != 0:
            raise StopError("systemd-run not found on KHARJ")


# ---------------------------------------------------------------- tunnel builders
def new_secret_set():
    return {"password": random_secret(32), "obfs_password": random_secret(32)}


def make_cert_for(name, part, sni):
    cdir = os.path.join(BASE_DIR, "certs", f"{name}-{part}")
    cert, key = make_self_signed(cdir, sni)
    return {"cert_path": cert, "key_path": key, "pin": pin_from_cert(cert)}


def read_text(path):
    with open(path) as f:
        return f.read()


def build_haproxy(t):
    """Both mode only: haproxy on IRAN balances TCP between the direct and reverse paths."""
    n = t["name"]
    header("Load balancer (haproxy) on IRAN")
    ensure_local_deps(need_haproxy=True)
    backends = [
        ("direct", f"127.0.0.1:{t['parts']['direct']['pub']}", t.get("weight_direct", 1)),
        ("reverse", f"127.0.0.1:{t['parts']['reverse']['pub']}", t.get("weight_reverse", 1)),
    ]
    cfg = haproxy_cfg(n, t["public_port"], backends)
    path = f"{HAP_DIR}/{n}.cfg"
    write_local(path, cfg, mode=0o644)
    rc, out = sh(["haproxy", "-c", "-f", path])
    if rc != 0:
        raise StopError("haproxy config check failed: " + out[-400:])
    ok("haproxy config is valid")
    local_unit_write(f"tm-{n}-haproxy.service",
                     unit_file(f"tm {n} haproxy load balancer", f"/usr/sbin/haproxy -f {path}"))
    sh(["systemctl", "daemon-reload"])
    local_service("enable", f"tm-{n}-haproxy.service")
    local_service("restart", f"tm-{n}-haproxy.service")
    ok("haproxy started")
    ufw_open_local(t["public_port"], "tcp")



# ================================================================ stealth profiles
# Profiles (verified against the Hysteria 2 docs):
#   stealth-hop  : salamander obfs, UDP port hopping (server listen range + client hopInterval),
#                  masquerade, quic.disableStatelessReset. No domain needed.
#   max-stealth  : looks like a real HTTP/3 website: ACME (or an existing) certificate for a real
#                  domain, ECH (hides SNI), masquerade proxy, UDP 443 when free. No obfs, because
#                  the docs say obfs makes the server no longer a valid HTTP/3 server. No mimic,
#                  because fake TCP is not HTTP/3 either.
#                  NOTE: mTLS (tls.clientCA) is not used here because tls and acme cannot be combined.
#   tcp-lite     : TCP only (disableUDP), lazy client, gecko obfs, no UDP forwarding.

PROFILE_LABELS = {
    "stealth-hop": "1) stealth-hop : salamander + UDP port hopping + masquerade (no domain needed)",
    "max-stealth": "2) max-stealth : real HTTP/3 look: domain + ACME cert + ECH + masquerade, UDP 443 (needs a domain)",
    "tcp-lite": "3) tcp-lite    : TCP only, lazy client, gecko obfs, light (no UDP through tunnel)",
}
HOP_COUNT = 100

MIMIC_SH = r'''set -e
CODE=$(. /etc/os-release && echo "$VERSION_CODENAME")
if command -v mimic >/dev/null 2>&1; then echo "mimic already installed"; exit 0; fi
DIR=$(mktemp -d)
cd "$DIR"
URLS=$(curl -fsSL https://api.github.com/repos/hack3ric/mimic/releases/latest | grep browser_download_url | cut -d'"' -f4)
M=$(echo "$URLS" | grep "/${CODE}_mimic_[^/]*\.deb$" | head -1)
D=$(echo "$URLS" | grep "/${CODE}_mimic-dkms_[^/]*\.deb$" | head -1)
if [ -z "$M" ] || [ -z "$D" ]; then echo "no ${CODE} mimic packages in the latest release"; exit 1; fi
curl -fsSLO "$M"
curl -fsSLO "$D"
apt-get install -y ./*_mimic_*.deb ./*_mimic-dkms_*.deb
command -v mimic >/dev/null 2>&1 || { echo "mimic binary not found after install"; exit 1; }
'''


def ask_domain():
    header("Domain for max-stealth (ACME certificate)")
    print(paint("    The domain must have an A record pointing to the server that runs Hysteria.", C.DIM))
    print(paint("    For a DIRECT tunnel that is KHARJ; for a REVERSE tunnel that is IRAN.", C.DIM))
    while True:
        d = ask("Domain (e.g. vpn.example.com)").lower()
        if re.match(r"^(?=.{4,253}$)([a-z0-9-]+\.)+[a-z]{2,}$", d):
            return d
        fail("not a valid domain name")


def ask_email(domain):
    """Let's Encrypt rejects fake TLDs such as .fake, so the default uses the tunnel's own domain."""
    while True:
        e = ask("Email for the ACME account", default=f"admin@{domain}")
        if re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", e):
            return e
        fail("not a valid email")


def ask_ech_public():
    header("ECH decoy name (public name)")
    print(paint("    What is this?", C.YELLOW, C.BOLD))
    print("    With ECH, the real server name (SNI) is hidden inside an encrypted part of the")
    print("    handshake. The network only sees the outer name: this decoy name.")
    print("    So the decoy should look like a normal, popular site, and it is NOT your domain.")
    print()
    print(paint("    Examples (verify before use: this script cannot test from IRAN):", C.YELLOW))
    print("    1) download.windowsupdate.com   : Microsoft Windows Update CDN")
    print("    2) swcdn.apple.com              : Apple software download CDN")
    print("    3) dl.google.com                : Google software downloads")
    print("    4) Custom name (type it yourself, e.g. a popular site you checked)")
    print()
    print(paint("    Rules: no http:// or https://, no path, only letters, digits, dots and dashes.", C.DIM))
    print(paint("    Check it from the IRAN server first, e.g.:", C.DIM))
    print(paint("      curl -vI --max-time 10 https://NAME/", C.DIM))
    print(paint("    If the name is blocked or does not resolve from IRAN, ECH will not help.", C.DIM))
    presets = {"1": "download.windowsupdate.com", "2": "swcdn.apple.com", "3": "dl.google.com"}
    while True:
        c = ask("Choose 1-4 or type a name", default="1").strip().lower()
        if c in presets:
            n = presets[c]
            ok(f"decoy: {n}")
            return n
        if c == "4":
            c = ask("Your decoy name").strip().lower()
        if re.match(r"^(?=.{4,253}$)([a-z0-9-]+\.)+[a-z]{2,}$", c):
            return c
        fail("not a valid name. Use a plain domain like example.com")


def check_domain(domain, server_ip):
    try:
        _, _, ips = socket.gethostbyname_ex(domain)
    except OSError:
        raise StopError(f"{domain} does not resolve yet. Create the A record first.")
    if server_ip not in ips:
        raise StopError(f"{domain} resolves to {', '.join(ips)}, not {server_ip}")
    ok(f"{domain} points to {server_ip}")


def port80_busy(side):
    if side == "IRAN":
        return local_port_used(80, "tcp")
    return REMOTE.mode == "ssh" and remote_port_used(80, "tcp")


def port80_listeners(side):
    if side == "IRAN":
        _, out = sh(["ss", "-lntp"])
    else:
        _, out = REMOTE.probe("ss -lntp")
    return [line.strip() for line in out.splitlines() if re.search(r":80\s", line)]


def check_port80(side):
    """ACME needs port 80. If it is busy, asks the user to stop that service and waits
    until it is free. The script does not stop or fail."""
    if not port80_busy(side):
        ok(f"port 80 is free on {side} (ACME challenge)")
        return
    warn(f"port 80 is busy on {side}. ACME needs it for the challenge.")
    for line in port80_listeners(side):
        print(paint("    " + line, C.DIM))
    info(f"Stop the service that uses port 80 on {side}, for example: systemctl stop nginx", always=True)
    info("The script waits and continues by itself when the port is free. Press Ctrl+C to quit.", always=True)
    waited = 0
    while port80_busy(side):
        time.sleep(3)
        waited += 3
        if waited % 30 == 0:
            info(f"still waiting for port 80 on {side} ({waited} s)", always=True)
    ok(f"port 80 is free on {side}, continuing", always=True)


def remote_udp_ports():
    if REMOTE.mode != "ssh":
        return set()
    _, out = REMOTE.probe("ss -lun -H | awk '{print $4}'")
    ports = set()
    for line in out.splitlines():
        m = re.search(r":(\d+)$", line.strip())
        if m:
            ports.add(int(m.group(1)))
    return ports


def choose_hop_start(side, used):
    """A free block of HOP_COUNT consecutive UDP ports on the server side."""
    remote_busy = remote_udp_ports() if side == "KHARJ" else set()
    for _ in range(300):
        start = random.randint(20000, 60000 - HOP_COUNT)
        block = range(start, start + HOP_COUNT)
        if any(x in used or x in remote_busy for x in block):
            continue
        if side == "IRAN" and any(local_port_used(x, "udp") for x in block):
            continue
        return start
    raise StopError(f"no free block of {HOP_COUNT} UDP ports found on {side}")


def ensure_mimic_local():
    rc, out = sh(["bash", "-c", MIMIC_SH])
    if rc != 0:
        raise StopError("mimic install on IRAN failed: " + out[-400:])
    ok("mimic ready on IRAN")


def server_host_for(t, part):
    return t["kharej_ip"] if part == "direct" else t["iran_ip"]


def server_addr(host, p, prof):
    if prof == "stealth-hop":
        return f"{host}:{p['hy_port']}-{p['hop_end']}"
    return f"{host}:{p['hy_port']}"


# ---------------------------------------------------------------- Hysteria YAML (profile aware)
def hy_speedtest_client_yaml(p, server, prof):
    """Client config for 'hysteria speedtest': no forwarding listeners at all."""
    return hy_client_yaml(p, server, [], [], prof)


# ---------------------------------------------------------------- ECH and per-part client config
def prepare_ech_local(key_path, public_name):
    """Runs 'hysteria ech' on IRAN. Returns the ECH CONFIGS PEM block for clients."""
    os.makedirs(os.path.dirname(key_path), exist_ok=True)
    rc, out = sh([HY_BIN, "ech", "--public-name", public_name, "-o", key_path, "--overwrite"])
    if rc != 0:
        first = out.strip().splitlines()[0] if out.strip() else "unknown error"
        raise StopError("ECH key generation failed: " + first)
    os.chmod(key_path, 0o600)
    text = read_text(key_path)
    m = re.search(r"-----BEGIN ECH CONFIGS-----.*?-----END ECH CONFIGS-----", text, re.S)
    if not m:
        raise StopError("ECH CONFIGS block not found in the generated ECH file")
    return m.group(0) + "\n"


def max_stealth_port(side, used):
    """UDP 443 (the real HTTP/3 port) when it is free on SIDE, else None."""
    if 443 in used:
        return None
    busy = local_port_used(443, "udp") if side == "IRAN" else 443 in remote_udp_ports()
    if busy:
        warn(f"UDP 443 is busy on {side}; another port is needed")
        return None
    ok(f"UDP 443 is free on {side}, using it (standard HTTP/3 port)")
    return 443


HOP_ECHO_PY = """
import socket, sys, time
p, t = int(sys.argv[1]), float(sys.argv[2])
k = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
k.bind(("0.0.0.0", p))
k.settimeout(0.2)
print("READY", flush=True)
end = time.time() + t
while time.time() < end:
    try:
        data, addr = k.recvfrom(64)
        k.sendto(data, addr)
    except socket.timeout:
        pass
"""
HOP_PROBE_PY = (
    "import select,socket,sys,time\n"
    "h,s,n=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])\n"
    "socks={p:socket.socket(socket.AF_INET,socket.SOCK_DGRAM) for p in range(s,s+n)}\n"
    "got=set()\n"
    "for _ in range(3):\n"
    "    for p,k in socks.items():\n"
    "        if p not in got:\n"
    "            try: k.sendto(b'tm-hop-echo',(h,p))\n"
    "            except OSError: pass\n"
    "    end=time.time()+1.5\n"
    "    while time.time()<end and len(got)<n:\n"
    "        r,_,_=select.select([socks[p] for p in socks if p not in got],[],[],0.2)\n"
    "        for k in r:\n"
    "            try: k.recvfrom(64)\n"
    "            except OSError: continue\n"
    "            got.add(next(p for p,x in socks.items() if x is k))\n"
    "print('MISSING '+' '.join(str(p) for p in socks if p not in got))\n"
)


def hop_path_missing(iran_ip, start, count):
    """Two-way test of the hop block, built like Hysteria's own server-side range:
    a temporary nft redirect sends every port of the block to the first port, where an echo
    socket answers. KHARJ sends one packet from a fresh socket to every port and waits for
    the echo, so the redirect, conntrack, the IRAN firewall and the return path are all used.
    Returns the ports that got no echo, or None when the test cannot run."""
    if REMOTE.mode != "ssh" or REMOTE.probe("command -v python3")[0] != 0:
        return None
    if sh(["bash", "-c", "command -v nft"])[0] != 0:
        return None
    rules = (f"table inet tm_hoptest {{\n  chain pre {{ type nat hook prerouting priority dstnat; "
             f"udp dport {start}-{start + count - 1} redirect to :{start}; }}\n}}\n")
    rc, out = sh(["nft", "-f", "-"], input_text=rules)
    if rc != 0:
        return None
    echo = None
    try:
        echo = subprocess.Popen([sys.executable, "-c", HOP_ECHO_PY, str(start), "20"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if not echo.stdout.readline().startswith("READY"):
            return None
        _, probe = REMOTE.probe(f"python3 -c {shlex.quote(HOP_PROBE_PY)} {iran_ip} {start} {count}")
    finally:
        if echo is not None:
            echo.kill()
        sh(["nft", "delete", "table", "inet", "tm_hoptest"])
    lines = [x for x in probe.splitlines() if x.startswith("MISSING")]
    if not lines:
        return None
    return [int(x) for x in lines[0].split()[1:]]


def check_hop_block_iran(t, p):
    """Port hopping needs every port of the block to work in both directions (Hysteria docs)."""
    missing = hop_path_missing(t["iran_ip"], p["hy_port"], HOP_COUNT)
    if missing is None:
        warn("hop block test could not run (needs SSH, python3 on KHARJ and nft on IRAN)")
        return
    if not missing:
        ok(f"all {HOP_COUNT} hop ports on IRAN answer KHARJ (redirect and return path work)")
        return
    sample = ", ".join(str(x) for x in missing[:8])
    raise StopError(f"{len(missing)} of {HOP_COUNT} hop ports on IRAN got no echo back to KHARJ "
                    f"(e.g. {sample}); port hopping needs every port to work in both directions")


DIAG_SH = r"""echo "hysteria: $(/usr/local/bin/hysteria version 2>/dev/null | grep -i '^Version' | tr -s '\t ' ' ')"
echo "rbridge: $(/usr/local/bin/tm-rbridge --version 2>/dev/null | head -1)"
echo "redirect rules: nft=$(nft list ruleset 2>/dev/null | grep -ci redirect) iptables=$(iptables -t nat -S 2>/dev/null | grep -ci redirect)"
echo "udp: $(awk '/^Udp:/{if(!h){split($0,k);h=1}else{for(i=2;i<=NF;i++)if(k[i]~/Err|NoPorts/)printf "%s=%s ",k[i],$i}}' /proc/net/snmp)"
echo "buffers: rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null) wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null)"
echo "conntrack: $(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null)/$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)"
echo "ufw: $(ufw status 2>/dev/null | head -1)"
"""


def collect_diag():
    """Network facts from both servers, taken right after a failed test."""
    out = []
    for side in ("IRAN", "KHARJ"):
        _, text = side_run(side, DIAG_SH)
        for line in text.splitlines():
            if line.strip():
                out.append(f"{side}: {line.strip()}")
    return "\n".join(out)


def setup_profile_files(t, part):
    """max-stealth only: ECH key goes to the server, ECH config goes to the client."""
    p = t["parts"][part]
    if t["profile"] != "max-stealth" and "ech" not in p.get("extras", []):
        return
    n = t["name"]
    key_local = f"{BASE_DIR}/{n}/{part}-ech.pem"
    cfg_text = prepare_ech_local(key_local, t["ech_public"])
    if part == "direct":
        # server = KHARJ, client = IRAN
        p["ech_key_path"] = f"{REMOTE_BASE}/{n}/direct-ech.pem"
        REMOTE.write_file("write ECH key on KHARJ (server)", p["ech_key_path"], read_text(key_local), mode="600")
        cfg_local = f"{BASE_DIR}/{n}/direct-ech-config.pem"
        write_local(cfg_local, cfg_text, mode=0o644)
        p["ech_client_file"] = cfg_local
    else:
        # server = IRAN, client = KHARJ
        p["ech_key_path"] = key_local
        p["ech_client_file"] = f"{REMOTE_BASE}/{n}/reverse-ech-config.pem"
        REMOTE.write_file("write ECH config on KHARJ (client)", p["ech_client_file"], cfg_text, mode="644")
    ok(f"ECH prepared for {part}")


def part_client_yaml(t, part, speedtest=False):
    prof = t["profile"]
    p = t["parts"][part]
    if part == "direct":
        server = server_addr(t["kharej_ip"], p, prof)
        if speedtest:
            return hy_speedtest_client_yaml(p, server, prof)
        pub_listen = f"0.0.0.0:{t['public_port']}" if t["type"] == "direct" else f"127.0.0.1:{p['pub']}"
        tcp = [(pub_listen, f"127.0.0.1:{p['target']}"),
               (f"127.0.0.1:{p['iperf_local']}", f"127.0.0.1:{p['iperf_remote']}")]
        udp = []
        if prof != "tcp-lite":
            if t["type"] == "direct":
                udp.append((f"0.0.0.0:{t['public_port']}", f"127.0.0.1:{p['target']}"))
            udp.append((f"127.0.0.1:{p['iperf_local']}", f"127.0.0.1:{p['iperf_remote']}"))
        return hy_client_yaml(p, server, tcp, udp, prof)
    server = server_addr(t["iran_ip"], p, prof)
    if speedtest:
        return hy_speedtest_client_yaml(p, server, prof)
    tcp = [(f"127.0.0.1:{p['pool']}", f"127.0.0.1:{p['internal']}"),
           (f"127.0.0.1:{p['iperf_pool']}", f"127.0.0.1:{p['iperf_internal']}")]
    return hy_client_yaml(p, server, tcp, [], prof)


# ---------------------------------------------------------------- builders
def build_direct(t):
    p = t["parts"]["direct"]
    n = t["name"]
    prof = t["profile"]
    header("Direct tunnel: KHARJ = Hysteria server, IRAN = Hysteria client")
    ensure_remote_deps(need_rbridge=False)
    setup_profile_files(t, "direct")
    if prof == "max-stealth" and not p.get("cert_file"):
        REMOTE.step("prepare ACME folder on KHARJ", f"mkdir -p {p['acme_dir']}")

    cert_r = key_r = ""
    if prof != "max-stealth":
        cert_r = f"{REMOTE_BASE}/{n}/direct-cert.pem"
        key_r = f"{REMOTE_BASE}/{n}/direct-key.pem"
        REMOTE.write_file("write direct certificate on KHARJ", cert_r, read_text(p["cert_path"]), mode="644")
        REMOTE.write_file("write direct private key on KHARJ", key_r, read_text(p["key_path"]), mode="600")
    srv = hy_server_yaml(p, t["masq"], prof, cert_r, key_r)
    REMOTE.write_file("write direct server config on KHARJ", f"{REMOTE_BASE}/{n}/direct-server.yaml", srv)
    remote_unit_step(f"tm-{n}-direct-hy.service",
                     unit_file(f"tm {n} direct hysteria server",
                               f"{HY_BIN} server -c {REMOTE_BASE}/{n}/direct-server.yaml"),
                     "direct server unit")
    if prof == "stealth-hop":
        ufw_open_remote(f"{p['hy_port']}:{p['hop_end']}", "udp")
    else:
        ufw_open_remote(p["hy_port"], "udp")
    if prof == "max-stealth" and not p.get("cert_file"):
        ufw_open_remote(80, "tcp")

    header("Direct tunnel: IRAN client")
    write_local(f"{BASE_DIR}/{n}/direct-client.yaml", part_client_yaml(t, "direct"))
    local_unit_write(f"tm-{n}-direct-hy.service",
                     unit_file(f"tm {n} direct hysteria client",
                               f"{HY_BIN} client -c {BASE_DIR}/{n}/direct-client.yaml"))
    sh(["systemctl", "daemon-reload"])
    local_service("enable", f"tm-{n}-direct-hy.service")
    local_service("restart", f"tm-{n}-direct-hy.service")
    ok("IRAN direct client started")
    if t["type"] == "direct":
        ufw_open_local(t["public_port"], "tcp")
        if prof != "tcp-lite":
            ufw_open_local(t["public_port"], "udp")


def build_reverse(t):
    p = t["parts"]["reverse"]
    n = t["name"]
    prof = t["profile"]
    header("Reverse tunnel: IRAN = Hysteria server + rbridge, KHARJ = Hysteria client + rbridge")
    ensure_rbridge_iran()
    ensure_remote_deps(need_rbridge=True)
    ensure_hysteria_local()
    ensure_local_deps()
    setup_profile_files(t, "reverse")
    if prof == "stealth-hop":
        ufw_open_local(f"{p['hy_port']}:{p['hop_end']}", "udp")
        check_hop_block_iran(t, p)
    if prof == "max-stealth" and not p.get("cert_file"):
        os.makedirs(p["acme_dir"], exist_ok=True)

    # IRAN side
    cert_l = key_l = ""
    if prof != "max-stealth":
        cert_l = f"{BASE_DIR}/{n}/reverse-cert.pem"
        key_l = f"{BASE_DIR}/{n}/reverse-key.pem"
        write_local(cert_l, read_text(p["cert_path"]), mode=0o644)
        write_local(key_l, read_text(p["key_path"]), mode=0o600)
    public_listen = f"127.0.0.1:{p['pub']}" if t["type"] == "both" else f"0.0.0.0:{t['public_port']}"
    iran_rb = rbridge_yaml("iran", {**p, "iran_ip": t["iran_ip"]}, t["ram_mb"], [
        {"name": "main", "listen": public_listen, "internal": f"127.0.0.1:{p['internal']}"},
        {"name": "iperf", "listen": f"127.0.0.1:{p['iperf_pub']}", "internal": f"127.0.0.1:{p['iperf_internal']}"},
    ])
    srv = hy_server_yaml(p, t["masq"], prof, cert_l, key_l)
    write_local(f"{BASE_DIR}/{n}/reverse-server.yaml", srv)
    write_local(f"{BASE_DIR}/{n}/reverse-rbridge.yaml", iran_rb)
    local_unit_write(f"tm-{n}-reverse-hy.service",
                     unit_file(f"tm {n} reverse hysteria server",
                               f"{HY_BIN} server -c {BASE_DIR}/{n}/reverse-server.yaml"))
    local_unit_write(f"tm-{n}-reverse-rb.service",
                     unit_file(f"tm {n} reverse rbridge (iran)",
                               f"{RB_BIN} run --config {BASE_DIR}/{n}/reverse-rbridge.yaml"))
    sh(["systemctl", "daemon-reload"])
    local_service("enable", f"tm-{n}-reverse-hy.service")
    local_service("restart", f"tm-{n}-reverse-hy.service")
    local_service("enable", f"tm-{n}-reverse-rb.service")
    local_service("restart", f"tm-{n}-reverse-rb.service")
    ok("IRAN reverse server and rbridge started")
    if prof == "stealth-hop":
        ufw_open_local(f"{p['hy_port']}:{p['hop_end']}", "udp")
    else:
        ufw_open_local(p["hy_port"], "udp")
    if prof == "max-stealth" and not p.get("cert_file"):
        ufw_open_local(80, "tcp")
    if t["type"] == "reverse":
        ufw_open_local(t["public_port"], "tcp")

    # KHARJ side
    header("Reverse tunnel: KHARJ client")
    kh_rb = rbridge_yaml("kharej", {**p, "iran_ip": t["iran_ip"]}, t["ram_mb"], [
        {"name": "main", "pool_listen": f"127.0.0.1:{p['pool']}",
         "internal": f"127.0.0.1:{p['internal']}", "target": f"127.0.0.1:{t['target_port']}"},
        {"name": "iperf", "pool_listen": f"127.0.0.1:{p['iperf_pool']}",
         "internal": f"127.0.0.1:{p['iperf_internal']}", "target": f"127.0.0.1:{p['iperf_target']}"},
    ])
    REMOTE.write_file("write reverse client config (hysteria) on KHARJ",
                      f"{REMOTE_BASE}/{n}/reverse-client.yaml", part_client_yaml(t, "reverse"))
    REMOTE.write_file("write reverse rbridge config on KHARJ", f"{REMOTE_BASE}/{n}/reverse-rbridge.yaml", kh_rb)
    remote_unit_step(f"tm-{n}-reverse-hy.service",
                     unit_file(f"tm {n} reverse hysteria client",
                               f"{HY_BIN} client -c {REMOTE_BASE}/{n}/reverse-client.yaml"),
                     "reverse client unit")
    remote_unit_step(f"tm-{n}-reverse-rb.service",
                     unit_file(f"tm {n} reverse rbridge (kharej)",
                               f"{RB_BIN} run --config {REMOTE_BASE}/{n}/reverse-rbridge.yaml"),
                     "reverse rbridge unit")


# ---------------------------------------------------------------- details / tests
def show_details(t):
    print()
    print(paint(f"  Tunnel: {t['name']}  ({t['type']})  profile: {t.get('profile', '-')}", C.CYAN, C.BOLD))
    print(f"    IRAN ip   : {t['iran_ip']}")
    print(f"    KHARJ ip  : {t['kharej_ip']}")
    for side, dom in (t.get("domains") or {}).items():
        where = "KHARJ" if side == "direct" else "IRAN"
        print(f"    domain    : {dom}  (A record must point to {where}; ECH decoy: {t.get('ech_public', '-')})")
    print(f"    masquerade: {t['masq'].get('url', 'static text')}  sni={t['sni']}")
    if "public_port" in t:
        print(f"    public    : {t['public_port']}  ({PORT_HELP['public_port']})")
    print(f"    target    : {t['target_port']}  ({PORT_HELP['target_port']})")
    for part, p in t["parts"].items():
        print(paint(f"    [{part}]", C.YELLOW))
        if p.get("extras"):
            extra_txt = ", ".join(p["extras"])
            if "stats_port" in p:
                extra_txt += f" (stats on 127.0.0.1:{p['stats_port']})"
            print("      extras          " + extra_txt)
        if "hop_end" in p:
            print(f"      hop range       {p['hy_port']}-{p['hop_end']}  UDP block (server listen + client hop)")
        for k, v in p.items():
            if k in PORT_HELP and isinstance(v, int):
                print(f"      {k:<15} {v:<6} {PORT_HELP[k]}")
    print(paint("    Passwords and certificates are in " + tunnel_path(t["name"]) + " (mode 600)", C.DIM))


def speedtest_part(t, part):
    n = t["name"]
    header(f"Hysteria speed test ({part})")
    if part == "direct":
        path = f"{BASE_DIR}/{n}/direct-speedtest.yaml"
        write_local(path, part_client_yaml(t, "direct", speedtest=True))
        rc, out = sh([HY_BIN, "speedtest", "-c", path, "--duration", "10s"])
        print(paint("    " + out.replace("\n", "\n    "), C.WHITE))
        if rc != 0:
            raise StopError("speed test failed (is the KHARJ server running?)")
        ok("speed test done")
    else:
        REMOTE.write_file("write speed test config on KHARJ", f"{REMOTE_BASE}/{n}/reverse-speedtest.yaml",
                          part_client_yaml(t, "reverse", speedtest=True))
        REMOTE.step("run Hysteria speed test from KHARJ",
                    f"{HY_BIN} speedtest -c {REMOTE_BASE}/{n}/reverse-speedtest.yaml --duration 10s")


def iperf_test(t, part, proto):
    n = t["name"]
    if part == "direct":
        srv_port = t["parts"]["direct"]["iperf_remote"]
        cli_port = t["parts"]["direct"]["iperf_local"]
        if proto == "udp" and t["profile"] == "tcp-lite":
            warn("tcp-lite profile has no UDP through the tunnel. UDP test skipped.")
            return
    else:
        if proto == "udp":
            warn("UDP is not supported through rbridge (reverse). Skipped.")
            return
        srv_port = t["parts"]["reverse"]["iperf_target"]
        cli_port = t["parts"]["reverse"]["iperf_pub"]
    unit = f"tm-{n}-{part}-iperf"
    header(f"iperf3 {proto.upper()} test ({part})")
    if REMOTE.mode != "ssh":
        warn("manual mode: the iperf3 server must run on KHARJ; skipping automatic test")
        return
    REMOTE.probe(f"systemctl stop {unit} >/dev/null 2>&1; true")
    try:
        REMOTE.step("start temporary iperf3 server on KHARJ",
                    f"systemd-run --unit {unit} --collect iperf3 -s -B 127.0.0.1 -p {srv_port}")
        time.sleep(1)
        args = ["iperf3", "-c", "127.0.0.1", "-p", str(cli_port), "-t", "10", "-J"]
        if proto == "udp":
            args += ["-u", "-b", "50M"]
        rc, out = sh(args)
        if rc != 0:
            raise StopError("iperf3 client failed: " + out[-300:])
        data = json.loads(out)
        if proto == "tcp":
            bps = data["end"]["sum_received"]["bits_per_second"]
        else:
            bps = data["end"]["sum"]["bits_per_second"]
        ok(f"{proto.upper()} throughput: {bps / 1e6:.1f} Mbit/s")
    finally:
        REMOTE.probe(f"systemctl stop {unit} >/dev/null 2>&1; true")


# ---------------------------------------------------------------- create wizard
def create_tunnel():
    banner("Create a new tunnel")
    if REMOTE.mode == "none":
        warn("no connection to KHARJ yet. Connect first from the main menu.")
        return
    name = ask("Tunnel name (a-z, 0-9, dash, max 20)")
    if not NAME_RE.match(name):
        fail("invalid name")
        return
    if os.path.exists(tunnel_path(name)):
        fail("a tunnel with this name already exists")
        return
    ttype = ask_tunnel_type()
    if not ttype:
        fail("invalid choice")
        return

    header("Server addresses")
    iran_ip = ask("Public IP of IRAN (KHARJ must reach it)", default=detect_public_ip())
    kharej_ip = REMOTE.host if REMOTE.mode == "ssh" else ask("Public IP of KHARJ")
    ram_mb = ask_ram()
    profile = ask_profile()
    if not profile:
        fail("invalid profile")
        return
    masq = ask_masquerade()
    extras, settings = ask_extras(profile)

    t = {"name": name, "type": ttype, "profile": profile, "iran_ip": iran_ip, "kharej_ip": kharej_ip,
         "ram_mb": ram_mb, "masq": masq, "created": datetime.now().isoformat(timespec="seconds"),
         "parts": {}}
    if profile == "max-stealth":
        t["domains"] = ask_domains(ttype)
        t["email"] = ask_email(list(t["domains"].values())[0])
        t["ech_public"] = ask_ech_public()
        t["sni"] = masq["sni"]
    else:
        t["sni"] = masq["sni"]
    t["extras"] = extras
    if "ech" in extras and profile != "max-stealth":
        t["ech_public"] = ask_ech_public()
    used = used_ports_local()
    parts = ["direct", "reverse"] if ttype == "both" else [ttype]

    try:
        ensure_hysteria_local()
        ensure_local_deps(need_haproxy=(ttype == "both"))

        target = ask_target_port(name, [
            "The tunnel forwards user traffic to this port on KHARJ, which must already be listening.",
            "Example: 443 if xray or sing-box listens on 127.0.0.1:443 on KHARJ.",
        ])
        t["target_port"] = target
        for part in parts:
            t["parts"][part] = {}

        if ttype == "both":
            t["public_port"] = ask_port(
                "Public port on IRAN (haproxy frontend, users connect here)",
                ["Users connect to this TCP port on IRAN. haproxy spreads traffic over both paths.",
                 "It must not be used by another service on IRAN (checked now)."],
                used)
            used.add(t["public_port"])

        for part in parts:
            p = t["parts"][part]
            side = "KHARJ" if part == "direct" else "IRAN"
            p["password"] = random_secret(32)
            p["obfs_password"] = random_secret(32)
            p["rb_password"] = p["password"]
            p["sni"] = t["domains"][part] if profile == "max-stealth" else t["sni"]
            p["target"] = target
            apply_extra_secrets(p, extras, used, settings)
            if profile == "max-stealth":
                dom = t["domains"][part]
                p["domain"] = dom
                p["email"] = t["email"]
                p["pin"] = None
                found = resolve_certificate(side, dom)
                if found:
                    p["cert_file"], p["key_file"] = found
                else:
                    check_domain(dom, server_host_for(t, part))
                    check_port80(side)
                    p["acme_dir"] = acme_dir_for(part, dom)
            else:
                cert = make_cert_for(name, part, masq["sni"])
                p["cert_path"], p["key_path"], p["pin"] = cert["cert_path"], cert["key_path"], cert["pin"]

            if profile == "stealth-hop":
                start = choose_hop_start(side, used)
                p["hy_port"] = start
                p["hop_end"] = start + HOP_COUNT - 1
                used.update(range(start, start + HOP_COUNT))
                ok(f"{part}: hop block {start}-{start + HOP_COUNT - 1} UDP on {side}")
            else:
                port = max_stealth_port(side, used) if profile == "max-stealth" else None
                p["hy_port"] = port or ask_port(
                    f"Hysteria UDP port on {side} ({part} server)",
                    [f"UDP port where the Hysteria SERVER listens on {side}.",
                     "The other side connects to it. Must be free (checked now)."],
                    used, proto_list=("udp",), where=side)
            used.add(p["hy_port"])

            if part == "direct":
                if ttype == "direct":
                    t["public_port"] = ask_port(
                        "Public TCP port on IRAN (users connect here)",
                        ["Users connect to this TCP port on IRAN; traffic goes through Hysteria to KHARJ.",
                         "Must be free on IRAN (checked now)."],
                        used)
                    used.add(t["public_port"])
                p["iperf_local"] = pick_random_port(used)
                used.add(p["iperf_local"])
                p["iperf_remote"] = random_free_remote(used)
                used.add(p["iperf_remote"])
                if ttype == "both":
                    p["pub"] = pick_random_port(used)
                    used.add(p["pub"])
            else:
                if ttype == "reverse":
                    t["public_port"] = ask_port(
                        "Public TCP port on IRAN (users connect here)",
                        ["rbridge listens on this TCP port on IRAN; users connect here.",
                         "Must be free on IRAN (checked now)."],
                        used)
                    used.add(t["public_port"])
                p["internal"] = pick_random_port(used)
                used.add(p["internal"])
                p["pool"] = random_free_remote(used)
                used.add(p["pool"])
                p["iperf_pub"] = pick_random_port(used)
                used.add(p["iperf_pub"])
                p["iperf_internal"] = pick_random_port(used)
                used.add(p["iperf_internal"])
                p["iperf_pool"] = random_free_remote(used)
                used.add(p["iperf_pool"])
                p["iperf_target"] = random_free_remote(used)
                used.add(p["iperf_target"])
                if ttype == "both":
                    p["pub"] = pick_random_port(used)
                    used.add(p["pub"])

        header("Building the tunnel")
        if ttype in ("direct", "both"):
            build_direct(t)
        if ttype in ("reverse", "both"):
            build_reverse(t)
        if ttype == "both":
            build_haproxy(t)

        save_json(tunnel_path(name), t)
        header("Result")
        ok(f"tunnel '{name}' ({ttype}, {profile}) created")
        show_details(t)
    except StopError as e:
        fail(f"STOPPED: {e}")
        warn("the tunnel was not saved. Partly created units can be removed from Manage tunnels.")
        if ask_yes("Remove the partly created pieces now?", default=True):
            try:
                remove_tunnel(t)
            except StopError as e2:
                fail(str(e2))



# ================================================================ extra options (optional, chosen per tunnel)
# Keys below come from the Hysteria 2 server/client config docs.
#   sniguard : server tls.sniGuard = strict (needs a cert with SAN; self-signed certs get SAN automatically)
#   ech      : client tls.ech + server ech.keyPath, with a decoy public name (verify on your server)
#   userpass : server auth.type userpass, client auth "user:password"
#   masq_xff : masquerade.proxy.xForwarded = true
#   lazy_fast: client lazy = true and fastOpen = true
#   congestion: congestion.type bbr + bbrProfile (standard/conservative/aggressive)
#   stats    : trafficStats.listen (loopback) + trafficStats.secret
EXTRA_ITEMS = [
    ("sniguard", "SNI guard (strict): reject connections whose SNI does not match the certificate"),
    ("ech", "ECH: hide the real SNI behind a decoy name (keeps the self-signed certificate)"),
    ("userpass", "Multi-user auth (userpass): one generated user per tunnel for now"),
    ("masq_xff", "Masquerade X-Forwarded headers (proxy masquerade only)"),
    ("lazy_fast", "Lazy client + TCP Fast Open (saves one round trip; changes proxy error behavior)"),
    ("congestion", "Congestion control: BBR profile (standard, conservative or aggressive)"),
    ("stats", "Traffic stats API on loopback, with a generated secret"),
]
# Options that do not apply to max-stealth (ACME and ECH are already built in).
NOT_FOR_MAX = {"sniguard", "ech"}


def ask_extras(profile):
    """Shows only the options that fit the chosen profile. Returns (extras, settings)."""
    items = [(k, label) for k, label in EXTRA_ITEMS if not (profile == "max-stealth" and k in NOT_FOR_MAX)]
    header("Extra options (optional)")
    for n, (_key, label) in enumerate(items, 1):
        print(f"    {n}) {label}")
    print(paint("    Enter = none. Example: 1,3", C.DIM))
    while True:
        raw = ask("Choose extras", default="")
        nums = [x for x in re.split(r"[,\s]+", raw.strip()) if x]
        if all(x.isdigit() and 1 <= int(x) <= len(items) for x in nums):
            break
        fail(f"invalid choice. Use numbers from 1 to {len(items)}.")
    extras = [items[int(x) - 1][0] for x in nums]
    settings = {"users": {"tm_user": random_secret(24)}, "bbr": "standard"}
    if "congestion" in extras:
        b = ask("BBR profile (standard, conservative or aggressive)", default="standard").lower()
        if b not in ("standard", "conservative", "aggressive"):
            raise StopError("invalid BBR profile")
        settings["bbr"] = b
    if extras:
        ok("extras: " + ", ".join(extras))
    return extras, settings


def apply_extra_secrets(p, extras, used, settings):
    p["extras"] = extras
    p["users"] = dict(settings["users"]) if "userpass" in extras else {}
    p["bbr_profile"] = settings["bbr"]
    if "stats" in extras:
        port = pick_random_port(used)
        used.add(port)
        p["stats_port"] = port
        p["stats_secret"] = random_secret(32)


# ---------------------------------------------------------------- Hysteria YAML (profiles + extras)
def hy_server_yaml(p, masq, prof, cert, key):
    ex = p.get("extras", [])
    lines = []
    if prof == "stealth-hop":
        lines.append(f"listen: :{p['hy_port']}-{p['hop_end']}")
    else:
        lines.append(f"listen: :{p['hy_port']}")
    if prof == "max-stealth" and not p.get("cert_file"):
        lines += ["acme:", "  domains:", f"    - {p['domain']}", f"  email: {p['email']}", "  type: http"]
        if p.get("acme_dir"):
            lines.append(f"  dir: {p['acme_dir']}")
    else:
        cert_path = p.get("cert_file") or cert
        key_path = p.get("key_file") or key
        lines += ["tls:", f"  cert: {cert_path}", f"  key: {key_path}"]
        if "sniguard" in ex:
            lines.append("  sniGuard: strict")
    if "userpass" in ex:
        lines += ["auth:", "  type: userpass", "  userpass:"]
        for user, pw in p["users"].items():
            lines.append(f"    {user}: {yaml_str(pw)}")
    else:
        lines += ["auth:", "  type: password", "  password: " + yaml_str(p["password"])]
    if prof == "tcp-lite":
        lines += ["obfs:", "  type: gecko", "  gecko:", "    password: " + yaml_str(p["obfs_password"]),
                  "    minPacketSize: 512", "    maxPacketSize: 1200"]
    elif prof != "max-stealth":
        lines += ["obfs:", "  type: salamander", "  salamander:", "    password: " + yaml_str(p["obfs_password"])]
    lines += ["quic:", "  disableStatelessReset: true", "speedTest: true"]
    if "congestion" in ex:
        lines += ["congestion:", "  type: bbr", f"  bbrProfile: {p['bbr_profile']}"]
    if "stats" in ex:
        lines += ["trafficStats:", f"  listen: 127.0.0.1:{p['stats_port']}",
                  "  secret: " + yaml_str(p["stats_secret"])]
    if prof == "tcp-lite":
        lines.append("disableUDP: true")
    if prof == "max-stealth" or "ech" in ex:
        lines += ["ech:", f"  keyPath: {p['ech_key_path']}"]
    lines.append("masquerade:")
    if masq["type"] == "proxy":
        lines += ["  type: proxy", "  proxy:", f"    url: {masq['url']}", "    rewriteHost: true"]
        if "masq_xff" in ex:
            lines.append("    xForwarded: true")
    else:
        lines += ["  type: string", "  string:", "    content: " + yaml_str(masq["content"]),
                  "    headers:", "      content-type: text/plain", "    statusCode: 200"]
    return "\n".join(lines) + "\n"


def hy_client_yaml(p, server, tcp_fwd, udp_fwd, prof):
    ex = p.get("extras", [])
    if "userpass" in ex:
        user, pw = next(iter(p["users"].items()))
        auth = yaml_str(f"{user}:{pw}")
    else:
        auth = yaml_str(p["password"])
    lines = [f"server: {server}", "auth: " + auth, "tls:", f"  sni: {p['sni']}"]
    if prof != "max-stealth":
        lines += ["  insecure: true", f"  pinSHA256: {p['pin']}"]
    if prof == "max-stealth" or "ech" in ex:
        lines.append(f"  ech: {p['ech_client_file']}")
    if prof == "tcp-lite":
        lines += ["obfs:", "  type: gecko", "  gecko:", "    password: " + yaml_str(p["obfs_password"]),
                  "    minPacketSize: 512", "    maxPacketSize: 1200"]
    elif prof != "max-stealth":
        lines += ["obfs:", "  type: salamander", "  salamander:", "    password: " + yaml_str(p["obfs_password"])]
    if prof == "stealth-hop":
        lines += ["transport:", "  type: udp", "  udp:", "    hopInterval: 30s"]
    if prof == "tcp-lite" or "lazy_fast" in ex:
        lines.append("lazy: true")
    if "lazy_fast" in ex:
        lines.append("fastOpen: true")
    if "congestion" in ex:
        lines += ["congestion:", "  type: bbr", f"  bbrProfile: {p['bbr_profile']}"]
    if tcp_fwd:
        lines.append("tcpForwarding:")
        for listen, remote in tcp_fwd:
            lines += [f"  - listen: {listen}", f"    remote: {remote}"]
    if udp_fwd:
        lines.append("udpForwarding:")
        for listen, remote in udp_fwd:
            lines += [f"  - listen: {listen}", f"    remote: {remote}", "    timeout: 60s"]
    return "\n".join(lines) + "\n"


# ================================================================ profile menu
def ask_profile():
    """Returns the profile key (stealth-hop, max-stealth, tcp-lite) or ''."""
    header("Stealth profile")
    print("    1) stealth-hop : salamander + UDP port hopping + masquerade (no domain needed)")
    print("    2) max-stealth : real HTTP/3 look: domain + ACME cert + ECH + masquerade, UDP 443 (needs a domain)")
    print("    3) tcp-lite    : TCP only, lazy client, gecko obfs, light (no UDP through tunnel)")
    c = ask("Choose (1, 2 or 3)", default="1").strip()
    return {"1": "stealth-hop", "2": "max-stealth", "3": "tcp-lite"}.get(c, "")



# ================================================================ auto benchmark
# Builds each tunnel type temporarily, sends a few small requests through it,
# scores it, then removes it. max-stealth reuses one ACME folder per domain and
# that folder is never deleted by the benchmark.
import statistics

BENCH_DIR = "/var/lib/tm-bench"
BENCH_UNIT = "tm-bench-web"
PAYLOAD_SIZE = 51200          # 50 KB per request
REQUESTS = 5                  # requests per tunnel
BENCH_RAM_MB = 256
BENCH_MASQ = {"type": "proxy", "url": "https://www.bing.com", "sni": "www.bing.com"}


DOMAIN_EXAMPLE = {"KHARJ": "my.KHAREJ.com", "IRAN": "my.IRAN.com"}


def ask_domain_side(side):
    header(f"Domain whose A record points to {side}")
    while True:
        d = ask(f"Domain ({DOMAIN_EXAMPLE[side]})").lower()
        if re.match(r"^(?=.{4,253}$)([a-z0-9-]+\.)+[a-z]{2,}$", d):
            return d
        fail("not a valid domain name")


def ask_domains(ttype):
    """direct needs a domain for KHARJ, reverse needs one for IRAN. both needs two."""
    doms = {}
    if ttype in ("direct", "both"):
        doms["direct"] = ask_domain_side("KHARJ")
    if ttype in ("reverse", "both"):
        doms["reverse"] = ask_domain_side("IRAN")
    if ttype == "both" and doms["direct"] == doms["reverse"]:
        raise StopError("both needs two different domains: one for KHARJ and one for IRAN")
    return doms


def acme_dir_for(part, domain):
    """ACME folder for a domain on the server that runs Hysteria for this part.
    It is kept between tests and is never removed by remove_tunnel()."""
    base = REMOTE_BASE if part == "direct" else BASE_DIR
    return f"{base}/acme/{domain}"


def score_results(results):
    """results: list of (connect_ms, ttfb_ms, ok). Returns (score, median connect, median ttfb)."""
    good = [r for r in results if r[2]]
    if not good:
        return 0, None, None
    rate = len(good) / len(results)
    ct = statistics.median(r[0] for r in good)
    tt = statistics.median(r[1] for r in good)
    pts = 30 * rate
    pts += 30 if ct <= 40 else 24 if ct <= 100 else 16 if ct <= 200 else 8 if ct <= 400 else 0
    pts += 40 if tt <= 150 else 32 if tt <= 300 else 20 if tt <= 600 else 10 if tt <= 1000 else 0
    return round(pts), round(ct, 1), round(tt, 1)


def measure_tunnel(t):
    """Sends REQUESTS small downloads through the public port. Returns result tuples."""
    url = f"http://127.0.0.1:{t['public_port']}/payload.bin"
    sh(["curl", "-s", "-o", "/dev/null", "--max-time", "20", url])   # warm-up, not counted
    time.sleep(1)
    results = []
    for _ in range(REQUESTS):
        rc, out = sh(["curl", "-s", "-o", "/dev/null", "--max-time", "20",
                      "-w", "%{http_code} %{size_download} %{time_connect} %{time_starttransfer}", url])
        parts = out.split()
        if rc == 0 and len(parts) == 4 and parts[0] == "200" and int(parts[1]) == PAYLOAD_SIZE:
            results.append((float(parts[2]) * 1000, float(parts[3]) * 1000, True))
        else:
            results.append((None, None, False))
    return results


def bench_target_setup(used):
    """Starts a small web server on KHARJ (127.0.0.1 only) that serves a 50 KB file."""
    port = random_free_remote(used)
    used.add(port)
    REMOTE.step("check python3 on KHARJ", "command -v python3 >/dev/null")
    REMOTE.step("create the 50 KB test file on KHARJ",
                f"mkdir -p {BENCH_DIR} && head -c {PAYLOAD_SIZE} /dev/urandom > {BENCH_DIR}/payload.bin")
    REMOTE.step("start the temporary test web server on KHARJ",
                f"systemctl stop {BENCH_UNIT} >/dev/null 2>&1; systemd-run --unit {BENCH_UNIT} --collect "
                f"python3 -m http.server {port} --bind 127.0.0.1 --directory {BENCH_DIR}")
    return port


def bench_target_stop():
    REMOTE.probe(f"systemctl stop {BENCH_UNIT} >/dev/null 2>&1; true")


def bench_udp_port(side, used):
    for _ in range(100):
        p = pick_random_port(used, proto_list=("udp",))
        if side == "KHARJ" and p in remote_udp_ports():
            continue
        return p
    raise StopError(f"no free UDP port found on {side}")


def make_bench_tunnel(idx, ttype, profile, target, iran_ip, kharej_ip, domains, email, ech_public, used, reuse=None):
    """Builds the same record structure that create_tunnel() builds, with no questions."""
    name = f"bench-{idx}"
    t = {"name": name, "type": ttype, "profile": profile, "iran_ip": iran_ip, "kharej_ip": kharej_ip,
         "ram_mb": BENCH_RAM_MB, "masq": BENCH_MASQ, "created": datetime.now().isoformat(timespec="seconds"),
         "parts": {}, "extras": [], "target_port": target}
    if profile == "max-stealth":
        t["domains"], t["email"], t["ech_public"] = domains, email, ech_public
    else:
        t["sni"] = BENCH_MASQ["sni"]
    parts = ["direct", "reverse"] if ttype == "both" else [ttype]
    for part in parts:
        t["parts"][part] = {}
    if ttype == "both":
        t["public_port"] = pick_random_port(used)
        used.add(t["public_port"])

    for part in parts:
        p = t["parts"][part]
        side = "KHARJ" if part == "direct" else "IRAN"
        p.update({"password": random_secret(32), "obfs_password": random_secret(32),
                  "rb_password": None, "sni": domains.get(part, BENCH_MASQ["sni"]) if profile == "max-stealth" else BENCH_MASQ["sni"], "target": target,
                  "extras": [], "users": {}, "bbr_profile": "standard"})
        p["rb_password"] = p["password"]
        if profile == "max-stealth":
            dom = domains[part]
            p.update({"domain": dom, "email": email, "pin": None})
            if reuse and part in reuse:
                p.update({"cert_file": reuse[part][0], "key_file": reuse[part][1]})
            else:
                check_domain(dom, server_host_for(t, part))
                check_port80(side)
                p["acme_dir"] = acme_dir_for(part, dom)
        else:
            cert = make_cert_for(name, part, BENCH_MASQ["sni"])
            p.update({"cert_path": cert["cert_path"], "key_path": cert["key_path"], "pin": cert["pin"]})
        if profile == "stealth-hop":
            start = choose_hop_start(side, used)
            p["hy_port"], p["hop_end"] = start, start + HOP_COUNT - 1
            used.update(range(start, start + HOP_COUNT))
        else:
            port = max_stealth_port(side, used) if profile == "max-stealth" else None
            p["hy_port"] = port or bench_udp_port(side, used)
            used.add(p["hy_port"])
        if part == "direct":
            if ttype == "direct":
                t["public_port"] = pick_random_port(used)
                used.add(t["public_port"])
            p["iperf_local"] = pick_random_port(used)
            used.add(p["iperf_local"])
            p["iperf_remote"] = random_free_remote(used)
            used.add(p["iperf_remote"])
            if ttype == "both":
                p["pub"] = pick_random_port(used)
                used.add(p["pub"])
        else:
            if ttype == "reverse":
                t["public_port"] = pick_random_port(used)
                used.add(t["public_port"])
            for key in ("internal", "pool", "iperf_pub", "iperf_internal", "iperf_pool", "iperf_target"):
                p[key] = random_free_remote(used) if key in ("pool", "iperf_pool", "iperf_target") \
                    else pick_random_port(used)
                used.add(p[key])
            if ttype == "both":
                p["pub"] = pick_random_port(used)
                used.add(p["pub"])
    return t


def build_by_type(t):
    if t["type"] in ("direct", "both"):
        build_direct(t)
    if t["type"] in ("reverse", "both"):
        build_reverse(t)
    if t["type"] == "both":
        build_haproxy(t)


PROFILE_DESC = {
    "stealth-hop": "salamander obfs + UDP port hopping + masquerade",
    "max-stealth": "real HTTP/3 look: ACME certificate + ECH + masquerade, no obfs, UDP 443",
    "tcp-lite": "TCP only, lazy client, gecko obfs",
}
TYPE_DESC = {
    "direct": "Hysteria2: server on KHARJ, client on IRAN",
    "reverse": "Hysteria2 + rbridge: server on IRAN, client on KHARJ",
    "both": "direct + reverse behind haproxy (roundrobin)",
}
# max-stealth runs last so a failing mimic cannot disturb the other tests
BENCH_PLAN = [(tt, p) for p in ("stealth-hop", "tcp-lite", "max-stealth") for tt in ("direct", "reverse")]


def diagnose(text):
    """Short reasons taken from error and log text."""
    rules = [
        ("invalidContact", "ACME rejected the contact email"),
        ("failed to load BPF", "mimic could not load its BPF program (kernel / BTF)"),
        ("exit status 17", "mimic lock file exists in /run/mimic (stale lock or another mimic instance)"),
        ("no recent network activity", "Hysteria client could not reach the server (no UDP answer)"),
        ("no tunnel stream available", "rbridge got no stream from the other side"),
    ]
    reasons = [msg for key, msg in rules if key in text]
    return "; ".join(reasons)


def show_failure(reason, log):
    fail(f"failed: {reason}", always=True)
    for line in clean_log_lines(log, limit=2):
        print(paint("          " + line, C.DIM))


def clean_log_lines(log, limit=3):
    """A few important, de-duplicated log lines (FATAL first), without timestamps."""
    seen, found, current = set(), [], ""
    for raw in log.splitlines():
        line = raw.strip()
        m = re.match(r"^\[(IRAN|KHARJ)\] tm-bench-\d+-(.+)\.service$", line)
        if m:
            current = f"{m.group(1)} {m.group(2)}"
            continue
        if not re.search(r"FATAL|ERROR|Error|WARN|failed|Failed", line) or "Scheduled restart" in line:
            continue
        msg = line.split("]: ", 1)[1] if "]: " in line else line
        msg = re.sub(r"^\S+\s+(FATAL|ERROR|WARN|INFO)\s+", r"\1 ", msg)
        key = (current, re.sub(r"\d+", "#", msg))
        if key in seen:
            continue
        seen.add(key)
        prio = 0 if "FATAL" in msg else 1 if re.search(r"ERROR|Error", msg) else 2
        found.append((prio, f"{current}: {msg[:150]}"))
    found.sort(key=lambda x: x[0])
    return [text for _, text in found[:limit]]


def side_run(side, cmd):
    """Runs a shell command on IRAN or KHARJ and returns (rc, output)."""
    if side == "IRAN":
        return sh(["bash", "-c", cmd])
    return REMOTE.probe(cmd)


def bench_cleanup_units():
    """Stops and removes leftover tm-bench-* units and bench-N folders on both servers.
    These are all created by this script's benchmark, so removing them is safe."""
    cmd = (
        "for u in $(systemctl list-units --all --plain --no-legend 'tm-bench-*' | awk '{print $1}'); do "
        "systemctl disable --now \"$u\" >/dev/null 2>&1; done; "
        "rm -f /etc/systemd/system/tm-bench-*.service; "
        f"rm -rf {BASE_DIR}/bench-[0-9]*; "
        "systemctl daemon-reload; systemctl reset-failed >/dev/null 2>&1; true"
    )
    side_run("IRAN", cmd)
    REMOTE.step("remove leftover benchmark services on KHARJ", cmd)


def bench_cleanup_mimic():
    """Shows mimic processes and lock files left on a server and asks before touching them.
    mimic may belong to another service, so nothing is stopped or removed without a yes."""
    for side in ("IRAN", "KHARJ"):
        _, procs = side_run(side, "pgrep -a mimic")
        _, lock_out = side_run(side, "ls /run/mimic/*.lock 2>/dev/null")
        procs, locks = procs.strip(), lock_out.split()
        if not procs and not locks:
            continue
        header(f"mimic leftovers on {side}", always=True)
        for line in procs.splitlines() + locks:
            print(paint("    " + line, C.DIM))
        if procs:
            warn("mimic is still running. It may belong to another service.")
            if ask_yes(f"Stop all mimic processes on {side}?", default=False):
                side_run(side, "pkill mimic; sleep 1")
                ok(f"mimic stopped on {side}", always=True)
                _, procs = side_run(side, "pgrep -a mimic")
                procs = procs.strip()
        if locks and not procs:
            if ask_yes(f"No mimic process is running on {side}. Remove the lock files above?", default=True):
                side_run(side, "rm -f /run/mimic/*.lock")
                ok(f"lock files removed on {side}", always=True)
        elif locks:
            info("lock files are kept because mimic is still running.", always=True)


def stage(name):
    print(paint(f"        · {name}", C.DIM))


def run_benchmark():
    banner("Auto benchmark")
    if REMOTE.mode != "ssh":
        warn("The benchmark needs an SSH connection to KHARJ (not manual mode).")
        return
    info(f"{len(BENCH_PLAN)} tests: direct, reverse x stealth-hop, tcp-lite, max-stealth. "
         f"{REQUESTS} requests of {PAYLOAD_SIZE // 1024} KB each.")
    if not ask_yes("Start the benchmark?", default=False):
        return

    domains = {"direct": ask_domain_side("KHARJ"), "reverse": ask_domain_side("IRAN")}
    if domains["direct"] == domains["reverse"]:
        raise StopError("the two domains must be different (one for KHARJ, one for IRAN)")
    email = ask_email(domains["direct"])
    ech_public = ask_ech_public()
    iran_ip = ask("Public IP of IRAN (KHARJ must reach it)", default=detect_public_ip())
    kharej_ip = REMOTE.host

    reuse = {}
    for part in ("direct", "reverse"):
        found = resolve_certificate("KHARJ" if part == "direct" else "IRAN", domains[part])
        if found:
            reuse[part] = found

    set_quiet(True)
    try:
        bench_cleanup_units()
    finally:
        set_quiet(False)
    bench_cleanup_mimic()

    results = []
    set_quiet(True)
    try:
        print()
        print(paint("  Preparing servers ...", C.DIM))
        ensure_rbridge_iran()
        ensure_hysteria_local()
        ensure_local_deps(need_haproxy=True)
        ensure_remote_deps(need_rbridge=True)

        used = used_ports_local()
        try:
            target = bench_target_setup(used)
            for idx, (ttype, profile) in enumerate(BENCH_PLAN, 1):
                label = f"{ttype}/{profile}"
                print()
                print(paint(f"  [{idx}/{len(BENCH_PLAN)}] {ttype.upper()} · {profile}", C.MAGENTA, C.BOLD))
                print(paint(f"        {TYPE_DESC[ttype]}", C.DIM))
                print(paint(f"        {PROFILE_DESC[profile]}", C.DIM))
                t = None
                try:
                    stage("building tunnel")
                    t = make_bench_tunnel(idx, ttype, profile, target, iran_ip, kharej_ip,
                                          domains, email, ech_public, used, reuse)
                    build_by_type(t)
                    time.sleep(5)
                    stage("checking services")
                    dead = dead_units(t)
                    if dead:
                        raise StopError("service stopped after start: " + "; ".join(dead))
                    remember_issued_cert(t, reuse)
                    stage(f"sending {REQUESTS} requests")
                    res = measure_tunnel(t)
                    sc, ct, tt = score_results(res)
                    log, reason, diag = "", "", ""
                    if sc == 0:
                        log = unit_log_tail(t)
                        diag = collect_diag()
                        reason = diagnose(log) or "no successful request"
                        show_failure(reason, log)
                    else:
                        ok(f"score {sc} · connect {ct} ms · first byte {tt} ms", always=True)
                    results.append({"label": label, "score": sc, "connect_ms": ct, "first_byte_ms": tt,
                                    "ok": sum(1 for r in res if r[2]), "error": "", "reason": reason, "log": log, "diag": diag})
                except StopError as e:
                    log = unit_log_tail(t) if t is not None else ""
                    diag = collect_diag() if t is not None else ""
                    hint = diagnose(f"{e}\n{log}")
                    reason = f"{e} ({hint})" if hint else str(e)
                    show_failure(reason, log)
                    results.append({"label": label, "score": 0, "connect_ms": None,
                                    "first_byte_ms": None, "ok": 0, "error": str(e), "reason": reason, "log": log, "diag": diag})
                finally:
                    if t is not None:
                        stage("removing tunnel")
                        try:
                            remove_tunnel(t)
                        except StopError as e:
                            warn(f"cleanup of {label} reported: {e}")
        finally:
            bench_target_stop()
    finally:
        set_quiet(False)

    show_bench_results(results)


def show_bench_results(results):
    os.makedirs(f"{BASE_DIR}/bench", exist_ok=True)
    path = f"{BASE_DIR}/bench/result-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
    save_json(path, results)
    failed = [r for r in results if r["score"] == 0]
    if failed:
        header("Why tests failed")
        for r in failed:
            print(paint(f"    {r['label']}: {r.get('reason') or 'no successful request'}", C.RED))
            for line in clean_log_lines(r.get("log", "")):
                print(paint("      " + line, C.DIM))
            for line in (r.get("diag") or "").splitlines():
                print(paint("      " + line, C.DIM))
    print()
    info(f"full details saved to {path}")
    info(f"Score = 30 success rate + 30 connect time + 40 first-byte time ({REQUESTS} x {PAYLOAD_SIZE // 1024} KB).")
    header("Results (highest score first)")
    print(paint(f"    {'#':<3}{'test':<26}{'ok':<6}{'connect ms':<12}{'first byte ms':<15}{'score':<6}", C.BOLD))
    for i, r in enumerate(sorted(results, key=lambda x: x["score"], reverse=True), 1):
        color = C.GREEN if r["score"] >= 70 else C.YELLOW if r["score"] >= 40 else C.RED
        ct = "-" if r["connect_ms"] is None else str(r["connect_ms"])
        tt = "-" if r["first_byte_ms"] is None else str(r["first_byte_ms"])
        name = r["label"].replace("/", " · ")
        print(paint(f"    {i:<3}{name:<26}{str(r['ok']) + '/' + str(REQUESTS):<6}{ct:<12}{tt:<15}{r['score']:<6}", color))


# ---------------------------------------------------------------- remote checks / removal
def remote_port_used(port, proto="tcp"):
    flag = "-ltn" if proto == "tcp" else "-lun"
    rc, out = REMOTE.probe(f"ss {flag} | awk '{{print $4}}' | grep -q ':{port}$' && echo USED || echo FREE")
    return out.strip().endswith("USED")


def remove_tunnel(t):
    """Stops and deletes every unit and file this tunnel created. Best effort on both sides."""
    n = t["name"]
    header(f"Removing tunnel '{n}'")
    for unit in [f"tm-{n}-direct-hy.service", f"tm-{n}-reverse-hy.service",
                 f"tm-{n}-reverse-rb.service", f"tm-{n}-haproxy.service"]:
        sh(["systemctl", "disable", "--now", unit])
        p = f"/etc/systemd/system/{unit}"
        if os.path.exists(p):
            os.remove(p)
    shutil.rmtree(f"{BASE_DIR}/{n}", ignore_errors=True)
    shutil.rmtree(f"{BASE_DIR}/certs/{n}-direct", ignore_errors=True)
    shutil.rmtree(f"{BASE_DIR}/certs/{n}-reverse", ignore_errors=True)
    if os.path.exists(f"{HAP_DIR}/{n}.cfg"):
        os.remove(f"{HAP_DIR}/{n}.cfg")
    if os.path.exists(tunnel_path(n)):
        os.remove(tunnel_path(n))
    ok("IRAN side removed")
    sh(["systemctl", "daemon-reload"])
    if REMOTE.mode in ("ssh", "manual"):
        REMOTE.step(f"remove tunnel '{n}' units and files on KHARJ",
                    f"for u in /etc/systemd/system/tm-{n}-*.service; do "
                    f"[ -e \"$u\" ] || continue; systemctl disable --now \"$(basename \"$u\")\" 2>/dev/null; rm -f \"$u\"; done; "
                    f"rm -rf {REMOTE_BASE}/{n}; systemctl daemon-reload")


# ---------------------------------------------------------------- create wizard
def ask_target_port(name, explain):
    header("Target port on KHARJ")
    for line in explain:
        print(paint("    " + line, C.DIM))
    while True:
        raw = ask("Port of the real service on KHARJ (e.g. xray/sing-box/nginx on 127.0.0.1)")
        if raw.isdigit() and 1 <= int(raw) <= 65535:
            return int(raw)
        fail("not a valid port")


def ask_tunnel_type():
    header("Tunnel type")
    print("    1) direct  : Hysteria server on KHARJ, client on IRAN")
    print("    2) reverse : Hysteria server on IRAN + rbridge, client on KHARJ (use when KHARJ can reach IRAN only)")
    print("    3) both    : direct + reverse behind a haproxy load balancer on IRAN")
    c = ask("Choose", default="1")
    return {"1": "direct", "2": "reverse", "3": "both"}.get(c, "")


def random_free_remote(used):
    for _ in range(30):
        p = pick_random_port(used)
        if REMOTE.mode != "ssh" or not remote_port_used(p):
            return p
    raise StopError("could not find a free port on KHARJ")


def detect_public_ip():
    rc, out = sh(["curl", "-s", "-m", "8", "https://api.ipify.org"])
    return out.strip() if rc == 0 and re.match(r"^\d+\.\d+\.\d+\.\d+$", out.strip()) else ""


# ---------------------------------------------------------------- details / status
PORT_HELP = {
    "hy_port": "Hysteria UDP port (server side)",
    "public_port": "Public TCP port on IRAN (users)",
    "target_port": "Real service port on KHARJ",
    "pub": "Loopback TCP port on IRAN used by haproxy",
    "iperf_local": "Loopback TCP/UDP port on IRAN for iperf3 tests (direct)",
    "iperf_remote": "Loopback port on KHARJ where iperf3 server runs (direct)",
    "internal": "Loopback TCP port on IRAN where Hysteria dials for rbridge (reverse)",
    "pool": "Loopback TCP port on KHARJ where Hysteria client listens for rbridge (reverse)",
    "iperf_pub": "Loopback port on IRAN, rbridge public side for iperf (reverse)",
    "iperf_internal": "Loopback port on IRAN, internal side for iperf (reverse)",
    "iperf_pool": "Loopback port on KHARJ, pool side for iperf (reverse)",
    "iperf_target": "Loopback port on KHARJ where iperf3 server runs (reverse)",
}


def unit_state_local(unit):
    rc, out = sh(["systemctl", "is-active", unit])
    return out.strip()


def unit_state_remote(unit):
    if REMOTE.mode != "ssh":
        return "manual"
    rc, out = REMOTE.probe(f"systemctl is-active {unit}")
    return out.strip() or "unknown"


def unit_names(t):
    n = t["name"]
    names = []
    if "direct" in t["parts"]:
        names.append(("IRAN", f"tm-{n}-direct-hy.service"))
        names.append(("KHARJ", f"tm-{n}-direct-hy.service"))
    if "reverse" in t["parts"]:
        names += [("IRAN", f"tm-{n}-reverse-hy.service"), ("IRAN", f"tm-{n}-reverse-rb.service")]
        names += [("KHARJ", f"tm-{n}-reverse-hy.service"), ("KHARJ", f"tm-{n}-reverse-rb.service")]
    if t["type"] == "both":
        names.append(("IRAN", f"tm-{n}-haproxy.service"))
    return names


def show_status(t):
    print()
    for where, unit in unit_names(t):
        state = unit_state_local(unit) if where == "IRAN" else unit_state_remote(unit)
        color = C.GREEN if state == "active" else C.RED
        print(f"    {where:<6} {unit:<34} " + paint(state, color, C.BOLD))


# ---------------------------------------------------------------- speed tests
def speedtest_menu():
    banner("Speed test")
    items = list_tunnels()
    if not items:
        warn("no tunnels yet")
        return pause()
    t = pick_tunnel(items)
    if not t:
        return
    parts = list(t["parts"].keys())
    for part in parts:
        try:
            speedtest_part(t, part)
        except StopError as e:
            fail(f"STOPPED: {e}")
        try:
            iperf_test(t, part, "tcp")
            iperf_test(t, part, "udp")
        except StopError as e:
            fail(f"STOPPED: {e}")
    pause()


# ---------------------------------------------------------------- manage
def pick_tunnel(items):
    for i, t in enumerate(items, 1):
        print(f"    {i}) {t['name']:<20} {t['type']:<8} public={t.get('public_port', '-')}")
    raw = ask("Select number (Enter to cancel)", default="")
    if not raw.isdigit() or not (1 <= int(raw) <= len(items)):
        return None
    return items[int(raw) - 1]


def restart_tunnel(t, action):
    for where, unit in unit_names(t):
        if where == "IRAN":
            sh(["systemctl", action, unit])
        elif REMOTE.mode == "ssh":
            REMOTE.step(f"{action} {unit} on KHARJ", f"systemctl {action} {unit}")
    ok(f"{action} done")


def change_weights(t):
    if t["type"] != "both":
        warn("weights apply only to 'both' tunnels")
        return
    wd = ask("Weight for direct", default=str(t.get("weight_direct", 1)))
    wr = ask("Weight for reverse", default=str(t.get("weight_reverse", 1)))
    if not (wd.isdigit() and wr.isdigit()):
        fail("weights must be numbers")
        return
    t["weight_direct"], t["weight_reverse"] = int(wd), int(wr)
    write_local(f"{HAP_DIR}/{t['name']}.cfg", haproxy_cfg(t["name"], t["public_port"], [
        ("direct", f"127.0.0.1:{t['parts']['direct']['pub']}", t["weight_direct"]),
        ("reverse", f"127.0.0.1:{t['parts']['reverse']['pub']}", t["weight_reverse"]),
    ]), mode=0o644)
    rc, out = sh(["haproxy", "-c", "-f", f"{HAP_DIR}/{t['name']}.cfg"])
    if rc != 0:
        fail("haproxy config check failed: " + out[-300:])
        return
    sh(["systemctl", "restart", f"tm-{t['name']}-haproxy.service"])
    save_json(tunnel_path(t["name"]), t)
    ok("weights updated")


def manage_menu():
    while True:
        banner("Manage tunnels")
        items = list_tunnels()
        if not items:
            warn("no tunnels yet. Use 'Create a new tunnel' first.")
            return pause()
        print("  Tunnels:")
        t = pick_tunnel(items)
        if not t:
            return
        while True:
            banner(f"Tunnel: {t['name']} ({t['type']})")
            show_details(t)
            show_status(t)
            print()
            print("    1) Show status again")
            print("    2) Start")
            print("    3) Stop")
            print("    4) Restart")
            print("    5) Change haproxy weights (both only)")
            print("    6) Delete this tunnel")
            print("    0) Back")
            c = ask("Choose", default="0")
            if c == "0":
                break
            try:
                if c == "2":
                    restart_tunnel(t, "start")
                elif c == "3":
                    restart_tunnel(t, "stop")
                elif c == "4":
                    restart_tunnel(t, "restart")
                elif c == "5":
                    change_weights(t)
                elif c == "6":
                    if ask(f"Type the tunnel name '{t['name']}' to confirm deletion") == t["name"]:
                        remove_tunnel(t)
                        ok("deleted")
                        return pause()
                    warn("name did not match; nothing deleted")
            except StopError as e:
                fail(f"STOPPED: {e}")
            pause()


# ---------------------------------------------------------------- connection screen
def connect_menu():
    banner("Connect to KHARJ")
    print("    The SSH password is asked each run and is never saved.")
    print("    If SSH fails, you can continue in MANUAL mode: the menu shows the")
    print("    commands for KHARJ one by one and you run them in your KHARJ terminal.")
    print()
    while True:
        host = ask("KHARJ host (IP)")
        port = ask("SSH port", default="22")
        user = ask("SSH user", default="root")
        pw = getpass.getpass(paint("  ? ", C.CYAN, C.BOLD) + "SSH password (hidden): ")
        if paramiko is None:
            fail("paramiko is missing")
            break
        try:
            REMOTE.connect_ssh(host, int(port), user, pw)
            del pw
            return
        except StopError as e:
            fail(str(e))
            del pw
            print()
            print("    1) Try again")
            print("    2) Manual mode (run KHARJ commands yourself)")
            if ask("Choose", default="2") == "1":
                continue
            REMOTE.set_manual()
            warn("MANUAL mode: the menu will print each KHARJ step for you to run.")
            return
    REMOTE.set_manual()
    warn("MANUAL mode.")


def deps_menu():
    banner("Install / check dependencies")
    try:
        ensure_local_deps(need_haproxy=False)
        ensure_hysteria_local()
        ok("IRAN dependencies are ready")
    except StopError as e:
        fail(f"STOPPED: {e}")
    pause()


def status_menu():
    banner("Status of all tunnels")
    items = list_tunnels()
    if not items:
        warn("no tunnels yet")
    for t in items:
        print(paint(f"  {t['name']} ({t['type']})", C.CYAN, C.BOLD))
        show_status(t)
        print()
    pause()


def main_menu():
    while True:
        mode = {"ssh": paint("SSH", C.GREEN, C.BOLD), "manual": paint("MANUAL", C.YELLOW, C.BOLD)}.get(
            REMOTE.mode, paint("none", C.RED))
        banner(f"Main menu   KHARJ mode: {mode}   script v{VERSION}")
        print("    1) Create a new tunnel")
        print("    2) Manage tunnels")
        print("    3) Speed test (Hysteria + iperf3)")
        print("    4) Status")
        print("    5) Install / check dependencies on IRAN")
        print("    6) Auto benchmark (tests all tunnel types)")
        print("    7) Reconnect to KHARJ")
        print("    0) Exit")
        c = ask("Choose", default="0")
        try:
            if c == "1":
                create_tunnel()
                pause()
            elif c == "2":
                manage_menu()
            elif c == "3":
                speedtest_menu()
            elif c == "4":
                status_menu()
            elif c == "5":
                deps_menu()
            elif c == "6":
                run_benchmark()
                pause()
            elif c == "7":
                REMOTE.close()
                connect_menu()
            elif c == "0":
                REMOTE.close()
                print(paint("\n  bye\n", C.CYAN))
                return
        except StopError as e:
            fail(f"STOPPED: {e}")
            pause()
        except KeyboardInterrupt:
            print()
            return


def main():
    if os.geteuid() != 0:
        print(paint("Run this script as root on the IRAN server.", C.RED, C.BOLD))
        sys.exit(1)
    if paramiko is None:
        banner("Missing dependency")
        info("installing python3-paramiko with apt...")
        sh(["apt-get", "update", "-y"])
        rc, out = sh(["apt-get", "install", "-y", "python3-paramiko"])
        if rc != 0:
            warn("could not install paramiko; continuing in MANUAL mode")
        else:
            os.execv(sys.executable, [sys.executable] + sys.argv)
    for d in (BASE_DIR, TUNNEL_DIR, HAP_DIR, BACKUP_DIR):
        os.makedirs(d, exist_ok=True)
    os.chmod(BASE_DIR, 0o700)
    connect_menu()
    main_menu()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(paint("\n  interrupted", C.YELLOW))
