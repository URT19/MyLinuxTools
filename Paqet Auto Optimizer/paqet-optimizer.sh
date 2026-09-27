#!/usr/bin/env bash
# ============================================================
# Paqet Auto Optimizer V2.1
# Baseline + Greedy Multi-Stage Tuner for Paqet v2.2.0-optimized
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

WORKDIR="/opt/paqet-optimizer"
BIN_DIR="$WORKDIR/bin"
REMOTE_DIR="/opt/paqet-optimizer"
REMOTE_BIN_DIR="$REMOTE_DIR/bin"
STATE_DIR="/run/paqet-optimizer"
CONFIG_DIR="$STATE_DIR/configs"
KCP_PORT_DEFAULT=29900
KEY="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)"
TEST_DURATION=10
WARMUP_DURATION=2
RUNS_PER_PROFILE=1
DEBUG="${DEBUG:-0}"

PAQET_BIN="$BIN_DIR/paqet"
PAQET_REMOTE_BIN="$REMOTE_BIN_DIR/paqet"
PAQET_DOWNLOAD_URL="https://github.com/behzadea12/Paqet-Tunnel-Manager/releases/download/PaqetOptimized/paqet-linux-amd64-v2.2.0-optimize.tar.gz"

# ---- Overrides ----
OVERRIDE_MODE="${MODE:-}"
OVERRIDE_MTU="${MTU:-}"
OVERRIDE_CONN="${CONN:-}"
OVERRIDE_BLOCK="${BLOCK:-}"

# ---- Sweep lists ----
MODES=("fast" "fast2" "fast3" "normal" "manual")
MTUS=(1500 1450 1400 1350 1300 1250 1200 1150)
CONNS=(2 4 8)
BLOCKS=("aes" "xor" "none")

mkdir -p "$STATE_DIR" "$CONFIG_DIR"

