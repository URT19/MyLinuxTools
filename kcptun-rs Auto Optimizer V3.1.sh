#!/usr/bin/env bash
# ============================================================
# kcptun-rs Auto Optimizer V3.1
# Baseline + Greedy Multi-Stage Tuner
# Ubuntu 22/24
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
STATE_DIR="/run/kcptun-rs-v31"
KCP_PORT_DEFAULT=29900
KEY="kcptun-rs-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)"
TEST_DURATION=10
WARMUP_DURATION=2
RUNS_PER_PROFILE=1
DEBUG="${DEBUG:-0}"

# ---- Overrides from environment (skip sweep when set) ----
OVERRIDE_MODE="${MODE:-}"
OVERRIDE_MTU="${MTU:-}"
OVERRIDE_WIN="${WIN:-}"          # format: "snd/rcv"
OVERRIDE_SOCKBUF="${SOCKBUF:-}"
OVERRIDE_NOCOMP="${NOCOMP:-}"    # on|off
OVERRIDE_SMUXVER="${SMUXVER:-}"  # 1|2

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


CRYPT_FIXED="xor"

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

SOCKBUFS=(
  1048576
  4194304
  8388608
  16777216
  16777217
  33554432
  67108864
)

NOCOMP_SMUX=(
  "on|1"
  "on|2"
  "off|1"
  "off|2"
)

mkdir -p "$STATE_DIR"

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
  sshpass -p "$IRAN_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=3 \
    -p "$IRAN_PORT" "$IRAN_USER@$IRAN_IP" "$@"
}

