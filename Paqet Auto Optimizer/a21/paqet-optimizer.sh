#!/usr/bin/env bash
# ============================================================
# Paqet Auto Optimizer V3.0
# For hanselime/paqet v1.0.0-alpha.21
# Baseline + Greedy Multi-Stage Tuner
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
PAQET_VERSION="v1.0.0-alpha.21"
BIN_DIR="$WORKDIR/bin/$PAQET_VERSION"
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
PAQET_DOWNLOAD_URL="https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.21/paqet-linux-amd64-v1.0.0-alpha.21.tar.gz"

# ---- Overrides ----
OVERRIDE_MODE="${MODE:-}"
OVERRIDE_MTU="${MTU:-}"
OVERRIDE_SNDWND="${SNDWND:-}"
OVERRIDE_RCVWND="${RCVWND:-}"
OVERRIDE_CONN="${CONN:-}"
OVERRIDE_BLOCK="${BLOCK:-}"
OVERRIDE_NODELAY="${NODELAY:-}"
OVERRIDE_INTERVAL="${INTERVAL:-}"
OVERRIDE_RESEND="${RESEND:-}"
OVERRIDE_NOCONG="${NOCONG:-}"
OVERRIDE_WDELAY="${WDELAY:-}"
OVERRIDE_ACKNODELAY="${ACKNODELAY:-}"
OVERRIDE_SMUXBUF="${SMUXBUF:-}"
OVERRIDE_STREAMBUF="${STREAMBUF:-}"
ENABLE_BASELINE="${BASELINE:-1}"   # 1=run baseline, 0=skip

# ---- Sweep lists ----
MODES=("normal" "fast" "fast2" "fast3" "manual")
MTUS=(1500 1450 1400 1350 1300 1250 1200 1150)
SNDWNDS=(128 256 512 1024 2048 4096)
RCVWNDS=(512 1024 2048 4096)
CONNS=(1 2 4 8)
BLOCKS=("aes" "xor" "none")

# manual-mode sweeps
MANUAL_NODELAYS=(0 1)
MANUAL_INTERVALS=(5 10 20)
MANUAL_RESENDS=(0 1 2)
MANUAL_NOCONGS=(0 1)
MANUAL_WDELAYS=(false true)
MANUAL_ACKNODELAYS=(true false)

SMUXBUFS=(4194304 8388608 16777216)
STREAMBUFS=(2097152 4194304 8388608)

mkdir -p "$STATE_DIR" "$CONFIG_DIR"

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

setup_iptables_server(){
  local port="$1"
  iptables -t raw -C PREROUTING -p tcp --dport "$port" -j NOTRACK 2>/dev/null || \
    iptables -t raw -A PREROUTING -p tcp --dport "$port" -j NOTRACK
  iptables -t raw -C OUTPUT -p tcp --sport "$port" -j NOTRACK 2>/dev/null || \
    iptables -t raw -A OUTPUT -p tcp --sport "$port" -j NOTRACK
  iptables -t mangle -C OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || \
    iptables -t mangle -A OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP
}

cleanup_iptables_server(){
  local port="$1"
  while iptables -t raw -D PREROUTING -p tcp --dport "$port" -j NOTRACK 2>/dev/null; do :; done
  while iptables -t raw -D OUTPUT -p tcp --sport "$port" -j NOTRACK 2>/dev/null; do :; done
  while iptables -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null; do :; done
}

# ---- Config generation ----
# Args: out listen_port server_ip mode mtu snd rcv conn block
#       nodelay interval resend nocong wdelay acknodelay smuxbuf streambuf
#       iface ip_addr router_mac role
generate_config(){
  local out="$1" listen_port="$2" server_ip="$3"
  local mode="$4" mtu="$5" snd="$6" rcv="$7" conn="$8" block="$9"
  local nodelay="${10}" interval="${11}" resend="${12}" nocong="${13}"
  local wdelay="${14}" acknodelay="${15}" smuxbuf="${16}" streambuf="${17}"
  local iface="${18}" ip_addr="${19}" router_mac="${20}" role="${21}"

  local manual_extra=""
  if [[ "$mode" == "manual" ]]; then
    manual_extra=$(cat <<MEOF
    nodelay: $nodelay
    interval: $interval
    resend: $resend
    nocongestion: $nocong
    wdelay: $wdelay
    acknodelay: $acknodelay
MEOF
)
  fi

  if [[ "$role" == "server" ]]; then
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
    mode: "$mode"
    mtu: $mtu
    sndwnd: $snd
    rcvwnd: $rcv
    block: "$block"
    key: "$KEY"
    smuxbuf: $smuxbuf
    streambuf: $streambuf
$manual_extra
EOF
  else
    cat > "$out" <<EOF
role: "client"
log:
  level: "info"
forward:
  - listen: "127.0.0.1:$listen_port"
    target: "127.0.0.1:50001"
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
  addr: "$server_ip"
transport:
  protocol: "kcp"
  conn: $conn
  kcp:
    mode: "$mode"
    mtu: $mtu
    sndwnd: $snd
    rcvwnd: $rcv
    block: "$block"
    key: "$KEY"
    smuxbuf: $smuxbuf
    streambuf: $streambuf
$manual_extra
EOF
  fi
}

