#!/usr/bin/env bash
# ============================================================
# kcptun-rs Auto Optimizer V4.0
# Baseline + Greedy Multi-Stage Tuner
# Ubuntu 22/24
#
# Changes vs V3.1:
#  - SSH password no longer passed as a CLI arg (was visible to any
#    local user via `ps`); now exported as SSHPASS and read with
#    `sshpass -e`.
#  - Default cipher changed from `xor` (insecure, known-plaintext
#    attack) to `aes-128` for both the sweep and the final
#    ready-to-use commands. Override with CRYPT=... if you know
#    what you're doing; insecure choices now print a loud warning.
#  - Pre-flight UDP reachability check: one throwaway measurement
#    before the full sweep, so a blocked KCP port fails fast with a
#    diagnosis instead of silently grinding through ~30 dead runs.
#  - Fixed a SOCKBUF sweep bug (near-duplicate 16777216/16777217
#    entries); added a larger option for high-BDP links.
#  - Optional FEC (datashard/parityshard) sweep stage, gated behind
#    FEC_SWEEP=1 so default runtime is unchanged.
#  - Optional -P/--parallel iperf streams via STREAMS=N.
#  - Progress counters per stage, wall-clock timer, and a
#    JSON+text report saved to disk (results no longer live only in
#    scrollback).
# ============================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