remote_exec_script(){
  sshpass -p "$IRAN_PASS" ssh \
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
  sshpass -p "$IRAN_PASS" scp \
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
    prog "Baseline iperf Run $run/$RUNS_PER_PROFILE (${TEST_DURATION}s)..."
    remote_exec "timeout $((TEST_DURATION+5)) iperf3 -c '$KHAREJ_IP' -p '$iperf_port' -t '$TEST_DURATION' -P 1 -J" > "$client_json" 2>/dev/null || true
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
# Args: mode mtu snd rcv sockbuf nocomp smuxver
# ------------------------------------------------------------
measure_kcptun(){
  local mode="$1" mtu="$2" snd="$3" rcv="$4" sockbuf="$5" nocomp="$6" smuxver="$7"

  local kcp_port iperf_port client_port
  kcp_port="$(find_free_udp_port)"
  iperf_port=50001
  client_port=50001

  local nocomp_flag=""
  [[ "$nocomp" == "on" ]] && nocomp_flag="--nocomp"

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
      --sockbuf "$sockbuf" $nocomp_flag --smuxver "$smuxver" \
      >"$STATE_DIR/kcptun-server-$kcp_port.log" 2>&1 &
    echo "$!" > "$STATE_DIR/kcptun-server.pid"

    sleep 2

    remote_exec_script <<REMOTE
nohup '$REMOTE_BIN_DIR/kcptun-client' \
  -r '$KHAREJ_IP:$kcp_port' \
  -l ':$client_port' \
  --key '$KEY' --crypt '$CRYPT_FIXED' --mode '$mode' \
  --mtu '$mtu' --sndwnd '$snd' --rcvwnd '$rcv' \
  --sockbuf '$sockbuf' $nocomp_flag --smuxver '$smuxver' \
  > '$REMOTE_DIR/test/kcptun-client-$client_port.log' 2>&1 &
echo \$! > '$REMOTE_DIR/test/kcptun-client-$client_port.pid'
REMOTE

    sleep 3
    debug_pause

    remote_exec "timeout 3 iperf3 -c 127.0.0.1 -p '$client_port' -t 3 -P 1 >/dev/null 2>&1 || true"

    json="$STATE_DIR/iperf-$$-$run.json"
    remote_exec "timeout $((TEST_DURATION+5)) iperf3 -c 127.0.0.1 -p '$client_port' -t '$TEST_DURATION' -P 1 -J" > "$json" 2>/dev/null || true
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
echo "       kcptun-rs Auto Optimizer V3.1" >&2
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
INIT_SOCKBUF=16777217
INIT_NOCOMP="on"
INIT_SMUXVER=2

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
  for m in "${MODES[@]}"; do
    prog "Mode '$m' with mtu=$INIT_MTU win=$INIT_SND/$INIT_RCV sockbuf=$INIT_SOCKBUF nocomp=$INIT_NOCOMP smuxver=$INIT_SMUXVER"
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
  for mtu in "${MTUS[@]}"; do
    prog "MTU=$mtu"
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
  for w in "${WINDOWS[@]}"; do
    IFS='|' read -r s r <<< "$w"
    prog "win=$s/$r"
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
  for sb in "${SOCKBUFS[@]}"; do
    prog "sockbuf=$sb"
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
  for ns in "${NOCOMP_SMUX[@]}"; do
    IFS='|' read -r nc sv <<< "$ns"
    [[ -n "$OVERRIDE_NOCOMP" && "$nc" != "$OVERRIDE_NOCOMP" ]] && continue
    [[ -n "$OVERRIDE_SMUXVER" && "$sv" != "$OVERRIDE_SMUXVER" ]] && continue
    prog "nocomp=$nc smuxver=$sv"
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

cleanup_local_test
remote_test_cleanup

echo >&2
echo -e "${BOLD}${CYAN}==========================================================" >&2
echo "                 FINAL REPORT" >&2
echo "==========================================================${NC}" >&2
echo "Baseline (no tunnel)        : $BASELINE Mbit/s" >&2
echo >&2
echo "Stage 1 - Mode:" >&2
for r in "${MODE_RESULTS[@]}"; do
  IFS='|' read -r k v <<< "$r"
  printf '  %-30s %10s Mbit/s\n' "$k" "$v" >&2
done
echo "  -> winner: $BEST_MODE" >&2
echo >&2
echo "Stage 2 - MTU (mode=$BEST_MODE):" >&2
for r in "${MTU_RESULTS[@]}"; do
  IFS='|' read -r k v <<< "$r"
  printf '  %-30s %10s Mbit/s\n' "mtu=$k" "$v" >&2
done
echo "  -> winner: $BEST_MTU" >&2
echo >&2
echo "Stage 3 - Window (mode=$BEST_MODE mtu=$BEST_MTU):" >&2
for r in "${WIN_RESULTS[@]}"; do
  IFS='|' read -r k v <<< "$r"
  printf '  %-30s %10s Mbit/s\n' "win=$k" "$v" >&2
done
echo "  -> winner: $BEST_WIN_SND/$BEST_WIN_RCV" >&2
echo >&2
echo "Stage 4 - SOCKBUF:" >&2
for r in "${SOCK_RESULTS[@]}"; do
  IFS='|' read -r k v <<< "$r"
  printf '  %-30s %10s Mbit/s\n' "sockbuf=$k" "$v" >&2
done
echo "  -> winner: $BEST_SOCK" >&2
echo >&2
echo "Stage 5 - nocomp/smuxver:" >&2
for r in "${NS_RESULTS[@]}"; do
  IFS='|' read -r k v <<< "$r"
  printf '  %-30s %10s Mbit/s\n' "$k" "$v" >&2
done
echo "  -> winner: nocomp=$BEST_NS_NOCOMP smuxver=$BEST_NS_SMUX" >&2
echo >&2
echo -e "${GREEN}${BOLD}Best overall: ${BEST_NS_SPEED} Mbit/s" >&2
echo -e "  mode=$BEST_MODE mtu=$BEST_MTU win=$BEST_WIN_SND/$BEST_WIN_RCV sockbuf=$BEST_SOCK nocomp=$BEST_NS_NOCOMP smuxver=$BEST_NS_SMUX${NC}" >&2
echo >&2
echo "Shared Key: $KEY" >&2
echo "Crypt     : $CRYPT_FIXED" >&2
echo >&2

NC_FLAG=""
[[ "$BEST_NS_NOCOMP" == "on" ]] && NC_FLAG="--nocomp"

echo "Ready-to-use commands:" >&2
echo >&2
echo "Kharej (server):" >&2
echo "  $BIN_DIR/kcptun-server \\" >&2
echo "    -l :<KCP_UDP_PORT> \\" >&2
echo "    -t 127.0.0.1:<REAL_TARGET_PORT> \\" >&2
echo "    --key $KEY \\" >&2
echo "    --crypt $CRYPT_FIXED \\" >&2
echo "    --mode $BEST_MODE \\" >&2
echo "    --mtu $BEST_MTU \\" >&2
echo "    --sndwnd $BEST_WIN_SND \\" >&2
echo "    --rcvwnd $BEST_WIN_RCV \\" >&2
echo "    --sockbuf $BEST_SOCK $NC_FLAG --smuxver $BEST_NS_SMUX" >&2
echo >&2
echo "Iran (client):" >&2
echo "  $REMOTE_BIN_DIR/kcptun-client \\" >&2
echo "    -r $KHAREJ_IP:<KCP_UDP_PORT> \\" >&2
echo "    -l :<LOCAL_TCP_PORT> \\" >&2
echo "    --key $KEY \\" >&2
echo "    --crypt $CRYPT_FIXED \\" >&2
echo "    --mode $BEST_MODE \\" >&2
echo "    --mtu $BEST_MTU \\" >&2
echo "    --sndwnd $BEST_WIN_SND \\" >&2
echo "    --rcvwnd $BEST_WIN_RCV \\" >&2
echo "    --sockbuf $BEST_SOCK $NC_FLAG --smuxver $BEST_NS_SMUX" >&2
echo -e "${BOLD}${CYAN}==========================================================${NC}" >&2
ok "Tuning completed."