debug_pause(){
  [[ "${DEBUG:-0}" == "1" ]] || return 0
  echo >&2
  echo "---- DEBUG PAUSE ----" >&2
  echo "kcp_port=$kcp_port iperf_port=$iperf_port client_port=$client_port" >&2
  echo "mode=$mode mtu=$mtu snd=$snd rcv=$rcv conn=$conn block=$block" >&2
  echo "KHAREJ_IP=$KHAREJ_IP" >&2
  echo "--- local processes ---" >&2
  ps -ef | grep -E "paqet|iperf3 -s" | grep -v grep >&2 || true
  echo "--- local server config ---" >&2
  cat "$CONFIG_DIR/server-$kcp_port.yaml" >&2 2>/dev/null || true
  echo "--- local server log ---" >&2
  tail -10 "$STATE_DIR/paqet-server-$kcp_port.log" >&2 2>/dev/null || true
  echo "--- remote client config ---" >&2
  remote_exec "cat '$REMOTE_DIR/test/client-$client_port.yaml' 2>/dev/null || true" >&2 || true
  echo "--- remote client log ---" >&2
  remote_exec "tail -10 '$REMOTE_DIR/test/paqet-client-$client_port.log' 2>/dev/null || true" >&2 || true
  echo "Press Enter to continue (or Ctrl+C to abort)..." >&2
  read -r _ || true
}

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

# Args: mode mtu snd rcv conn block nodelay interval resend nocong wdelay acknodelay smuxbuf streambuf
measure_paqet(){
  local mode="$1" mtu="$2" snd="$3" rcv="$4" conn="$5" block="$6"
  local nodelay="$7" interval="$8" resend="$9" nocong="${10}"
  local wdelay="${11}" acknodelay="${12}" smuxbuf="${13}" streambuf="${14}"

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
    cleanup_iptables_server "$kcp_port"
    setup_iptables_server "$kcp_port"

    nohup iperf3 -s -B 127.0.0.1 -p "$iperf_port" \
      --idle-timeout 30 > "$STATE_DIR/iperf-$iperf_port.log" 2>&1 &
    echo "$!" > "$STATE_DIR/iperf-$iperf_port.pid"

    local server_config="$CONFIG_DIR/server-$kcp_port.yaml"
    generate_config "$server_config" "$kcp_port" "$KHAREJ_IP" \
      "$mode" "$mtu" "$snd" "$rcv" "$conn" "$block" \
      "$nodelay" "$interval" "$resend" "$nocong" "$wdelay" "$acknodelay" \
      "$smuxbuf" "$streambuf" "$iface" "$ip_addr" "$router_mac" "server"

    nohup "$PAQET_BIN" run -c "$server_config" \
      >"$STATE_DIR/paqet-server-$kcp_port.log" 2>&1 &
    echo "$!" > "$STATE_DIR/paqet-server.pid"

    sleep 2

    local client_config="$CONFIG_DIR/client-$client_port.yaml"
    generate_config "$client_config" "$client_port" "$KHAREJ_IP:$kcp_port" \
      "$mode" "$mtu" "$snd" "$rcv" "$conn" "$block" \
      "$nodelay" "$interval" "$resend" "$nocong" "$wdelay" "$acknodelay" \
      "$smuxbuf" "$streambuf" "$remote_iface" "$remote_ip" "$remote_router_mac" "client"

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
echo "       Paqet Auto Optimizer V3.0 (hanselime v1.0.0-alpha.21)" >&2
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
apt-get install -y -qq curl wget iperf3 sshpass jq lsof net-tools bc python3 iproute2 iptables >/dev/null
ok "Kharej dependencies installed"

remote_exec_script <<'REMOTE'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iperf3 python3 curl iproute2 iptables >/dev/null 2>&1 || true
command -v iperf3 >/dev/null && echo IPERF3_OK || echo IPERF3_MISSING
REMOTE
ok "Iran dependencies installed"

step "Downloading Paqet binary"
mkdir -p "$BIN_DIR"
rm -f "$PAQET_BIN"
cd "$BIN_DIR"
TARBALL="paqet-linux-amd64-${PAQET_VERSION}.tar.gz"
TMP_EXTRACT="$(mktemp -d)"
curl -L -o "$TMP_EXTRACT/$TARBALL" "$PAQET_DOWNLOAD_URL"
tar -xzf "$TMP_EXTRACT/$TARBALL" -C "$TMP_EXTRACT"
BIN_FOUND="$(find "$TMP_EXTRACT" -maxdepth 3 -type f -name 'paqet*' ! -name '*.tar.gz' | head -1)"
[[ -n "$BIN_FOUND" ]] || die "paqet binary not found in tarball"
mv -f "$BIN_FOUND" "$PAQET_BIN"
chmod +x "$PAQET_BIN"
rm -rf "$TMP_EXTRACT"
ok "Paqet binary ready: $PAQET_BIN"
"$PAQET_BIN" version || true

step "Preparing Iran server"
remote_exec "mkdir -p '$REMOTE_BIN_DIR' '$REMOTE_DIR/test'" || die "Cannot prepare remote dirs."
remote_exec "pkill -TERM -f 'paqet run' 2>/dev/null || true"
remote_copy_atomic "$PAQET_BIN" "$PAQET_REMOTE_BIN"

step "Detecting Kharej public IP"
KHAREJ_IP="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$KHAREJ_IP" ]] || KHAREJ_IP="$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo UNKNOWN)"
info "Kharej public IP: $KHAREJ_IP"