# ---- Cleanup ----
cleanup_local_test(){
  pkill -TERM -f "paqet run" 2>/dev/null || true
  pkill -TERM -f "$PAQET_BIN" 2>/dev/null || true
  pkill -TERM -f "iperf3 -s -B 0.0.0.0" 2>/dev/null || true
  pkill -TERM -f "iperf3 -s -B 127.0.0.1" 2>/dev/null || true
  pkill -TERM -f "iperf3 -c" 2>/dev/null || true
  sleep 0.3
  pkill -KILL -f "paqet run" 2>/dev/null || true
  pkill -KILL -f "$PAQET_BIN" 2>/dev/null || true
  pkill -KILL -f "iperf3 -s -B 0.0.0.0" 2>/dev/null || true
  pkill -KILL -f "iperf3 -s -B 127.0.0.1" 2>/dev/null || true
  pkill -KILL -f "iperf3 -c" 2>/dev/null || true
  rm -f "$STATE_DIR"/*.pid "$STATE_DIR"/*.log "$STATE_DIR"/*.port 2>/dev/null || true
}

remote_test_cleanup(){
  remote_exec_script <<REMOTE || true
pkill -TERM -f 'paqet run' 2>/dev/null || true
pkill -TERM -f 'iperf3 -s' 2>/dev/null || true
pkill -TERM -f 'iperf3 -c' 2>/dev/null || true
sleep 0.3
pkill -KILL -f 'paqet run' 2>/dev/null || true
pkill -KILL -f 'iperf3 -s' 2>/dev/null || true
pkill -KILL -f 'iperf3 -c' 2>/dev/null || true
rm -f '$REMOTE_DIR/test/'*.pid '$REMOTE_DIR/test/'*.log '$REMOTE_DIR/test/'*.port 2>/dev/null || true
REMOTE
}

trap 'cleanup_local_test || true; remote_test_cleanup 2>/dev/null || true' EXIT
trap 'trap - INT TERM; warn "Interrupted."; cleanup_local_test || true; remote_test_cleanup 2>/dev/null || true; exit 130' INT TERM

# ---- SSH ----
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
  sshpass -p "$IRAN_PASS" scp -q \
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

# ---- Ports ----
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

is_better(){ awk "BEGIN {exit !($1 > $2)}"; }

# ---- Network detection ----
detect_local_network(){
  local iface ip_addr router_mac
  iface="$(ip -o link show | awk -F': ' '$2 != "lo" {print $2}' | head -1)"
  [[ -n "$iface" ]] || iface="eth0"
  ip_addr="$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
  [[ -n "$ip_addr" ]] || ip_addr="0.0.0.0"
  router_mac="$(ip neigh show default 2>/dev/null | awk '{print $5}' | head -1)"
  [[ -n "$router_mac" ]] || router_mac="00:00:00:00:00:00"
  echo "$iface|$ip_addr|$router_mac"
}

detect_remote_network(){
  remote_exec_script <<'REMOTE'
iface="$(ip -o link show | awk -F': ' '$2 != "lo" {print $2}' | head -1)"
[[ -n "$iface" ]] || iface="eth0"
ip_addr="$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
[[ -n "$ip_addr" ]] || ip_addr="0.0.0.0"
router_mac="$(ip neigh show default 2>/dev/null | awk '{print $5}' | head -1)"
[[ -n "$router_mac" ]] || router_mac="00:00:00:00:00:00"
echo "$iface|$ip_addr|$router_mac"
REMOTE
}

# ---- Config generation ----
generate_server_config(){
  local out="$1" listen_port="$2" mode="$3" mtu="$4" conn="$5" block="$6"
  local iface="$7" ip_addr="$8" router_mac="$9"

  cat > "$out" <<EOF
role: "server"
log:
  level: "info"
listen:
  addr: ":$listen_port"
network:
  interface: "$iface"
  ipv4:
    addr: "$ip_addr:$listen_port"
    router_mac: "$router_mac"
  tcp:
    local_flag: ["PA"]
transport:
  protocol: "kcp"
  conn: $conn
  kcp:
    key: "$KEY"
    mode: "$mode"
    block: "$block"
    mtu: $mtu
EOF
}

generate_client_config(){
  local out="$1" server_addr="$2" local_listen="$3" target_port="$4" mode="$5" mtu="$6" conn="$7" block="$8"
  local iface="$9" ip_addr="${10}" router_mac="${11}"

  cat > "$out" <<EOF
role: "client"
log:
  level: "info"
forward:
  - listen: "127.0.0.1:$local_listen"
    target: "127.0.0.1:$target_port"
    protocol: "tcp"
network:
  interface: "$iface"
  ipv4:
    addr: "$ip_addr:0"
    router_mac: "$router_mac"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]
server:
  addr: "$server_addr"
transport:
  protocol: "kcp"
  conn: $conn
  kcp:
    key: "$KEY"
    mode: "$mode"
    block: "$block"
    mtu: $mtu
EOF
}

# ---- Debug ----
debug_pause(){
  [[ "${DEBUG:-0}" == "1" ]] || return 0
  echo >&2
  echo "---- DEBUG PAUSE ----" >&2
  echo "kcp_port=$kcp_port iperf_port=$iperf_port client_port=$client_port" >&2
  echo "mode=$mode mtu=$mtu conn=$conn block=$block" >&2
  echo "KHAREJ_IP=$KHAREJ_IP" >&2
  echo "--- local processes ---" >&2
  ps -ef | grep -E "paqet|iperf3 -s" | grep -v grep >&2 || true
  echo "--- local listening ---" >&2
  ss -Hlun 2>/dev/null | grep -E ":$kcp_port\\b" >&2 || true
  ss -Hltn 2>/dev/null | grep -E ":$iperf_port\\b" >&2 || true
  echo "--- remote processes ---" >&2
  remote_exec "ps -ef | grep -E 'paqet|iperf3 -s' | grep -v grep || true" >&2 || true
  echo "--- remote listening ---" >&2
  remote_exec "ss -Hltn 2>/dev/null | grep -E ':$client_port\\b' || true" >&2 || true
  echo "--- local paqet log ---" >&2
  tail -20 "$STATE_DIR/paqet-server-$kcp_port.log" >&2 2>/dev/null || true
  echo "--- local server config ---" >&2
  cat "$CONFIG_DIR/server-$kcp_port.yaml" >&2 2>/dev/null || true
  echo "--- remote paqet log ---" >&2
  remote_exec "tail -20 '$REMOTE_DIR/test/paqet-client-$client_port.log' 2>/dev/null || true" >&2 || true
  echo "--- remote client config ---" >&2
  remote_exec "cat '$REMOTE_DIR/test/client-$client_port.yaml' 2>/dev/null || true" >&2 || true
  echo "Press Enter to continue (or Ctrl+C to abort)..." >&2
  read -r _ || true
}

# ============================================================
#  Baseline
# ============================================================
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

# ============================================================
#  Measurement
# ============================================================
measure_paqet(){
  local mode="$1" mtu="$2" conn="$3" block="$4"

  local kcp_port iperf_port client_port
  kcp_port="$(find_free_udp_port)"
  iperf_port=50001
  client_port=50002

  local total="0" valid=0 run speed json

  local local_net iface ip_addr router_mac
  local_net="$(detect_local_network)"
  iface="${local_net%%|*}"
  local tmp="${local_net#*|}"; ip_addr="${tmp%%|*}"; router_mac="${tmp##*|}"

  local remote_net remote_iface remote_ip remote_router_mac
  remote_net="$(detect_remote_network)"
  remote_iface="${remote_net%%|*}"
  tmp="${remote_net#*|}"; remote_ip="${tmp%%|*}"; remote_router_mac="${tmp##*|}"

  for ((run=1; run<=RUNS_PER_PROFILE; run++)); do
    cleanup_local_test
    remote_test_cleanup

    nohup iperf3 -s -B 127.0.0.1 -p "$iperf_port" \
      --idle-timeout 30 > "$STATE_DIR/iperf-$iperf_port.log" 2>&1 &
    echo "$!" > "$STATE_DIR/iperf-$iperf_port.pid"

    local server_config="$CONFIG_DIR/server-$kcp_port.yaml"
    generate_server_config "$server_config" "$kcp_port" \
      "$mode" "$mtu" "$conn" "$block" \
      "$iface" "$ip_addr" "$router_mac"

    nohup "$PAQET_BIN" run -c "$server_config" \
      >"$STATE_DIR/paqet-server-$kcp_port.log" 2>&1 &
    echo "$!" > "$STATE_DIR/paqet-server.pid"

    sleep 2

    local client_config="$CONFIG_DIR/client-$client_port.yaml"
    # client listen port must differ from iperf3 target port on Kharej
    generate_client_config "$client_config" "$KHAREJ_IP:$kcp_port" "$client_port" "$iperf_port" \
      "$mode" "$mtu" "$conn" "$block" \
      "$remote_iface" "$remote_ip" "$remote_router_mac"

    remote_copy_atomic "$client_config" "$REMOTE_DIR/test/client-$client_port.yaml"

    remote_exec_script <<REMOTE
nohup '$PAQET_REMOTE_BIN' run -c '$REMOTE_DIR/test/client-$client_port.yaml' \\
  > '$REMOTE_DIR/test/paqet-client-$client_port.log' 2>&1 &
echo \$! > '$REMOTE_DIR/test/paqet-client-$client_port.pid'
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
echo "       Paqet Auto Optimizer V2.1" >&2
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

step "Installing dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget iperf3 sshpass jq lsof net-tools bc python3 iproute2 >/dev/null
ok "Kharej dependencies installed"

remote_exec_script <<'REMOTE'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iperf3 python3 curl iproute2 >/dev/null 2>&1 || true
command -v iperf3 >/dev/null && echo IPERF3_OK || echo IPERF3_MISSING
REMOTE
ok "Iran dependencies installed"

step "Downloading Paqet binary"
mkdir -p "$BIN_DIR"
rm -f "$PAQET_BIN"
cd "$BIN_DIR"
TARBALL="paqet-linux-amd64-v2.2.0-optimize.tar.gz"
curl -L -o "$TARBALL" "$PAQET_DOWNLOAD_URL"
tar -xzf "$TARBALL"
if [[ -f "paqet_linux_amd64" ]]; then
  mv -f paqet_linux_amd64 "$PAQET_BIN"
elif [[ -f "paqet" ]]; then
  mv -f paqet "$PAQET_BIN"
else
  FOUND="$(find . -maxdepth 2 -type f -name 'paqet*' ! -name '*.tar.gz' | head -1)"
  [[ -n "$FOUND" ]] || die "paqet binary not found in tarball"
  mv -f "$FOUND" "$PAQET_BIN"
fi
chmod +x "$PAQET_BIN"
rm -f "$TARBALL"
ok "Paqet binary ready: $PAQET_BIN"
"$PAQET_BIN" version

step "Preparing Iran server"
remote_exec "mkdir -p '$REMOTE_BIN_DIR' '$REMOTE_DIR/test'" || die "Cannot prepare remote dirs."
remote_exec "pkill -TERM -f 'paqet run' 2>/dev/null || true"
remote_copy_atomic "$PAQET_BIN" "$PAQET_REMOTE_BIN"

step "Detecting Kharej public IP"
KHAREJ_IP="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$KHAREJ_IP" ]] || KHAREJ_IP="$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo UNKNOWN)"
info "Kharej public IP: $KHAREJ_IP"

step "Baseline: direct iperf3 (no tunnel)"
BASELINE="$(run_baseline_iperf)"
ok "Baseline (no tunnel): ${BASELINE} Mbit/s"

INIT_MTU=1350
INIT_CONN=4
INIT_BLOCK="xor"

# ============================================================
#  Stage 1: Mode
# ============================================================
declare -a MODE_RESULTS=()
BEST_MODE_SPEED="0.00"
BEST_MODE=""

if [[ -n "$OVERRIDE_MODE" ]]; then
  step "Stage 1: Mode sweep SKIPPED (MODE=$OVERRIDE_MODE)"
  BEST_MODE="$OVERRIDE_MODE"; BEST_MODE_SPEED="n/a"
  MODE_RESULTS=("$OVERRIDE_MODE|skipped")
else
  step "Stage 1: Mode sweep"
  set +e
  for m in "${MODES[@]}"; do
    prog "Mode '$m'"
    speed="$(measure_paqet "$m" "$INIT_MTU" "$INIT_CONN" "$INIT_BLOCK")"
    prog "$m -> $speed Mbit/s"
    MODE_RESULTS+=("$m|$speed")
    if is_better "$speed" "$BEST_MODE_SPEED"; then BEST_MODE_SPEED="$speed"; BEST_MODE="$m"; fi
  done
  set -e
  [[ -n "$BEST_MODE" ]] || die "No valid Mode result."
  ok "Best Mode: $BEST_MODE (${BEST_MODE_SPEED} Mbit/s)"
fi

# ============================================================
#  Stage 2: MTU
# ============================================================
declare -a MTU_RESULTS=()
BEST_MTU_SPEED="0.00"
BEST_MTU=""

if [[ -n "$OVERRIDE_MTU" ]]; then
  step "Stage 2: MTU sweep SKIPPED (MTU=$OVERRIDE_MTU)"
  BEST_MTU="$OVERRIDE_MTU"; BEST_MTU_SPEED="n/a"
  MTU_RESULTS=("$OVERRIDE_MTU|skipped")
else
  step "Stage 2: MTU sweep (mode=$BEST_MODE)"
  set +e
  for mtu in "${MTUS[@]}"; do
    prog "MTU=$mtu"
    speed="$(measure_paqet "$BEST_MODE" "$mtu" "$INIT_CONN" "$INIT_BLOCK")"
    prog "mtu=$mtu -> $speed Mbit/s"
    MTU_RESULTS+=("$mtu|$speed")
    if is_better "$speed" "$BEST_MTU_SPEED"; then BEST_MTU_SPEED="$speed"; BEST_MTU="$mtu"; fi
  done
  set -e
  [[ -n "$BEST_MTU" ]] || die "No valid MTU result."
  ok "Best MTU: $BEST_MTU (${BEST_MTU_SPEED} Mbit/s)"
fi

# ============================================================
#  Stage 3: CONN
# ============================================================
declare -a CONN_RESULTS=()
BEST_CONN_SPEED="0.00"
BEST_CONN=""

if [[ -n "$OVERRIDE_CONN" ]]; then
  step "Stage 3: CONN sweep SKIPPED (CONN=$OVERRIDE_CONN)"
  BEST_CONN="$OVERRIDE_CONN"; BEST_CONN_SPEED="n/a"
  CONN_RESULTS=("$OVERRIDE_CONN|skipped")
else
  step "Stage 3: CONN sweep (mode=$BEST_MODE mtu=$BEST_MTU)"
  set +e
  for cn in "${CONNS[@]}"; do
    prog "conn=$cn"
    speed="$(measure_paqet "$BEST_MODE" "$BEST_MTU" "$cn" "$INIT_BLOCK")"
    prog "conn=$cn -> $speed Mbit/s"
    CONN_RESULTS+=("$cn|$speed")
    if is_better "$speed" "$BEST_CONN_SPEED"; then BEST_CONN_SPEED="$speed"; BEST_CONN="$cn"; fi
  done
  set -e
  [[ -n "$BEST_CONN" ]] || die "No valid CONN result."
  ok "Best CONN: $BEST_CONN (${BEST_CONN_SPEED} Mbit/s)"
fi

# ============================================================
#  Stage 4: BLOCK (encryption)
# ============================================================
declare -a BLOCK_RESULTS=()
BEST_BLOCK_SPEED="0.00"
BEST_BLOCK=""

if [[ -n "$OVERRIDE_BLOCK" ]]; then
  step "Stage 4: BLOCK sweep SKIPPED (BLOCK=$OVERRIDE_BLOCK)"
  BEST_BLOCK="$OVERRIDE_BLOCK"; BEST_BLOCK_SPEED="n/a"
  BLOCK_RESULTS=("$OVERRIDE_BLOCK|skipped")
else
  step "Stage 4: BLOCK sweep (mode=$BEST_MODE mtu=$BEST_MTU conn=$BEST_CONN)"
  set +e
  for bl in "${BLOCKS[@]}"; do
    prog "block=$bl"
    speed="$(measure_paqet "$BEST_MODE" "$BEST_MTU" "$BEST_CONN" "$bl")"
    prog "block=$bl -> $speed Mbit/s"
    BLOCK_RESULTS+=("$bl|$speed")
    if is_better "$speed" "$BEST_BLOCK_SPEED"; then BEST_BLOCK_SPEED="$speed"; BEST_BLOCK="$bl"; fi
  done
  set -e
  [[ -n "$BEST_BLOCK" ]] || die "No valid BLOCK result."
  ok "Best BLOCK: $BEST_BLOCK (${BEST_BLOCK_SPEED} Mbit/s)"
fi

cleanup_local_test
remote_test_cleanup

echo >&2
echo -e "${BOLD}${CYAN}==========================================================" >&2
echo "                 FINAL REPORT" >&2
echo -e "==========================================================${NC}" >&2
echo "Baseline (no tunnel) : $BASELINE Mbit/s" >&2
echo >&2
echo "Stage 1 - Mode:" >&2
for r in "${MODE_RESULTS[@]}"; do IFS='|' read -r k v <<< "$r"; printf '  %-20s %10s Mbit/s\n' "$k" "$v" >&2; done
echo "  -> winner: $BEST_MODE" >&2
echo >&2
echo "Stage 2 - MTU:" >&2
for r in "${MTU_RESULTS[@]}"; do IFS='|' read -r k v <<< "$r"; printf '  %-20s %10s Mbit/s\n' "mtu=$k" "$v" >&2; done
echo "  -> winner: $BEST_MTU" >&2
echo >&2
echo "Stage 3 - CONN:" >&2
for r in "${CONN_RESULTS[@]}"; do IFS='|' read -r k v <<< "$r"; printf '  %-20s %10s Mbit/s\n' "conn=$k" "$v" >&2; done
echo "  -> winner: $BEST_CONN" >&2
echo >&2
echo "Stage 4 - BLOCK:" >&2
for r in "${BLOCK_RESULTS[@]}"; do IFS='|' read -r k v <<< "$r"; printf '  %-20s %10s Mbit/s\n' "block=$k" "$v" >&2; done
echo "  -> winner: $BEST_BLOCK" >&2
echo >&2
echo -e "${GREEN}${BOLD}Best overall config:" >&2
echo "  mode=$BEST_MODE mtu=$BEST_MTU conn=$BEST_CONN block=$BEST_BLOCK" >&2
echo -e "  shared key=$KEY${NC}" >&2
echo -e "${BOLD}${CYAN}==========================================================${NC}" >&2
ok "Tuning completed."