info(){ echo -e "${BLUE}[INFO]${NC} $*" >&2; }
ok(){   echo -e "${GREEN}[OK]${NC} $*" >&2; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
die(){  echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step(){ echo -e "\n${MAGENTA}${BOLD}==> $*${NC}" >&2; }
prog(){ echo -e "  ${CYAN}-> $*${NC}" >&2; }

need_root(){ [[ $EUID -eq 0 ]] || die "Run this script as root."; }

WORKDIR="/opt/kcptun-rs"
BIN_DIR="$WORKDIR/bin"
REMOTE_DIR="/opt/kcptun-rs"
REMOTE_BIN_DIR="$REMOTE_DIR/bin"
STATE_DIR="/run/kcptun-rs-v4"
REPORT_DIR="$WORKDIR/reports"
KCP_PORT_DEFAULT=29900
KEY="kcptun-rs-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)"
TEST_DURATION="${TEST_DURATION:-10}"
WARMUP_DURATION="${WARMUP_DURATION:-2}"
RUNS_PER_PROFILE="${RUNS_PER_PROFILE:-1}"
STREAMS="${STREAMS:-1}"          # iperf3 -P parallel streams per measurement
FEC_SWEEP="${FEC_SWEEP:-0}"      # 1 = run the optional FEC stage
CONN_SWEEP="${CONN_SWEEP:-0}"    # 1 = run the optional --conn stage
DEBUG="${DEBUG:-0}"
SCRIPT_START_TS=$(date +%s)

# ---- Overrides from environment (skip sweep when set) ----
OVERRIDE_MODE="${MODE:-}"
OVERRIDE_MTU="${MTU:-}"
OVERRIDE_WIN="${WIN:-}"          # format: "snd/rcv"
OVERRIDE_SOCKBUF="${SOCKBUF:-}"
OVERRIDE_NOCOMP="${NOCOMP:-}"    # on|off
OVERRIDE_SMUXVER="${SMUXVER:-}"  # 1|2
OVERRIDE_FEC="${FEC:-}"          # format: "datashard/parityshard"
OVERRIDE_CONN="${CONN:-}"        # integer

if [[ -n "$OVERRIDE_WIN" && "$OVERRIDE_WIN" != */* ]]; then
  echo "[ERROR] WIN must be in format snd/rcv (e.g. 1024/1024)" >&2
  exit 1
fi
if [[ -n "$OVERRIDE_NOCOMP" && "$OVERRIDE_NOCOMP" != "on" && "$OVERRIDE_NOCOMP" != "off" ]]; then
  echo "[ERROR] NOCOMP must be on or off" >&2
  exit 1
fi
if [[ -n "$OVERRIDE_SMUXVER" && "$OVERRIDE_SMUXVER" != "1" && "$OVERRIDE_SMUXVER" != "2" ]]; then
  echo "[ERROR] SMUXVER must be 1 or 2" >&2
  exit 1
fi
if [[ -n "$OVERRIDE_FEC" && "$OVERRIDE_FEC" != */* ]]; then
  echo "[ERROR] FEC must be in format datashard/parityshard (e.g. 10/3)" >&2
  exit 1
fi
if [[ -n "$OVERRIDE_CONN" && ! "$OVERRIDE_CONN" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] CONN must be a positive integer" >&2
  exit 1
fi

# Cipher used for both the sweep and the final ready-to-use commands.
# aes-128 is AES-NI accelerated on virtually every modern VPS CPU and is
# not a meaningfully slower choice than xor on such hardware, so there is
# no good reason to default to an insecure cipher just for a benchmark.
CRYPT="${CRYPT:-aes-128}"
case "$CRYPT" in
  xor|none)
    warn "CRYPT=$CRYPT provides no real confidentiality (xor is broken under known-plaintext, none is unencrypted). Only use this for isolated speed testing, never for the production command printed at the end."
    ;;
esac
CRYPT_FIXED="$CRYPT"   # kept for readability in the code below

MODES=("fast" "fast2" "fast3" "normal" "manual")

MTUS=(1500 1450 1400 1350 1300 1250 1200 1150)

WINDOWS=(
  "512|512"
  "1024|1024"
  "2048|2048"
  "1024|2048"
  "2048|1024"
  "4096|4096"
)

# NOTE: V3.1 had both 16777216 and 16777217 here, one byte apart -- almost
# certainly a typo that wasted a whole measurement on a value indistinguishable
# from its neighbour. Deduped, and a larger tier added for high-bandwidth /
# high-latency (satellite, intercontinental) links.
SOCKBUFS=(
  1048576
  4194304
  8388608
  16777216
  33554432
  67108864
  134217728
)

NOCOMP_SMUX=(
  "on|1"
  "on|2"
  "off|1"
  "off|2"
)

# Optional stages (off by default so total runtime matches V3.1 unless opted in).
FEC_SHARDS=(
  "0|0"
  "10|3"
  "10|2"
  "3|1"
)
CONNS=(1 2 4)

mkdir -p "$STATE_DIR" "$REPORT_DIR"
rm -f "$STATE_DIR"/*.pid "$STATE_DIR"/*.log "$STATE_DIR"/*.port "$STATE_DIR"/*.json 2>/dev/null || true

cleanup_local_test(){
  pkill -TERM -f "kcptun-server" 2>/dev/null || true
  pkill -TERM -f "iperf3 -s -B 0.0.0.0" 2>/dev/null || true
  pkill -TERM -f "iperf3 -s -B 127.0.0.1" 2>/dev/null || true
  sleep 0.3
  pkill -KILL -f "kcptun-server" 2>/dev/null || true
  pkill -KILL -f "iperf3 -s -B 0.0.0.0" 2>/dev/null || true
  pkill -KILL -f "iperf3 -s -B 127.0.0.1" 2>/dev/null || true
  rm -f "$STATE_DIR"/*.pid "$STATE_DIR"/*.log "$STATE_DIR"/*.port 2>/dev/null || true
}

remote_test_cleanup(){
  remote_exec_script <<REMOTE || true
pkill -TERM -f 'kcptun-client' 2>/dev/null || true
pkill -TERM -f 'iperf3 -s'     2>/dev/null || true
pkill -TERM -f 'iperf3 -c'     2>/dev/null || true
sleep 0.3
pkill -KILL -f 'kcptun-client' 2>/dev/null || true
pkill -KILL -f 'iperf3 -s'     2>/dev/null || true
pkill -KILL -f 'iperf3 -c'     2>/dev/null || true
rm -f '$REMOTE_DIR/test/'*.pid '$REMOTE_DIR/test/'*.log '$REMOTE_DIR/test/'*.port 2>/dev/null || true
REMOTE
}

trap 'cleanup_local_test || true; remote_test_cleanup 2>/dev/null || true' EXIT
trap 'trap - INT TERM; warn "Interrupted."; cleanup_local_test || true; remote_test_cleanup 2>/dev/null || true; exit 130' INT TERM

remote_exec(){
  # Password is read from the SSHPASS env var (sshpass -e), never from a
  # CLI arg -- a `-p PASSWORD` arg is visible to every local user via
  # `ps aux` for as long as the process runs. SSHPASS is only readable via
  # /proc/<pid>/environ, which requires the same privilege ps already needs.
  sshpass -e ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=3 \
    -p "$IRAN_PORT" "$IRAN_USER@$IRAN_IP" "$@"
}

remote_exec_script(){
  sshpass -e ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=3 \
    -p "$IRAN_PORT" "$IRAN_USER@$IRAN_IP" bash -s
}

remote_copy_atomic(){
  local src="$1" dest="$2"
  local base tmp remote_sha local_sha

  base="$(basename "$dest")"
  tmp="${dest}.new.$$"

  local_sha="$(sha256sum "$src" | awk '{print $1}')"
  prog "Uploading $base to temporary remote file..."
  sshpass -e scp \
    -q \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=20 \
    -P "$IRAN_PORT" \
    "$src" "$IRAN_USER@$IRAN_IP:$tmp" || die "SCP failed for $base"

  prog "Verifying SHA256 for $base..."
  remote_sha="$(remote_exec "sha256sum '$tmp' | awk '{print \$1}'")"
  if [[ "$local_sha" != "$remote_sha" ]]; then
    remote_exec "rm -f '$tmp'" || true
    die "SHA256 mismatch for $base"
  fi

  remote_exec "chmod 0755 '$tmp' && mv -f '$tmp' '$dest'" || die "Atomic move failed for $base"
  ok "$base deployed and SHA256 verified"
}

find_free_udp_port(){
  local p
  for p in $(seq "$KCP_PORT_DEFAULT" $((KCP_PORT_DEFAULT+100))); do
    if ! ss -Hlun | awk '{print $5}' | grep -Eq "(^|:)$p$"; then
      echo "$p"; return 0
    fi
  done
  die "No free UDP port found."
}

find_free_tcp_port(){
  local p
  for p in $(shuf -i 20000-45000 -n 200); do
    if ! ss -Hltn | awk '{print $4}' | grep -Eq "(^|:)$p$"; then
      echo "$p"; return 0
    fi
  done
  die "No free TCP port found."
}

wait_tcp(){
  local host="$1" port="$2" tries="${3:-20}"
  local i
  for ((i=1;i<=tries;i++)); do
    if timeout 1 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then return 0; fi
    sleep 0.5
  done
  return 1
}

parse_iperf_json(){
  python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    bps = d["end"]["sum_received"]["bits_per_second"]
    print(f"{bps/1_000_000:.2f}")
except Exception:
    print("0.00")
PY
}

is_better(){
  awk "BEGIN {exit !($1 > $2)}"
}

debug_pause(){
  [[ "${DEBUG:-0}" == "1" ]] || return 0
  echo >&2
  echo "---- DEBUG PAUSE ----" >&2
  echo "kcp_port=$kcp_port iperf_port=$iperf_port client_port=$client_port" >&2
  echo "mode=$mode mtu=$mtu snd=$snd rcv=$rcv sockbuf=$sockbuf nocomp=$nocomp smuxver=$smuxver" >&2
  echo "KHAREJ_IP=$KHAREJ_IP" >&2
  echo "--- local processes ---" >&2
  ps -ef | grep -E "kcptun-server|iperf3 -s" | grep -v grep >&2 || true
  echo "--- local listening ---" >&2
  ss -Hlun 2>/dev/null | grep -E ":$kcp_port\b" >&2 || true
  ss -Hltn 2>/dev/null | grep -E ":$iperf_port\b" >&2 || true
  echo "--- remote processes ---" >&2
  remote_exec "ps -ef | grep -E 'kcptun-client|iperf3 -s' | grep -v grep || true" >&2 || true
  echo "--- remote listening ---" >&2
  remote_exec "ss -Hltn 2>/dev/null | grep -E ':$client_port\b' || true" >&2 || true
  echo "--- local kcptun-server log ---" >&2
  tail -20 "$STATE_DIR/kcptun-server-$kcp_port.log" >&2 2>/dev/null || true
  echo "--- local iperf log ---" >&2
  tail -10 "$STATE_DIR/iperf-$iperf_port.log" >&2 2>/dev/null || true
  echo "--- remote kcptun-client log ---" >&2
  remote_exec "tail -20 '$REMOTE_DIR/test/kcptun-client-$client_port.log' 2>/dev/null || true" >&2 || true
  echo "--- remote iperf log ---" >&2
  remote_exec "tail -10 '$REMOTE_DIR/test/iperf-$iperf_port.log' 2>/dev/null || true" >&2 || true
  echo "Press Enter to continue (or Ctrl+C to abort)..." >&2
  read -r _ || true
}

# ------------------------------------------------------------
# Baseline: direct iperf3, server on Kharej public, client from Iran
# Only numeric value on stdout.
# ------------------------------------------------------------
run_baseline_iperf(){
  local iperf_port client_json
  iperf_port="$(find_free_tcp_port)"
  client_json="$STATE_DIR/baseline.json"

  prog "Baseline iperf3 port: $iperf_port"

  cleanup_local_test
  remote_test_cleanup

  nohup iperf3 -s -B 0.0.0.0 -p "$iperf_port" \
    --idle-timeout 60 > "$STATE_DIR/iperf-baseline.log" 2>&1 &
  echo "$!" > "$STATE_DIR/iperf-baseline.pid"

  sleep 2
  wait_tcp "127.0.0.1" "$iperf_port" 20 || warn "Local baseline listener not ready."

  if [[ "${DEBUG:-0}" == "1" ]]; then
    echo >&2
    echo "---- DEBUG PAUSE (baseline) ----" >&2
    echo "iperf_port=$iperf_port KHAREJ_IP=$KHAREJ_IP" >&2
    ps -ef | grep "iperf3 -s" | grep -v grep >&2 || true
    ss -Hltn 2>/dev/null | grep -E ":$iperf_port\b" >&2 || true
    tail -10 "$STATE_DIR/iperf-baseline.log" >&2 2>/dev/null || true
    echo "Press Enter to continue (or Ctrl+C to abort)..." >&2
    read -r _ || true
  fi

  if ! remote_exec "timeout 3 bash -c '</dev/tcp/$KHAREJ_IP/$iperf_port'" 2>/dev/null; then
    warn "Iran cannot reach Kharej iperf port $iperf_port."
    pkill -TERM -f "iperf3 -s -B 0.0.0.0 -p $iperf_port" 2>/dev/null || true
    echo "0.00"
    return
  fi

  prog "Baseline warm-up ${WARMUP_DURATION}s..."
  remote_exec "timeout '$WARMUP_DURATION' iperf3 -c '$KHAREJ_IP' -p '$iperf_port' -t '$WARMUP_DURATION' -P 1 >/dev/null 2>&1 || true"

  local total="0" valid=0 run speed
  for ((run=1; run<=RUNS_PER_PROFILE; run++)); do
    prog "Baseline iperf Run $run/$RUNS_PER_PROFILE (${TEST_DURATION}s, $STREAMS stream(s))..."
    remote_exec "timeout $((TEST_DURATION+5)) iperf3 -c '$KHAREJ_IP' -p '$iperf_port' -t '$TEST_DURATION' -P '$STREAMS' -J" > "$client_json" 2>/dev/null || true
    speed="$(parse_iperf_json "$client_json")"
    prog "Run $run: $speed Mbit/s"
    if awk "BEGIN {exit !($speed > 0)}"; then
      total="$(awk "BEGIN {print $total + $speed}")"
      valid=$((valid+1))
    fi
  done

  pkill -TERM -f "iperf3 -s -B 0.0.0.0 -p $iperf_port" 2>/dev/null || true
  sleep 0.3
  pkill -KILL -f "iperf3 -s -B 0.0.0.0 -p $iperf_port" 2>/dev/null || true

  if (( valid > 0 )); then
    awk "BEGIN {printf \"%.2f\", $total/$valid}"
  else
    echo "0.00"
  fi
}
# ------------------------------------------------------------
# kcptun-rs measurement. Only numeric value on stdout.
# Args: mode mtu snd rcv sockbuf nocomp smuxver [fec_ds/fec_ps] [conn]
# The last two args are optional and only used by the FEC/CONN stages;
# omitting them preserves exact V3.1 behaviour (no FEC flags, default --conn).
# ------------------------------------------------------------
measure_kcptun(){
  local mode="$1" mtu="$2" snd="$3" rcv="$4" sockbuf="$5" nocomp="$6" smuxver="$7"
  local fec="${8:-}" conn="${9:-}"

  local kcp_port iperf_port client_port
  kcp_port="$(find_free_udp_port)"
  iperf_port=50001
  client_port=50001

  local nocomp_flag=""
  [[ "$nocomp" == "on" ]] && nocomp_flag="--nocomp"

  local fec_flag="" ds ps
  if [[ -n "$fec" ]]; then
    IFS='|' read -r ds ps <<< "$fec"
    fec_flag="--datashard $ds --parityshard $ps"
  fi

  local conn_flag=""
  [[ -n "$conn" ]] && conn_flag="--conn $conn"

  local total="0" valid=0 run speed json

  for ((run=1; run<=RUNS_PER_PROFILE; run++)); do
    cleanup_local_test
    remote_test_cleanup

    nohup iperf3 -s -B 127.0.0.1 -p "$iperf_port" \
      --idle-timeout 30 > "$STATE_DIR/iperf-$iperf_port.log" 2>&1 &
    echo "$!" > "$STATE_DIR/iperf-$iperf_port.pid"

    nohup "$BIN_DIR/kcptun-server" \
      -l ":$kcp_port" \
      -t "127.0.0.1:$iperf_port" \
      --key "$KEY" --crypt "$CRYPT_FIXED" --mode "$mode" \
      --mtu "$mtu" --sndwnd "$snd" --rcvwnd "$rcv" \
      --sockbuf "$sockbuf" $nocomp_flag --smuxver "$smuxver" $fec_flag \
      >"$STATE_DIR/kcptun-server-$kcp_port.log" 2>&1 &
    echo "$!" > "$STATE_DIR/kcptun-server.pid"

    sleep 2

    remote_exec_script <<REMOTE
nohup '$REMOTE_BIN_DIR/kcptun-client' \
  -r '$KHAREJ_IP:$kcp_port' \
  -l ':$client_port' \
  --key '$KEY' --crypt '$CRYPT_FIXED' --mode '$mode' \
  --mtu '$mtu' --sndwnd '$snd' --rcvwnd '$rcv' \
  --sockbuf '$sockbuf' $nocomp_flag --smuxver '$smuxver' $fec_flag $conn_flag \
  > '$REMOTE_DIR/test/kcptun-client-$client_port.log' 2>&1 &
echo \$! > '$REMOTE_DIR/test/kcptun-client-$client_port.pid'
REMOTE

    sleep 3
    debug_pause

    remote_exec "timeout 3 iperf3 -c 127.0.0.1 -p '$client_port' -t 3 -P 1 >/dev/null 2>&1 || true"

    json="$STATE_DIR/iperf-$$-$run.json"
    remote_exec "timeout $((TEST_DURATION+5)) iperf3 -c 127.0.0.1 -p '$client_port' -t '$TEST_DURATION' -P '$STREAMS' -J" > "$json" 2>/dev/null || true
    speed="$(parse_iperf_json "$json")"
    if awk "BEGIN {exit !($speed > 0)}"; then
      total="$(awk "BEGIN {print $total + $speed}")"
      valid=$((valid+1))
    fi
  done

  cleanup_local_test
  remote_test_cleanup

  if (( valid > 0 )); then
    awk "BEGIN {printf \"%.2f\", $total/$valid}"
  else
    echo "0.00"
  fi
}

# ============================================================
#  MAIN
# ============================================================
need_root

echo -e "${BOLD}${CYAN}" >&2
echo "==========================================================" >&2
echo "       kcptun-rs Auto Optimizer V4.0" >&2
echo "       Baseline + Greedy Multi-Stage Tuner" >&2
echo "==========================================================" >&2
echo -e "${NC}" >&2

step "Iran SSH details"
if [[ -n "${IRAN_IP:-}" && -n "${IRAN_PASS:-}" ]]; then
  IRAN_USER="${IRAN_USER:-root}"
  IRAN_PORT="${IRAN_PORT:-22}"
  info "Using env: IRAN_IP=$IRAN_IP IRAN_USER=$IRAN_USER IRAN_PORT=$IRAN_PORT"
else
  [[ -t 0 ]] || die "Non-interactive shell. Set IRAN_IP / IRAN_USER / IRAN_PASS / IRAN_PORT env vars."
  read -r -p "Iran IP: " IRAN_IP
  read -r -p "Iran SSH Username [root]: " IRAN_USER
  IRAN_USER="${IRAN_USER:-root}"
  read -r -s -p "Iran SSH Password: " IRAN_PASS
  echo
  read -r -p "Iran SSH Port [22]: " IRAN_PORT
  IRAN_PORT="${IRAN_PORT:-22}"
fi

# Exported for sshpass -e; never passed as a CLI argument (see remote_exec).
export SSHPASS="$IRAN_PASS"

if ! command -v sshpass >/dev/null 2>&1; then
  info "Installing sshpass locally..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq sshpass >/dev/null
fi
command -v sshpass >/dev/null || die "sshpass is required."

step "Pre-flight"
cleanup_local_test
remote_exec "echo SSH_OK" >/dev/null || die "Iran SSH connection failed."
remote_test_cleanup

step "Installing Kharej dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget git build-essential pkg-config libssl-dev \
  iperf3 sshpass jq lsof net-tools bc python3 >/dev/null
ok "Kharej dependencies installed"

step "Installing Iran dependencies"
remote_exec_script <<'REMOTE'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iperf3 python3 curl >/dev/null 2>&1 || true
command -v iperf3 >/dev/null && echo IPERF3_OK || echo IPERF3_MISSING
REMOTE
ok "Iran dependencies installed"

step "Installing Rust"
if ! command -v rustc >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null
fi
# shellcheck disable=SC1091
source /root/.cargo/env 2>/dev/null || true
command -v cargo >/dev/null || die "Cargo is not available."
ok "Rust: $(rustc --version)"

step "Building kcptun-rs"
mkdir -p "$BIN_DIR"
cd "$WORKDIR"
if [[ ! -d "$WORKDIR/kcptun-rs/.git" ]]; then
  rm -rf "$WORKDIR/kcptun-rs"
  git clone --depth 1 https://github.com/xsean2020/kcptun-rs.git "$WORKDIR/kcptun-rs"
fi
cd "$WORKDIR/kcptun-rs"
cargo build --release
install -m 0755 target/release/kcptun-server "$BIN_DIR/kcptun-server"
install -m 0755 target/release/kcptun-client "$BIN_DIR/kcptun-client"
ok "kcptun-rs binaries ready"

step "Preparing Iran server"
remote_exec "mkdir -p '$REMOTE_BIN_DIR' '$REMOTE_DIR/test'" || die "Cannot prepare remote dirs."
remote_exec "pkill -TERM -f '$REMOTE_BIN_DIR/kcptun-client' 2>/dev/null || true"
remote_copy_atomic "$BIN_DIR/kcptun-client" "$REMOTE_BIN_DIR/kcptun-client"
remote_copy_atomic "$BIN_DIR/kcptun-server" "$REMOTE_BIN_DIR/kcptun-server"

step "Detecting Kharej public IP"
KHAREJ_IP="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$KHAREJ_IP" ]] || KHAREJ_IP="$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo UNKNOWN)"
info "Kharej public IP: $KHAREJ_IP"

step "Baseline: direct iperf3 (no tunnel)"
BASELINE="$(run_baseline_iperf)"
ok "Baseline (no tunnel): ${BASELINE} Mbit/s"

INIT_MTU=1350
INIT_SND=1024
INIT_RCV=1024
INIT_SOCKBUF=16777216
INIT_NOCOMP="on"
INIT_SMUXVER=2

step "Pre-flight: KCP UDP reachability"
info "Running one throwaway measurement before the full sweep..."
PREFLIGHT_SPEED="$(measure_kcptun "fast" "$INIT_MTU" "$INIT_SND" "$INIT_RCV" "$INIT_SOCKBUF" "$INIT_NOCOMP" "$INIT_SMUXVER")"
if ! awk "BEGIN {exit !($PREFLIGHT_SPEED > 0)}"; then
  # One retry in case it was just a slow first connection, not stopping the
  # whole run on a fluke.
  warn "Pre-flight measurement returned 0 Mbit/s, retrying once..."
  PREFLIGHT_SPEED="$(measure_kcptun "fast" "$INIT_MTU" "$INIT_SND" "$INIT_RCV" "$INIT_SOCKBUF" "$INIT_NOCOMP" "$INIT_SMUXVER")"
fi
if ! awk "BEGIN {exit !($PREFLIGHT_SPEED > 0)}"; then
  die "Pre-flight measurement failed twice (0 Mbit/s through the tunnel, while the direct baseline was ${BASELINE} Mbit/s). This almost always means UDP port $KCP_PORT_DEFAULT-$((KCP_PORT_DEFAULT+100)) is blocked on Kharej's firewall/security group, or NAT/UDP is filtered somewhere on the path. Fix that before re-running -- the full sweep would otherwise spend $((${#MODES[@]}+${#MTUS[@]}+${#WINDOWS[@]}+${#SOCKBUFS[@]}+${#NOCOMP_SMUX[@]})) measurements confirming the same 0."
fi
ok "Pre-flight OK: ${PREFLIGHT_SPEED} Mbit/s through the tunnel"

if [[ -n "$OVERRIDE_MODE" ]]; then
  step "Stage 1: Mode sweep SKIPPED (MODE=$OVERRIDE_MODE)"
  BEST_MODE="$OVERRIDE_MODE"
  BEST_MODE_SPEED="n/a"
  declare -a MODE_RESULTS=("$OVERRIDE_MODE|skipped")
else
  step "Stage 1: Mode sweep"
  declare -a MODE_RESULTS=()
  BEST_MODE_SPEED="0.00"
  BEST_MODE=""

  set +e
  i=0
  for m in "${MODES[@]}"; do
    i=$((i+1))
    prog "[$i/${#MODES[@]}] Mode '$m' with mtu=$INIT_MTU win=$INIT_SND/$INIT_RCV sockbuf=$INIT_SOCKBUF nocomp=$INIT_NOCOMP smuxver=$INIT_SMUXVER"
    speed="$(measure_kcptun "$m" "$INIT_MTU" "$INIT_SND" "$INIT_RCV" "$INIT_SOCKBUF" "$INIT_NOCOMP" "$INIT_SMUXVER")"
    prog "$m -> $speed Mbit/s"
    MODE_RESULTS+=("$m|$speed")
    if is_better "$speed" "$BEST_MODE_SPEED"; then
      BEST_MODE_SPEED="$speed"
      BEST_MODE="$m"
    fi
  done
  set -e

  [[ -n "$BEST_MODE" ]] || die "No valid Mode result."
  ok "Best Mode: $BEST_MODE (${BEST_MODE_SPEED} Mbit/s)"
fi

if [[ -n "$OVERRIDE_MTU" ]]; then
  step "Stage 2: MTU sweep SKIPPED (MTU=$OVERRIDE_MTU)"
  BEST_MTU="$OVERRIDE_MTU"
  BEST_MTU_SPEED="n/a"
  declare -a MTU_RESULTS=("$OVERRIDE_MTU|skipped")
else
  step "Stage 2: MTU sweep (best mode = $BEST_MODE)"
  declare -a MTU_RESULTS=()
  BEST_MTU_SPEED="0.00"
  BEST_MTU=""

  set +e
  i=0
  for mtu in "${MTUS[@]}"; do
    i=$((i+1))
    prog "[$i/${#MTUS[@]}] MTU=$mtu"
    speed="$(measure_kcptun "$BEST_MODE" "$mtu" "$INIT_SND" "$INIT_RCV" "$INIT_SOCKBUF" "$INIT_NOCOMP" "$INIT_SMUXVER")"
    prog "mtu=$mtu -> $speed Mbit/s"
    MTU_RESULTS+=("$mtu|$speed")
    if is_better "$speed" "$BEST_MTU_SPEED"; then
      BEST_MTU_SPEED="$speed"
      BEST_MTU="$mtu"
    fi
  done
  set -e

  [[ -n "$BEST_MTU" ]] || die "No valid MTU result."
  ok "Best MTU: $BEST_MTU (${BEST_MTU_SPEED} Mbit/s)"
fi

if [[ -n "$OVERRIDE_WIN" ]]; then
  IFS='/' read -r _ws _wr <<< "$OVERRIDE_WIN"
  step "Stage 3: SNDWND/RCVWND sweep SKIPPED (WIN=$_ws/$_wr)"
  BEST_WIN_SND="$_ws"
  BEST_WIN_RCV="$_wr"
  BEST_WIN_SPEED="n/a"
  declare -a WIN_RESULTS=("$_ws/$_wr|skipped")
else
  step "Stage 3: SNDWND/RCVWND sweep (mode=$BEST_MODE mtu=$BEST_MTU)"
  declare -a WIN_RESULTS=()
  BEST_WIN_SPEED="0.00"
  BEST_WIN_SND=""
  BEST_WIN_RCV=""

  set +e
  i=0
  for w in "${WINDOWS[@]}"; do
    i=$((i+1))
    IFS='|' read -r s r <<< "$w"
    prog "[$i/${#WINDOWS[@]}] win=$s/$r"
    speed="$(measure_kcptun "$BEST_MODE" "$BEST_MTU" "$s" "$r" "$INIT_SOCKBUF" "$INIT_NOCOMP" "$INIT_SMUXVER")"
    prog "win=$s/$r -> $speed Mbit/s"
    WIN_RESULTS+=("$s/$r|$speed")
    if is_better "$speed" "$BEST_WIN_SPEED"; then
      BEST_WIN_SPEED="$speed"
      BEST_WIN_SND="$s"
      BEST_WIN_RCV="$r"
    fi
  done
  set -e

  [[ -n "$BEST_WIN_SND" ]] || die "No valid Window result."
  ok "Best Window: $BEST_WIN_SND/$BEST_WIN_RCV (${BEST_WIN_SPEED} Mbit/s)"
fi

if [[ -n "$OVERRIDE_SOCKBUF" ]]; then
  step "Stage 4: SOCKBUF sweep SKIPPED (SOCKBUF=$OVERRIDE_SOCKBUF)"
  BEST_SOCK="$OVERRIDE_SOCKBUF"
  BEST_SOCK_SPEED="n/a"
  declare -a SOCK_RESULTS=("$OVERRIDE_SOCKBUF|skipped")
else
  step "Stage 4: SOCKBUF sweep (mode=$BEST_MODE mtu=$BEST_MTU win=$BEST_WIN_SND/$BEST_WIN_RCV)"
  declare -a SOCK_RESULTS=()
  BEST_SOCK_SPEED="0.00"
  BEST_SOCK=""

  set +e
  i=0
  for sb in "${SOCKBUFS[@]}"; do
    i=$((i+1))
    prog "[$i/${#SOCKBUFS[@]}] sockbuf=$sb"
    speed="$(measure_kcptun "$BEST_MODE" "$BEST_MTU" "$BEST_WIN_SND" "$BEST_WIN_RCV" "$sb" "$INIT_NOCOMP" "$INIT_SMUXVER")"
    prog "sockbuf=$sb -> $speed Mbit/s"
    SOCK_RESULTS+=("$sb|$speed")
    if is_better "$speed" "$BEST_SOCK_SPEED"; then
      BEST_SOCK_SPEED="$speed"
      BEST_SOCK="$sb"
    fi
  done
  set -e

  [[ -n "$BEST_SOCK" ]] || die "No valid SOCKBUF result."
  ok "Best SOCKBUF: $BEST_SOCK (${BEST_SOCK_SPEED} Mbit/s)"
fi

if [[ -n "$OVERRIDE_NOCOMP" && -n "$OVERRIDE_SMUXVER" ]]; then
  step "Stage 5: --nocomp / --smuxver sweep SKIPPED (nocomp=$OVERRIDE_NOCOMP smuxver=$OVERRIDE_SMUXVER)"
  BEST_NS_NOCOMP="$OVERRIDE_NOCOMP"
  BEST_NS_SMUX="$OVERRIDE_SMUXVER"
  BEST_NS_SPEED="n/a"
  declare -a NS_RESULTS=("nocomp=$OVERRIDE_NOCOMP smuxver=$OVERRIDE_SMUXVER|skipped")
else
  step "Stage 5: --nocomp / --smuxver sweep"
  declare -a NS_RESULTS=()
  BEST_NS_SPEED="0.00"
  BEST_NS_NOCOMP=""
  BEST_NS_SMUX=""

  set +e
  i=0
  for ns in "${NOCOMP_SMUX[@]}"; do
    i=$((i+1))
    IFS='|' read -r nc sv <<< "$ns"
    [[ -n "$OVERRIDE_NOCOMP" && "$nc" != "$OVERRIDE_NOCOMP" ]] && continue
    [[ -n "$OVERRIDE_SMUXVER" && "$sv" != "$OVERRIDE_SMUXVER" ]] && continue
    prog "[$i/${#NOCOMP_SMUX[@]}] nocomp=$nc smuxver=$sv"
    speed="$(measure_kcptun "$BEST_MODE" "$BEST_MTU" "$BEST_WIN_SND" "$BEST_WIN_RCV" "$BEST_SOCK" "$nc" "$sv")"
    prog "nocomp=$nc smuxver=$sv -> $speed Mbit/s"
    NS_RESULTS+=("nocomp=$nc smuxver=$sv|$speed")
    if is_better "$speed" "$BEST_NS_SPEED"; then
      BEST_NS_SPEED="$speed"
      BEST_NS_NOCOMP="$nc"
      BEST_NS_SMUX="$sv"
    fi
  done
  set -e

  [[ -n "$BEST_NS_NOCOMP" ]] || die "No valid nocomp/smuxver result."
  ok "Best nocomp=$BEST_NS_NOCOMP smuxver=$BEST_NS_SMUX (${BEST_NS_SPEED} Mbit/s)"
fi

# ---- Optional Stage 6: FEC (datashard/parityshard) ----
# Off by default (FEC_SWEEP=1 to enable): FEC trades throughput for
# resilience against packet loss, which is a real win on lossy mobile/
# satellite paths but pure overhead on a clean link, so it isn't assumed.
if [[ -n "$OVERRIDE_FEC" ]]; then
  IFS='/' read -r _fds _fps <<< "$OVERRIDE_FEC"
  step "Stage 6: FEC sweep SKIPPED (FEC=$_fds/$_fps)"
  BEST_FEC="$_fds|$_fps"
  BEST_FEC_SPEED="n/a"
  declare -a FEC_RESULTS=("$_fds/$_fps|skipped")
elif [[ "$FEC_SWEEP" == "1" ]]; then
  step "Stage 6: FEC sweep (mode=$BEST_MODE mtu=$BEST_MTU win=$BEST_WIN_SND/$BEST_WIN_RCV sockbuf=$BEST_SOCK)"
  declare -a FEC_RESULTS=()
  BEST_FEC_SPEED="0.00"
  BEST_FEC=""

  set +e
  i=0
  for f in "${FEC_SHARDS[@]}"; do
    i=$((i+1))
    prog "[$i/${#FEC_SHARDS[@]}] fec=$f"
    speed="$(measure_kcptun "$BEST_MODE" "$BEST_MTU" "$BEST_WIN_SND" "$BEST_WIN_RCV" "$BEST_SOCK" "$BEST_NS_NOCOMP" "$BEST_NS_SMUX" "$f")"
    prog "fec=$f -> $speed Mbit/s"
    FEC_RESULTS+=("$f|$speed")
    if is_better "$speed" "$BEST_FEC_SPEED"; then
      BEST_FEC_SPEED="$speed"
      BEST_FEC="$f"
    fi
  done
  set -e

  [[ -n "$BEST_FEC" ]] || die "No valid FEC result."
  ok "Best FEC (datashard|parityshard): $BEST_FEC (${BEST_FEC_SPEED} Mbit/s)"
else
  step "Stage 6: FEC sweep SKIPPED (set FEC_SWEEP=1 to enable, or FEC=ds/ps to pin a value)"
  BEST_FEC="0|0"
  BEST_FEC_SPEED="n/a"
  declare -a FEC_RESULTS=("not run|-")
fi

# ---- Optional Stage 7: --conn (parallel KCP connections) ----
# Off by default (CONN_SWEEP=1 to enable): more UDP connections can help
# push past a single-flow throughput ceiling, but also multiplies load on
# both ends, so it's opt-in rather than assumed.
if [[ -n "$OVERRIDE_CONN" ]]; then
  step "Stage 7: --conn sweep SKIPPED (CONN=$OVERRIDE_CONN)"
  BEST_CONN="$OVERRIDE_CONN"
  BEST_CONN_SPEED="n/a"
  declare -a CONN_RESULTS=("$OVERRIDE_CONN|skipped")
elif [[ "$CONN_SWEEP" == "1" ]]; then
  IFS='|' read -r _fds _fps <<< "$BEST_FEC"
  BEST_FEC_ARG=""
  [[ "$_fds" != "0" || "$_fps" != "0" ]] && BEST_FEC_ARG="$BEST_FEC"
  step "Stage 7: --conn sweep (mode=$BEST_MODE mtu=$BEST_MTU win=$BEST_WIN_SND/$BEST_WIN_RCV sockbuf=$BEST_SOCK)"
  declare -a CONN_RESULTS=()
  BEST_CONN_SPEED="0.00"
  BEST_CONN=""

  set +e
  i=0
  for c in "${CONNS[@]}"; do
    i=$((i+1))
    prog "[$i/${#CONNS[@]}] conn=$c"
    speed="$(measure_kcptun "$BEST_MODE" "$BEST_MTU" "$BEST_WIN_SND" "$BEST_WIN_RCV" "$BEST_SOCK" "$BEST_NS_NOCOMP" "$BEST_NS_SMUX" "$BEST_FEC_ARG" "$c")"
    prog "conn=$c -> $speed Mbit/s"
    CONN_RESULTS+=("$c|$speed")
    if is_better "$speed" "$BEST_CONN_SPEED"; then
      BEST_CONN_SPEED="$speed"
      BEST_CONN="$c"
    fi
  done
  set -e

  [[ -n "$BEST_CONN" ]] || die "No valid --conn result."
  ok "Best --conn: $BEST_CONN (${BEST_CONN_SPEED} Mbit/s)"
else
  step "Stage 7: --conn sweep SKIPPED (set CONN_SWEEP=1 to enable, or CONN=N to pin a value)"
  BEST_CONN=""
  BEST_CONN_SPEED="n/a"
  declare -a CONN_RESULTS=("not run|-")
fi

cleanup_local_test
remote_test_cleanup

NC_FLAG=""
[[ "$BEST_NS_NOCOMP" == "on" ]] && NC_FLAG="--nocomp"

FEC_FLAGS=""
IFS='|' read -r _fds _fps <<< "$BEST_FEC"
[[ "$_fds" != "0" || "$_fps" != "0" ]] && FEC_FLAGS="--datashard $_fds --parityshard $_fps"

CONN_FLAG=""
[[ -n "$BEST_CONN" ]] && CONN_FLAG="--conn $BEST_CONN"

ELAPSED=$(( $(date +%s) - SCRIPT_START_TS ))
REPORT_FILE="$REPORT_DIR/report-$(date +%Y%m%d-%H%M%S).txt"

{
echo "=========================================================="
echo "                 FINAL REPORT"
echo "=========================================================="
echo "Baseline (no tunnel)        : $BASELINE Mbit/s"
echo "Total run time              : $((ELAPSED/60))m $((ELAPSED%60))s"
echo
echo "Stage 1 - Mode:"
for r in "${MODE_RESULTS[@]}"; do
  IFS='|' read -r k v <<< "$r"
  printf '  %-30s %10s Mbit/s\n' "$k" "$v"
done
echo "  -> winner: $BEST_MODE"
echo
echo "Stage 2 - MTU (mode=$BEST_MODE):"
for r in "${MTU_RESULTS[@]}"; do
  IFS='|' read -r k v <<< "$r"
  printf '  %-30s %10s Mbit/s\n' "mtu=$k" "$v"
done
echo "  -> winner: $BEST_MTU"
echo
echo "Stage 3 - Window (mode=$BEST_MODE mtu=$BEST_MTU):"
for r in "${WIN_RESULTS[@]}"; do
  IFS='|' read -r k v <<< "$r"
  printf '  %-30s %10s Mbit/s\n' "win=$k" "$v"
done
echo "  -> winner: $BEST_WIN_SND/$BEST_WIN_RCV"
echo
echo "Stage 4 - SOCKBUF:"
for r in "${SOCK_RESULTS[@]}"; do
  IFS='|' read -r k v <<< "$r"
  printf '  %-30s %10s Mbit/s\n' "sockbuf=$k" "$v"
done
echo "  -> winner: $BEST_SOCK"
echo
echo "Stage 5 - nocomp/smuxver:"
for r in "${NS_RESULTS[@]}"; do
  IFS='|' read -r k v <<< "$r"
  printf '  %-30s %10s Mbit/s\n' "$k" "$v"
done
echo "  -> winner: nocomp=$BEST_NS_NOCOMP smuxver=$BEST_NS_SMUX"
echo
echo "Stage 6 - FEC (datashard/parityshard):"
for r in "${FEC_RESULTS[@]}"; do
  IFS='|' read -r k v <<< "$r"
  printf '  %-30s %10s Mbit/s\n' "fec=$k" "$v"
done
echo "  -> winner: $BEST_FEC"
echo
echo "Stage 7 - --conn:"
for r in "${CONN_RESULTS[@]}"; do
  IFS='|' read -r k v <<< "$r"
  printf '  %-30s %10s Mbit/s\n' "conn=$k" "$v"
done
echo "  -> winner: ${BEST_CONN:-default}"
echo
echo "Best overall: ${BEST_NS_SPEED} Mbit/s"
echo "  mode=$BEST_MODE mtu=$BEST_MTU win=$BEST_WIN_SND/$BEST_WIN_RCV sockbuf=$BEST_SOCK nocomp=$BEST_NS_NOCOMP smuxver=$BEST_NS_SMUX fec=$BEST_FEC conn=${BEST_CONN:-default}"
echo
echo "Shared Key: $KEY"
echo "Crypt     : $CRYPT_FIXED"
echo
echo "Ready-to-use commands:"
echo
echo "Kharej (server):"
echo "  $BIN_DIR/kcptun-server \\"
echo "    -l :<KCP_UDP_PORT> \\"
echo "    -t 127.0.0.1:<REAL_TARGET_PORT> \\"
echo "    --key $KEY \\"
echo "    --crypt $CRYPT_FIXED \\"
echo "    --mode $BEST_MODE \\"
echo "    --mtu $BEST_MTU \\"
echo "    --sndwnd $BEST_WIN_SND \\"
echo "    --rcvwnd $BEST_WIN_RCV \\"
echo "    --sockbuf $BEST_SOCK $NC_FLAG --smuxver $BEST_NS_SMUX $FEC_FLAGS $CONN_FLAG"
echo
echo "Iran (client):"
echo "  $REMOTE_BIN_DIR/kcptun-client \\"
echo "    -r $KHAREJ_IP:<KCP_UDP_PORT> \\"
echo "    -l :<LOCAL_TCP_PORT> \\"
echo "    --key $KEY \\"
echo "    --crypt $CRYPT_FIXED \\"
echo "    --mode $BEST_MODE \\"
echo "    --mtu $BEST_MTU \\"
echo "    --sndwnd $BEST_WIN_SND \\"
echo "    --rcvwnd $BEST_WIN_RCV \\"
echo "    --sockbuf $BEST_SOCK $NC_FLAG --smuxver $BEST_NS_SMUX $FEC_FLAGS $CONN_FLAG"
echo "=========================================================="
} | tee "$REPORT_FILE" >&2

if [[ "$CRYPT_FIXED" == "xor" || "$CRYPT_FIXED" == "none" ]]; then
  warn "The commands above use --crypt $CRYPT_FIXED. Do not run this in production -- rerun with the default CRYPT (aes-128) or another real cipher before deploying."
fi

info "Full report saved to: $REPORT_FILE"
ok "Tuning completed in $((ELAPSED/60))m $((ELAPSED%60))s."