if [[ "$ENABLE_BASELINE" == "1" ]]; then
  step "Baseline: direct iperf3 (no tunnel)"
  BASELINE="$(run_baseline_iperf)"
  ok "Baseline (no tunnel): ${BASELINE} Mbit/s"
else
  step "Baseline: SKIPPED (BASELINE=0)"
  BASELINE="skipped"
fi

# defaults for the "current best" chain
CUR_MODE="fast"; CUR_MTU=1350; CUR_SND=1024; CUR_RCV=1024
CUR_CONN=4; CUR_BLOCK="aes"
CUR_NODELAY=1; CUR_INTERVAL=10; CUR_RESEND=2; CUR_NOCONG=1
CUR_WDELAY="false"; CUR_ACKNODELAY="true"
CUR_SMUXBUF=4194304; CUR_STREAMBUF=2097152

# ---- helper to invoke measurement using current best chain ----
run_with(){
  # positional overrides as "k=v"
  local mode="$CUR_MODE" mtu="$CUR_MTU" snd="$CUR_SND" rcv="$CUR_RCV"
  local conn="$CUR_CONN" block="$CUR_BLOCK"
  local nd="$CUR_NODELAY" iv="$CUR_INTERVAL" rs="$CUR_RESEND" ncg="$CUR_NOCONG"
  local wd="$CUR_WDELAY" ak="$CUR_ACKNODELAY" sm="$CUR_SMUXBUF" st="$CUR_STREAMBUF"

  local kv
  for kv in "$@"; do
    case "${kv%%=*}" in
      mode) mode="${kv#*=}";;
      mtu) mtu="${kv#*=}";;
      snd) snd="${kv#*=}";;
      rcv) rcv="${kv#*=}";;
      conn) conn="${kv#*=}";;
      block) block="${kv#*=}";;
      nodelay) nd="${kv#*=}";;
      interval) iv="${kv#*=}";;
      resend) rs="${kv#*=}";;
      nocong) ncg="${kv#*=}";;
      wdelay) wd="${kv#*=}";;
      acknodelay) ak="${kv#*=}";;
      smuxbuf) sm="${kv#*=}";;
      streambuf) st="${kv#*=}";;
    esac
  done

  measure_paqet "$mode" "$mtu" "$snd" "$rcv" "$conn" "$block" \
    "$nd" "$iv" "$rs" "$ncg" "$wd" "$ak" "$sm" "$st"
}

declare -a RESULTS=()

# ============================================================
#  Stage 1: Mode
# ============================================================
step "Stage 1: Mode sweep"
declare -a MODE_RESULTS=()
BEST_MODE_SPEED="0.00"
BEST_MODE=""

if [[ -n "$OVERRIDE_MODE" ]]; then
  step "Stage 1: Mode sweep SKIPPED (MODE=$OVERRIDE_MODE)"
  BEST_MODE="$OVERRIDE_MODE"; BEST_MODE_SPEED="n/a"; CUR_MODE="$OVERRIDE_MODE"
  MODE_RESULTS=("$OVERRIDE_MODE|skipped")
else
  set +e
  for m in "${MODES[@]}"; do
    prog "Mode '$m'"
    speed="$(run_with mode="$m")"
    prog "$m -> $speed Mbit/s"
    MODE_RESULTS+=("$m|$speed")
    if is_better "$speed" "$BEST_MODE_SPEED"; then
      BEST_MODE_SPEED="$speed"; BEST_MODE="$m"
    fi
  done
  set -e
  [[ -n "$BEST_MODE" ]] || die "No valid Mode result."
  CUR_MODE="$BEST_MODE"
  ok "Best Mode: $BEST_MODE (${BEST_MODE_SPEED} Mbit/s)"
fi

# ============================================================
#  Stage 1b: Manual-mode sub-sweep (only if mode=manual)
# ============================================================
if [[ "$CUR_MODE" == "manual" ]]; then
  step "Stage 1b: Manual-mode sub-parameter sweep"

  # nodelay
  if [[ -z "$OVERRIDE_NODELAY" ]]; then
    best_s="0.00"; best_v=""
    for v in "${MANUAL_NODELAYS[@]}"; do
      prog "nodelay=$v"
      s="$(run_with nodelay="$v")"
      prog "nodelay=$v -> $s Mbit/s"
      is_better "$s" "$best_s" && { best_s="$s"; best_v="$v"; }
    done
    [[ -n "$best_v" ]] && CUR_NODELAY="$best_v"
    ok "Best nodelay: $CUR_NODELAY ($best_s Mbit/s)"
  fi

  # interval
  if [[ -z "$OVERRIDE_INTERVAL" ]]; then
    best_s="0.00"; best_v=""
    for v in "${MANUAL_INTERVALS[@]}"; do
      prog "interval=$v"
      s="$(run_with interval="$v")"
      prog "interval=$v -> $s Mbit/s"
      is_better "$s" "$best_s" && { best_s="$s"; best_v="$v"; }
    done
    [[ -n "$best_v" ]] && CUR_INTERVAL="$best_v"
    ok "Best interval: $CUR_INTERVAL ($best_s Mbit/s)"
  fi

  # resend
  if [[ -z "$OVERRIDE_RESEND" ]]; then
    best_s="0.00"; best_v=""
    for v in "${MANUAL_RESENDS[@]}"; do
      prog "resend=$v"
      s="$(run_with resend="$v")"
      prog "resend=$v -> $s Mbit/s"
      is_better "$s" "$best_s" && { best_s="$s"; best_v="$v"; }
    done
    [[ -n "$best_v" ]] && CUR_RESEND="$best_v"
    ok "Best resend: $CUR_RESEND ($best_s Mbit/s)"
  fi

  # nocongestion
  if [[ -z "$OVERRIDE_NOCONG" ]]; then
    best_s="0.00"; best_v=""
    for v in "${MANUAL_NOCONGS[@]}"; do
      prog "nocongestion=$v"
      s="$(run_with nocong="$v")"
      prog "nocongestion=$v -> $s Mbit/s"
      is_better "$s" "$best_s" && { best_s="$s"; best_v="$v"; }
    done
    [[ -n "$best_v" ]] && CUR_NOCONG="$best_v"
    ok "Best nocongestion: $CUR_NOCONG ($best_s Mbit/s)"
  fi

  # wdelay
  if [[ -z "$OVERRIDE_WDELAY" ]]; then
    best_s="0.00"; best_v=""
    for v in "${MANUAL_WDELAYS[@]}"; do
      prog "wdelay=$v"
      s="$(run_with wdelay="$v")"
      prog "wdelay=$v -> $s Mbit/s"
      is_better "$s" "$best_s" && { best_s="$s"; best_v="$v"; }
    done
    [[ -n "$best_v" ]] && CUR_WDELAY="$best_v"
    ok "Best wdelay: $CUR_WDELAY ($best_s Mbit/s)"
  fi

  # acknodelay
  if [[ -z "$OVERRIDE_ACKNODELAY" ]]; then
    best_s="0.00"; best_v=""
    for v in "${MANUAL_ACKNODELAYS[@]}"; do
      prog "acknodelay=$v"
      s="$(run_with acknodelay="$v")"
      prog "acknodelay=$v -> $s Mbit/s"
      is_better "$s" "$best_s" && { best_s="$s"; best_v="$v"; }
    done
    [[ -n "$best_v" ]] && CUR_ACKNODELAY="$best_v"
    ok "Best acknodelay: $CUR_ACKNODELAY ($best_s Mbit/s)"
  fi
fi

# ============================================================
#  Stage 2: MTU
# ============================================================
step "Stage 2: MTU sweep"
declare -a MTU_RESULTS=()
BEST_MTU_SPEED="0.00"; BEST_MTU=""

if [[ -n "$OVERRIDE_MTU" ]]; then
  step "Stage 2: MTU sweep SKIPPED (MTU=$OVERRIDE_MTU)"
  BEST_MTU="$OVERRIDE_MTU"; BEST_MTU_SPEED="n/a"; CUR_MTU="$OVERRIDE_MTU"
  MTU_RESULTS=("$OVERRIDE_MTU|skipped")
else
  set +e
  for mtu in "${MTUS[@]}"; do
    prog "MTU=$mtu"
    speed="$(run_with mtu="$mtu")"
    prog "mtu=$mtu -> $speed Mbit/s"
    MTU_RESULTS+=("$mtu|$speed")
    is_better "$speed" "$BEST_MTU_SPEED" && { BEST_MTU_SPEED="$speed"; BEST_MTU="$mtu"; }
  done
  set -e
  [[ -n "$BEST_MTU" ]] || die "No valid MTU result."
  CUR_MTU="$BEST_MTU"
  ok "Best MTU: $BEST_MTU (${BEST_MTU_SPEED} Mbit/s)"
fi

# ============================================================
#  Stage 3: SNDWND
# ============================================================
step "Stage 3: sndwnd sweep"
declare -a SND_RESULTS=()
BEST_SND_SPEED="0.00"; BEST_SND=""

if [[ -n "$OVERRIDE_SNDWND" ]]; then
  step "Stage 3: sndwnd sweep SKIPPED (SNDWND=$OVERRIDE_SNDWND)"
  BEST_SND="$OVERRIDE_SNDWND"; BEST_SND_SPEED="n/a"; CUR_SND="$OVERRIDE_SNDWND"
  SND_RESULTS=("$OVERRIDE_SNDWND|skipped")
else
  set +e
  for v in "${SNDWNDS[@]}"; do
    prog "sndwnd=$v"
    speed="$(run_with snd="$v")"
    prog "sndwnd=$v -> $speed Mbit/s"
    SND_RESULTS+=("$v|$speed")
    is_better "$speed" "$BEST_SND_SPEED" && { BEST_SND_SPEED="$speed"; BEST_SND="$v"; }
  done
  set -e
  [[ -n "$BEST_SND" ]] || die "No valid sndwnd result."
  CUR_SND="$BEST_SND"
  ok "Best sndwnd: $BEST_SND (${BEST_SND_SPEED} Mbit/s)"
fi

# ============================================================
#  Stage 4: RCVWND
# ============================================================
step "Stage 4: rcvwnd sweep"
declare -a RCV_RESULTS=()
BEST_RCV_SPEED="0.00"; BEST_RCV=""

if [[ -n "$OVERRIDE_RCVWND" ]]; then
  step "Stage 4: rcvwnd sweep SKIPPED (RCVWND=$OVERRIDE_RCVWND)"
  BEST_RCV="$OVERRIDE_RCVWND"; BEST_RCV_SPEED="n/a"; CUR_RCV="$OVERRIDE_RCVWND"
  RCV_RESULTS=("$OVERRIDE_RCVWND|skipped")
else
  set +e
  for v in "${RCVWNDS[@]}"; do
    prog "rcvwnd=$v"
    speed="$(run_with rcv="$v")"
    prog "rcvwnd=$v -> $speed Mbit/s"
    RCV_RESULTS+=("$v|$speed")
    is_better "$speed" "$BEST_RCV_SPEED" && { BEST_RCV_SPEED="$speed"; BEST_RCV="$v"; }
  done
  set -e
  [[ -n "$BEST_RCV" ]] || die "No valid rcvwnd result."
  CUR_RCV="$BEST_RCV"
  ok "Best rcvwnd: $BEST_RCV (${BEST_RCV_SPEED} Mbit/s)"
fi

# ============================================================
#  Stage 5: CONN
# ============================================================
step "Stage 5: conn sweep"
declare -a CONN_RESULTS=()
BEST_CONN_SPEED="0.00"; BEST_CONN=""

if [[ -n "$OVERRIDE_CONN" ]]; then
  step "Stage 5: conn sweep SKIPPED (CONN=$OVERRIDE_CONN)"
  BEST_CONN="$OVERRIDE_CONN"; BEST_CONN_SPEED="n/a"; CUR_CONN="$OVERRIDE_CONN"
  CONN_RESULTS=("$OVERRIDE_CONN|skipped")
else
  set +e
  for v in "${CONNS[@]}"; do
    prog "conn=$v"
    speed="$(run_with conn="$v")"
    prog "conn=$v -> $speed Mbit/s"
    CONN_RESULTS+=("$v|$speed")
    is_better "$speed" "$BEST_CONN_SPEED" && { BEST_CONN_SPEED="$speed"; BEST_CONN="$v"; }
  done
  set -e
  [[ -n "$BEST_CONN" ]] || die "No valid conn result."
  CUR_CONN="$BEST_CONN"
  ok "Best conn: $BEST_CONN (${BEST_CONN_SPEED} Mbit/s)"
fi

# ============================================================
#  Stage 6: BLOCK
# ============================================================
step "Stage 6: block sweep"
declare -a BLOCK_RESULTS=()
BEST_BLOCK_SPEED="0.00"; BEST_BLOCK=""

if [[ -n "$OVERRIDE_BLOCK" ]]; then
  step "Stage 6: block sweep SKIPPED (BLOCK=$OVERRIDE_BLOCK)"
  BEST_BLOCK="$OVERRIDE_BLOCK"; BEST_BLOCK_SPEED="n/a"; CUR_BLOCK="$OVERRIDE_BLOCK"
  BLOCK_RESULTS=("$OVERRIDE_BLOCK|skipped")
else
  set +e
  for v in "${BLOCKS[@]}"; do
    prog "block=$v"
    speed="$(run_with block="$v")"
    prog "block=$v -> $speed Mbit/s"
    BLOCK_RESULTS+=("$v|$speed")
    is_better "$speed" "$BEST_BLOCK_SPEED" && { BEST_BLOCK_SPEED="$speed"; BEST_BLOCK="$v"; }
  done
  set -e
  [[ -n "$BEST_BLOCK" ]] || die "No valid block result."
  CUR_BLOCK="$BEST_BLOCK"
  ok "Best block: $BEST_BLOCK (${BEST_BLOCK_SPEED} Mbit/s)"
fi

# ============================================================
#  Stage 7: SMUXBUF
# ============================================================
step "Stage 7: smuxbuf sweep"
declare -a SMUX_RESULTS=()
BEST_SMUX_SPEED="0.00"; BEST_SMUX=""

if [[ -n "$OVERRIDE_SMUXBUF" ]]; then
  step "Stage 7: smuxbuf sweep SKIPPED (SMUXBUF=$OVERRIDE_SMUXBUF)"
  BEST_SMUX="$OVERRIDE_SMUXBUF"; BEST_SMUX_SPEED="n/a"; CUR_SMUXBUF="$OVERRIDE_SMUXBUF"
  SMUX_RESULTS=("$OVERRIDE_SMUXBUF|skipped")
else
  set +e
  for v in "${SMUXBUFS[@]}"; do
    prog "smuxbuf=$v"
    speed="$(run_with smuxbuf="$v")"
    prog "smuxbuf=$v -> $speed Mbit/s"
    SMUX_RESULTS+=("$v|$speed")
    is_better "$speed" "$BEST_SMUX_SPEED" && { BEST_SMUX_SPEED="$speed"; BEST_SMUX="$v"; }
  done
  set -e
  [[ -n "$BEST_SMUX" ]] || die "No valid smuxbuf result."
  CUR_SMUXBUF="$BEST_SMUX"
  ok "Best smuxbuf: $BEST_SMUX (${BEST_SMUX_SPEED} Mbit/s)"
fi

# ============================================================
#  Stage 8: STREAMBUF
# ============================================================
step "Stage 8: streambuf sweep"
declare -a STREAM_RESULTS=()
BEST_STREAM_SPEED="0.00"; BEST_STREAM=""

if [[ -n "$OVERRIDE_STREAMBUF" ]]; then
  step "Stage 8: streambuf sweep SKIPPED (STREAMBUF=$OVERRIDE_STREAMBUF)"
  BEST_STREAM="$OVERRIDE_STREAMBUF"; BEST_STREAM_SPEED="n/a"; CUR_STREAMBUF="$OVERRIDE_STREAMBUF"
  STREAM_RESULTS=("$OVERRIDE_STREAMBUF|skipped")
else
  set +e
  for v in "${STREAMBUFS[@]}"; do
    prog "streambuf=$v"
    speed="$(run_with streambuf="$v")"
    prog "streambuf=$v -> $speed Mbit/s"
    STREAM_RESULTS+=("$v|$speed")
    is_better "$speed" "$BEST_STREAM_SPEED" && { BEST_STREAM_SPEED="$speed"; BEST_STREAM="$v"; }
  done
  set -e
  [[ -n "$BEST_STREAM" ]] || die "No valid streambuf result."
  CUR_STREAMBUF="$BEST_STREAM"
  ok "Best streambuf: $BEST_STREAM (${BEST_STREAM_SPEED} Mbit/s)"
fi

cleanup_local_test
remote_test_cleanup

echo >&2
echo -e "${BOLD}${CYAN}==========================================================" >&2
echo "                 FINAL REPORT" >&2
echo "==========================================================${NC}" >&2
if [[ "$BASELINE" == "skipped" ]]; then
  echo "Baseline (no tunnel) : skipped" >&2
else
  echo "Baseline (no tunnel) : $BASELINE Mbit/s" >&2
fi
echo >&2

print_stage(){
  local title="$1"; shift
  echo "$title:" >&2
  local r
  for r in "$@"; do
    local k="${r%%|*}" v="${r##*|}"
    printf '  %-22s %10s Mbit/s\n' "$k" "$v" >&2
  done
}
print_stage "Stage 1 - Mode"   "${MODE_RESULTS[@]}"
echo "  -> winner: $CUR_MODE" >&2; echo >&2
print_stage "Stage 2 - MTU"    "${MTU_RESULTS[@]}"
echo "  -> winner: $CUR_MTU" >&2; echo >&2
print_stage "Stage 3 - sndwnd" "${SND_RESULTS[@]}"
echo "  -> winner: $CUR_SND" >&2; echo >&2
print_stage "Stage 4 - rcvwnd" "${RCV_RESULTS[@]}"
echo "  -> winner: $CUR_RCV" >&2; echo >&2
print_stage "Stage 5 - conn"   "${CONN_RESULTS[@]}"
echo "  -> winner: $CUR_CONN" >&2; echo >&2
print_stage "Stage 6 - block"  "${BLOCK_RESULTS[@]}"
echo "  -> winner: $CUR_BLOCK" >&2; echo >&2
print_stage "Stage 7 - smuxbuf" "${SMUX_RESULTS[@]}"
echo "  -> winner: $CUR_SMUXBUF" >&2; echo >&2
print_stage "Stage 8 - streambuf" "${STREAM_RESULTS[@]}"
echo "  -> winner: $CUR_STREAMBUF" >&2; echo >&2

echo -e "${GREEN}${BOLD}Best overall config:" >&2
echo "  mode=$CUR_MODE mtu=$CUR_MTU sndwnd=$CUR_SND rcvwnd=$CUR_RCV" >&2
echo "  conn=$CUR_CONN block=$CUR_BLOCK smuxbuf=$CUR_SMUXBUF streambuf=$CUR_STREAMBUF" >&2
if [[ "$CUR_MODE" == "manual" ]]; then
  echo "  nodelay=$CUR_NODELAY interval=$CUR_INTERVAL resend=$CUR_RESEND" >&2
  echo "  nocongestion=$CUR_NOCONG wdelay=$CUR_WDELAY acknodelay=$CUR_ACKNODELAY" >&2
fi
echo "  shared key=$KEY${NC}" >&2
echo -e "${BOLD}${CYAN}==========================================================${NC}" >&2
ok "Tuning completed."


