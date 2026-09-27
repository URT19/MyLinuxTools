#!/usr/bin/env bash
# ============================================================
# GRE Auto Optimizer V1.0 (with optional IPsec)
# Greedy multi-stage tuner for GRE / gretap tunnels
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

STATE_DIR="/run/gre-optimizer"
TEST_DURATION=10
WARMUP_DURATION=2
RUNS_PER_PROFILE=1
DEBUG="${DEBUG:-0}"
ENABLE_BASELINE="${BASELINE:-1}"

TUN_NAME="gre1"
TUN_LOCAL_IP="172.31.255.2"     # on Kharej
TUN_REMOTE_IP="172.31.255.1"    # on Iran
TUN_PREFIX=30
IRAN_IFACE_LOCAL_IP=""          # autodetected later

IPSEC_KEY="${IPSEC_KEY:-}"
IPSEC_SPI_OUT="0x1001"
IPSEC_SPI_IN="0x1002"
IPSEC_REQID="1"

# ---- Overrides ----
OVERRIDE_GRE_MODE="${GRE_MODE:-}"
OVERRIDE_MTU="${MTU:-}"
OVERRIDE_IPSEC="${IPSEC:-}"
OVERRIDE_IPSEC_CIPHER="${IPSEC_CIPHER:-}"
OVERRIDE_TTL="${TTL:-}"
OVERRIDE_MASQ="${MASQ:-}"
OVERRIDE_MSS="${MSS_CLAMP:-}"
OVERRIDE_OFFLOAD="${OFFLOAD:-}"
OVERRIDE_TXQLEN="${TXQLEN:-}"
OVERRIDE_TCP_TUNED="${TCP_TUNED:-}"

# ---- Sweep lists ----
GRE_MODES=(gre)
MTUS=(1500 1476 1450 1420 1400 1380 1350 1300 1250 1200 1150)
IPSEC_MODES=(off on)
IPSEC_CIPHERS=(aes128gcm aes256gcm chacha20poly1305)
TTLS=(64 128 255)
MASQS=(off on)
MSS_CLAMPS=(off on)
OFFLOADS=(on off)
TXQLENS=(1000 5000 10000)
TCP_TUNEDS=(default tuned)

mkdir -p "$STATE_DIR"

# ============================================================
#  Helpers
# ============================================================
ssh_kh(){ sshpass -p "$IRAN_PASS" ssh \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR -o ConnectTimeout=15 \
  -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
  -p "$IRAN_PORT" "$IRAN_USER@$IRAN_IP" "$@"; }

ssh_kh_script(){ sshpass -p "$IRAN_PASS" ssh \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR -o ConnectTimeout=15 \
  -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
  -p "$IRAN_PORT" "$IRAN_USER@$IRAN_IP" bash -s; }

cleanup_local(){
  # remove any GRE/IPsec config we added locally
  ip link show "$TUN_NAME" >/dev/null 2>&1 && ip link del "$TUN_NAME" 2>/dev/null || true
  ip xfrm state flush 2>/dev/null || true
  ip xfrm policy flush 2>/dev/null || true
  pkill -TERM -f "iperf3 -s -B 0.0.0.0" 2>/dev/null || true
  pkill -TERM -f "iperf3 -s -B $TUN_LOCAL_IP" 2>/dev/null || true
  pkill -TERM -f "iperf3 -c" 2>/dev/null || true
  sleep 0.2
  pkill -KILL -f "iperf3" 2>/dev/null || true
  rm -f "$STATE_DIR"/*.pid "$STATE_DIR"/*.log 2>/dev/null || true
}

cleanup_remote(){
  ssh_kh_script <<REMOTE 2>/dev/null || true
ip link show "$TUN_NAME" >/dev/null 2>&1 && ip link del "$TUN_NAME" 2>/dev/null || true
ip xfrm state flush 2>/dev/null || true
ip xfrm policy flush 2>/dev/null || true
pkill -TERM -f iperf3 2>/dev/null || true
sleep 0.2
pkill -KILL -f iperf3 2>/dev/null || true
REMOTE
}

trap 'cleanup_local; cleanup_remote' EXIT
trap 'trap - INT TERM; warn "Interrupted."; cleanup_local; cleanup_remote; exit 130' INT TERM

find_free_tcp_port(){
  local p
  for p in $(shuf -i 20000-45000 -n 200); do
    if ! ss -Hltn | awk '{print $4}' | grep -Eq "(^|:)$p$"; then
      echo "$p"; return 0
    fi
  done
  die "No free TCP port found."
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

detect_public_ip(){
  local ip
  ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  echo "$ip"
}

detect_iface_and_mac(){
  local iface mac
  iface="$(ip -o link show | awk -F': ' '$2 != "lo" {print $2}' | head -1)"
  [[ -n "$iface" ]] || iface="eth0"
  mac="$(ip neigh show default 2>/dev/null | awk '{print $5}' | head -1)"
  [[ -n "$mac" ]] || mac="00:00:00:00:00:00"
  echo "$iface|$mac"
}

# ============================================================
#  GRE setup / teardown
# ============================================================
setup_gre_local(){
  local gre_mode="$1" mtu="$2" ttl="$3" local_ip="$4" remote_ip="$5"
  local tun_ip="$6"

  ip link show "$TUN_NAME" >/dev/null 2>&1 && ip link del "$TUN_NAME" 2>/dev/null || true

  ip tunnel add "$TUN_NAME" mode "$gre_mode" \
    remote "$remote_ip" local "$local_ip" ttl "$ttl" \
    || { warn "ip tunnel add failed (mode=$gre_mode)"; return 1; }

  ip addr add "$tun_ip/$TUN_PREFIX" dev "$TUN_NAME" 2>/dev/null || true
  ip link set "$TUN_NAME" mtu "$mtu" 2>/dev/null || true
  ip link set "$TUN_NAME" up || return 1
  ip link set "$TUN_NAME" txqueuelen 1000 2>/dev/null || true
  return 0
}

setup_gre_remote(){
  local gre_mode="$1" mtu="$2" ttl="$3" local_ip="$4" remote_ip="$5"
  local tun_ip="$6"

  ssh_kh_script <<REMOTE
ip link show "$TUN_NAME" >/dev/null 2>&1 && ip link del "$TUN_NAME" 2>/dev/null || true
ip tunnel add "$TUN_NAME" mode "$gre_mode" remote "$remote_ip" local "$local_ip" ttl "$ttl" || exit 1
ip addr add "$tun_ip/$TUN_PREFIX" dev "$TUN_NAME" 2>/dev/null || true
ip link set "$TUN_NAME" mtu "$mtu" 2>/dev/null || true
ip link set "$TUN_NAME" up || exit 1
ip link set "$TUN_NAME" txqueuelen 1000 2>/dev/null || true
REMOTE
}

teardown_gre_local(){
  ip link show "$TUN_NAME" >/dev/null 2>&1 && ip link del "$TUN_NAME" 2>/dev/null || true
}

teardown_gre_remote(){
  ssh_kh "ip link show '$TUN_NAME' >/dev/null 2>&1 && ip link del '$TUN_NAME' 2>/dev/null; true" || true
}

# ============================================================
#  IPsec (transport mode protecting GRE packets)
# ============================================================
CURRENT_IPSEC_KEY=""

gen_key_hex(){
  if [[ -n "$IPSEC_KEY" ]]; then echo "$IPSEC_KEY"; return; fi
  if [[ -z "$CURRENT_IPSEC_KEY" ]]; then
    CURRENT_IPSEC_KEY="$(openssl rand -hex 20)"
  fi
  echo "$CURRENT_IPSEC_KEY"
}

setup_ipsec_local(){
  local cipher="$1" local_ip="$2" remote_ip="$3"

  ip xfrm state flush 2>/dev/null || true
  ip xfrm policy flush 2>/dev/null || true

  local key out_alg
  key="$(gen_key_hex)"

  case "$cipher" in
    aes128gcm)        out_alg="rfc4106(gcm(aes)) $key 128";;
    aes256gcm)        out_alg="rfc4106(gcm(aes)) $key 256";;
    chacha20poly1305) out_alg="rfc7539(chacha20,poly1305) $key";;
    *) warn "Unknown IPsec cipher: $cipher"; return 1;;
  esac

  # OUT state (local -> remote), proto GRE
  ip xfrm state add src "$local_ip" dst "$remote_ip" proto esp \
    spi "$IPSEC_SPI_OUT" reqid "$IPSEC_REQID" mode transport \
    aead "$out_alg" || { warn "xfrm state add (out) failed"; return 1; }

  # IN state (remote -> local)
  ip xfrm state add src "$remote_ip" dst "$local_ip" proto esp \
    spi "$IPSEC_SPI_IN" reqid "$IPSEC_REQID" mode transport \
    aead "$out_alg" || { warn "xfrm state add (in) failed"; return 1; }

  # Policies for GRE (protocol 47)
  ip xfrm policy add dir out src "$local_ip" dst "$remote_ip" proto gre \
    tmpl proto esp reqid "$IPSEC_REQID" mode transport || return 1
  ip xfrm policy add dir in src "$remote_ip" dst "$local_ip" proto gre \
    tmpl proto esp reqid "$IPSEC_REQID" mode transport || return 1

  return 0
}

setup_ipsec_remote(){
  local cipher="$1" local_ip="$2" remote_ip="$3"

  local key
  key="$(gen_key_hex)"

  local out_alg
  case "$cipher" in
    aes128gcm)        out_alg="rfc4106(gcm(aes)) $key 128";;
    aes256gcm)        out_alg="rfc4106(gcm(aes)) $key 256";;
    chacha20poly1305) out_alg="rfc7539(chacha20,poly1305) $key";;
    *) return 1;;
  esac

  ssh_kh_script <<REMOTE
ip xfrm state flush 2>/dev/null || true
ip xfrm policy flush 2>/dev/null || true
ip xfrm state add src "$local_ip" dst "$remote_ip" proto esp spi "$IPSEC_SPI_OUT" reqid "$IPSEC_REQID" mode transport aead "$out_alg" || exit 1
ip xfrm state add src "$remote_ip" dst "$local_ip" proto esp spi "$IPSEC_SPI_IN" reqid "$IPSEC_REQID" mode transport aead "$out_alg" || exit 1
ip xfrm policy add dir out src "$local_ip" dst "$remote_ip" proto gre tmpl proto esp reqid "$IPSEC_REQID" mode transport || exit 1
ip xfrm policy add dir in src "$remote_ip" dst "$local_ip" proto gre tmpl proto esp reqid "$IPSEC_REQID" mode transport || exit 1
REMOTE
}

teardown_ipsec_local(){
  ip xfrm state flush 2>/dev/null || true
  ip xfrm policy flush 2>/dev/null || true
}

teardown_ipsec_remote(){
  ssh_kh "ip xfrm state flush 2>/dev/null; ip xfrm policy flush 2>/dev/null; true" || true
}

# ============================================================
#  Optional: MSS clamp, MASQUERADE, offload, sysctl
# ============================================================
apply_mss_clamp_local(){
  local onoff="$1"
  iptables -t mangle -D FORWARD -o "$TUN_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  if [[ "$onoff" == "on" ]]; then
    iptables -t mangle -A FORWARD -o "$TUN_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  fi
}
apply_mss_clamp_remote(){
  local onoff="$1"
  ssh_kh_script <<REMOTE
iptables -t mangle -D FORWARD -o "$TUN_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
[[ "$onoff" == "on" ]] && iptables -t mangle -A FORWARD -o "$TUN_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
true
REMOTE
}

apply_masq_local(){
  local onoff="$1"
  # cleanup any previous MASQ rule we may have added
  while iptables -t nat -D POSTROUTING -o "$TUN_NAME" -j MASQUERADE 2>/dev/null; do :; done
  if [[ "$onoff" == "on" ]]; then
    iptables -t nat -A POSTROUTING -o "$TUN_NAME" -j MASQUERADE
  fi
}

apply_offload_local(){
  local onoff="$1"
  if [[ "$onoff" == "off" ]]; then
    ethtool -K "$TUN_NAME" gro off gso off tso off 2>/dev/null || true
  else
    ethtool -K "$TUN_NAME" gro on gso on tso on 2>/dev/null || true
  fi
}

apply_txqlen_local(){
  local q="$1"
  ip link set "$TUN_NAME" txqueuelen "$q" 2>/dev/null || true
}

apply_tcp_tuning_local(){
  local mode="$1"
  if [[ "$mode" == "tuned" ]]; then
    sysctl -w net.core.rmem_max=33554432 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=33554432 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
  else
    sysctl -w net.core.rmem_max=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=212992 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_rmem="4096 131072 6291456" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304" >/dev/null 2>&1 || true
  fi
}
apply_tcp_tuning_remote(){
  local mode="$1"
  ssh_kh_script <<REMOTE
if [[ "$mode" == "tuned" ]]; then
  sysctl -w net.core.rmem_max=33554432 >/dev/null 2>&1 || true
  sysctl -w net.core.wmem_max=33554432 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432" >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432" >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
else
  sysctl -w net.core.rmem_max=212992 >/dev/null 2>&1 || true
  sysctl -w net.core.wmem_max=212992 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_rmem="4096 131072 6291456" >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304" >/dev/null 2>&1 || true
fi
true
REMOTE
}

# ============================================================
#  Connectivity check
# ============================================================
ping_tunnel_ok(){
  local from_ip="$1" to_ip="$2"
  if ! ping -c 2 -W 2 -I "$from_ip" "$to_ip" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# ============================================================
#  Baseline
# ============================================================
run_baseline_iperf(){
  local port client_json
  port="$(find_free_tcp_port)"
  client_json="$STATE_DIR/baseline.json"

  prog "Baseline iperf3 port: $port"

  cleanup_local
  cleanup_remote

  nohup iperf3 -s -B 0.0.0.0 -p "$port" \
    --idle-timeout 60 > "$STATE_DIR/iperf-baseline.log" 2>&1 &
  echo "$!" > "$STATE_DIR/iperf-baseline.pid"
  sleep 2

  local total="0" valid=0 run speed
  for ((run=1; run<=RUNS_PER_PROFILE; run++)); do
    ssh_kh "timeout $((TEST_DURATION+5)) iperf3 -c '$KHAREJ_IP' -p '$port' -t '$TEST_DURATION' -P 1 -J" > "$client_json" 2>/dev/null || true
    speed="$(parse_iperf_json "$client_json")"
    prog "Baseline run $run: $speed Mbit/s"
    if awk "BEGIN {exit !($speed > 0)}"; then
      total="$(awk "BEGIN {print $total + $speed}")"
      valid=$((valid+1))
    fi
  done

  pkill -TERM -f "iperf3 -s -B 0.0.0.0 -p $port" 2>/dev/null || true

  if (( valid > 0 )); then
    awk "BEGIN {printf \"%.2f\", $total/$valid}"
  else
    echo "0.00"
  fi
}

# ============================================================
#  Measurement
# measure_gre <mode> <mtu> <ipsec> <cipher> <ttl> <masq> <mss> <offload> <txqlen> <tcptune>
# ============================================================
measure_gre(){
  local gre_mode="$1" mtu="$2" ipsec="$3" cipher="$4" ttl="$5"
  CURRENT_IPSEC_KEY=""
  local masq="$6" mss="$7" offload="$8" txqlen="$9" tcptune="${10}"

  local port
  port="$(find_free_tcp_port)"

  # teardown everything first
  teardown_gre_local
  teardown_gre_remote
  teardown_ipsec_local
  teardown_ipsec_remote

  # IPsec first (state + policy need to exist before GRE traffic flows)
  if [[ "$ipsec" == "on" ]]; then
    setup_ipsec_local "$cipher" "$KHAREJ_IP" "$IRAN_IP" || { echo "0.00"; return; }
    setup_ipsec_remote "$cipher" "$IRAN_IP" "$KHAREJ_IP" || { echo "0.00"; return; }
  fi

  # GRE on both sides
  setup_gre_local "$gre_mode" "$mtu" "$ttl" "$KHAREJ_IP" "$IRAN_IP" "$TUN_LOCAL_IP" || { echo "0.00"; return; }
  setup_gre_remote "$gre_mode" "$mtu" "$ttl" "$IRAN_IP" "$KHAREJ_IP" "$TUN_REMOTE_IP" || { echo "0.00"; return; }

  sleep 1

  # optional tweaks
  apply_masq_local "$masq"
  apply_mss_clamp_local "$mss"
  apply_mss_clamp_remote "$mss"
  apply_offload_local "$offload"
  apply_txqlen_local "$txqlen"
  apply_tcp_tuning_local "$tcptune"
  apply_tcp_tuning_remote "$tcptune"

  # ping check
  if ! ping_tunnel_ok "$TUN_LOCAL_IP" "$TUN_REMOTE_IP"; then
    warn "Tunnel ping failed (mode=$gre_mode mtu=$mtu ipsec=$ipsec cipher=$cipher)"
    teardown_gre_local; teardown_gre_remote; teardown_ipsec_local; teardown_ipsec_remote
    echo "0.00"
    return
  fi

  # iperf3 server on Kharej bound to the tunnel IP
  pkill -TERM -f "iperf3 -s" 2>/dev/null || true
  sleep 0.2
  nohup iperf3 -s -B "$TUN_LOCAL_IP" -p "$port" \
    --idle-timeout 30 > "$STATE_DIR/iperf-$port.log" 2>&1 &
  sleep 1

  # Run iperf3 from Iran, target = tunnel IP of Kharej
  local json speed total="0" valid=0 run
  for ((run=1; run<=RUNS_PER_PROFILE; run++)); do
    json="$STATE_DIR/iperf-$$-$run.json"
    ssh_kh "timeout $((TEST_DURATION+5)) iperf3 -c '$TUN_LOCAL_IP' -p '$port' -t '$TEST_DURATION' -P 1 -J" > "$json" 2>/dev/null || true
    speed="$(parse_iperf_json "$json")"
    if awk "BEGIN {exit !($speed > 0)}"; then
      total="$(awk "BEGIN {print $total + $speed}")"
      valid=$((valid+1))
    fi
  done

  teardown_gre_local
  teardown_gre_remote
  teardown_ipsec_local
  teardown_ipsec_remote
  pkill -TERM -f "iperf3 -s -B $TUN_LOCAL_IP" 2>/dev/null || true

  if (( valid > 0 )); then
    awk "BEGIN {printf \"%.2f\", $total/$valid}"
  else
    echo "0.00"
  fi
}

# helper to use current chain with overrides
CUR_GRE_MODE="gre"
CUR_MTU=1400
CUR_IPSEC="off"
CUR_IPSEC_CIPHER="aes128gcm"
CUR_TTL=255
CUR_MASQ="off"
CUR_MSS="on"
CUR_OFFLOAD="on"
CUR_TXQLEN=1000
CUR_TCP_TUNED="default"

run_with(){
  local gre_mode="$CUR_GRE_MODE" mtu="$CUR_MTU" ipsec="$CUR_IPSEC"
  local cipher="$CUR_IPSEC_CIPHER" ttl="$CUR_TTL" masq="$CUR_MASQ"
  local mss="$CUR_MSS" offload="$CUR_OFFLOAD" txqlen="$CUR_TXQLEN"
  local tcp_tuned="$CUR_TCP_TUNED"

  local kv
  for kv in "$@"; do
    case "${kv%%=*}" in
      gre_mode) gre_mode="${kv#*=}";;
      mtu) mtu="${kv#*=}";;
      ipsec) ipsec="${kv#*=}";;
      cipher) cipher="${kv#*=}";;
      ttl) ttl="${kv#*=}";;
      masq) masq="${kv#*=}";;
      mss) mss="${kv#*=}";;
      offload) offload="${kv#*=}";;
      txqlen) txqlen="${kv#*=}";;
      tcp_tuned) tcp_tuned="${kv#*=}";;
    esac
  done

  measure_gre "$gre_mode" "$mtu" "$ipsec" "$cipher" "$ttl" "$masq" \
    "$mss" "$offload" "$txqlen" "$tcp_tuned"
}

# ============================================================
#  MAIN
# ============================================================
need_root

echo -e "${BOLD}${CYAN}" >&2
echo "==========================================================" >&2
echo "       GRE Auto Optimizer V1.0 (with optional IPsec)" >&2
echo "==========================================================" >&2
echo -e "${NC}" >&2

step "SSH details"
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
cleanup_local
cleanup_remote

ssh_kh "echo SSH_OK" >/dev/null || die "Iran SSH connection failed."

step "Installing dependencies (Kharej)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iperf3 sshpass iproute2 iptables ethtool iputils-ping \
  curl python3 openssl kmod >/dev/null
ok "Kharej dependencies installed"

step "Installing dependencies (Iran)"
ssh_kh_script <<'REMOTE'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iperf3 iproute2 iptables ethtool iputils-ping curl python3 openssl kmod >/dev/null 2>&1 || true
command -v iperf3 >/dev/null && echo IPERF3_OK || echo IPERF3_MISSING
REMOTE
ok "Iran dependencies installed"

step "Loading kernel modules"
for m in ip_gre gre esp4 xfrm_user; do
  modprobe "$m" 2>/dev/null && prog "Kharej: $m loaded" || warn "Kharej: $m not loaded (may be built-in or restricted)"
done
ssh_kh_script <<'REMOTE'
for m in ip_gre gre esp4 xfrm_user; do
  modprobe "$m" 2>/dev/null && echo "Iran: $m loaded" || echo "Iran: $m not loaded (may be built-in or restricted)"
done
REMOTE
ok "Kernel modules checked"

step "Detecting public IPs"
KHAREJ_IP="$(detect_public_ip)"
[[ -n "$KHAREJ_IP" ]] || die "Cannot detect Kharej public IP"
info "Kharej public IP: $KHAREJ_IP"
info "Iran public IP: $IRAN_IP"

# sanity: ensure this matches expectations
if [[ "$IRAN_IP" == "$KHAREJ_IP" ]]; then
  die "IRAN_IP equals Kharej public IP — check env vars"
fi

step "Enabling IP forwarding"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
ssh_kh "sysctl -w net.ipv4.ip_forward=1 >/dev/null" || true
ok "IP forwarding enabled on both sides"

# ---------------- Baseline ----------------
if [[ "$ENABLE_BASELINE" == "1" ]]; then
  step "Baseline: direct iperf3 (no tunnel)"
  BASELINE="$(run_baseline_iperf)"
  ok "Baseline (no tunnel): ${BASELINE} Mbit/s"
else
  step "Baseline: SKIPPED (BASELINE=0)"
  BASELINE="skipped"
fi

# ---------------- Stage 1: GRE mode ----------------
step "Stage 1: GRE mode sweep"
declare -a S1=()
BEST1=""; BEST1S="0.00"
if [[ -n "$OVERRIDE_GRE_MODE" ]]; then
  step "Stage 1: SKIPPED (GRE_MODE=$OVERRIDE_GRE_MODE)"
  BEST1="$OVERRIDE_GRE_MODE"; BEST1S="n/a"; CUR_GRE_MODE="$OVERRIDE_GRE_MODE"
  S1=("$OVERRIDE_GRE_MODE|skipped")
else
  for v in "${GRE_MODES[@]}"; do
    prog "gre_mode=$v"
    s="$(run_with gre_mode="$v")"
    prog "$v -> $s Mbit/s"
    S1+=("$v|$s")
    is_better "$s" "$BEST1S" && { BEST1S="$s"; BEST1="$v"; }
  done
  [[ -n "$BEST1" ]] || die "No valid GRE mode result."
  CUR_GRE_MODE="$BEST1"
  ok "Best GRE mode: $BEST1 ($BEST1S Mbit/s)"
fi

# ---------------- Stage 2: MTU ----------------
step "Stage 2: MTU sweep"
declare -a S2=()
BEST2=""; BEST2S="0.00"
if [[ -n "$OVERRIDE_MTU" ]]; then
  step "Stage 2: SKIPPED (MTU=$OVERRIDE_MTU)"
  BEST2="$OVERRIDE_MTU"; BEST2S="n/a"; CUR_MTU="$OVERRIDE_MTU"
  S2=("$OVERRIDE_MTU|skipped")
else
  for v in "${MTUS[@]}"; do
    prog "mtu=$v"
    s="$(run_with mtu="$v")"
    prog "mtu=$v -> $s Mbit/s"
    S2+=("$v|$s")
    is_better "$s" "$BEST2S" && { BEST2S="$s"; BEST2="$v"; }
  done
  [[ -n "$BEST2" ]] || die "No valid MTU result."
  CUR_MTU="$BEST2"
  ok "Best MTU: $BEST2 ($BEST2S Mbit/s)"
fi

# ---------------- Stage 3: IPsec on/off ----------------
step "Stage 3: IPsec sweep"
declare -a S3=()
BEST3=""; BEST3S="0.00"
if [[ -n "$OVERRIDE_IPSEC" ]]; then
  step "Stage 3: SKIPPED (IPSEC=$OVERRIDE_IPSEC)"
  BEST3="$OVERRIDE_IPSEC"; BEST3S="n/a"; CUR_IPSEC="$OVERRIDE_IPSEC"
  S3=("$OVERRIDE_IPSEC|skipped")
else
  for v in "${IPSEC_MODES[@]}"; do
    prog "ipsec=$v"
    s="$(run_with ipsec="$v")"
    prog "ipsec=$v -> $s Mbit/s"
    S3+=("$v|$s")
    is_better "$s" "$BEST3S" && { BEST3S="$s"; BEST3="$v"; }
  done
  [[ -n "$BEST3" ]] || die "No valid IPsec result."
  CUR_IPSEC="$BEST3"
  ok "Best IPsec: $BEST3 ($BEST3S Mbit/s)"
fi

# ---------------- Stage 4: IPsec cipher ----------------
step "Stage 4: IPsec cipher sweep"
declare -a S4=()
BEST4=""; BEST4S="0.00"
if [[ "$CUR_IPSEC" != "on" ]]; then
  step "Stage 4: SKIPPED (IPsec off)"
  CUR_IPSEC_CIPHER=""
  S4=("ipsec=off|skipped")
elif [[ -n "$OVERRIDE_IPSEC_CIPHER" ]]; then
  step "Stage 4: SKIPPED (IPSEC_CIPHER=$OVERRIDE_IPSEC_CIPHER)"
  BEST4="$OVERRIDE_IPSEC_CIPHER"; BEST4S="n/a"; CUR_IPSEC_CIPHER="$OVERRIDE_IPSEC_CIPHER"
  S4=("$OVERRIDE_IPSEC_CIPHER|skipped")
else
  for v in "${IPSEC_CIPHERS[@]}"; do
    prog "cipher=$v"
    s="$(run_with cipher="$v")"
    prog "$v -> $s Mbit/s"
    S4+=("$v|$s")
    is_better "$s" "$BEST4S" && { BEST4S="$s"; BEST4="$v"; }
  done
  [[ -n "$BEST4" ]] || die "No valid cipher result."
  CUR_IPSEC_CIPHER="$BEST4"
  ok "Best cipher: $BEST4 ($BEST4S Mbit/s)"
fi

# ---------------- Stage 5: TTL ----------------
step "Stage 5: TTL sweep"
declare -a S5=()
BEST5=""; BEST5S="0.00"
if [[ -n "$OVERRIDE_TTL" ]]; then
  step "Stage 5: SKIPPED (TTL=$OVERRIDE_TTL)"
  BEST5="$OVERRIDE_TTL"; BEST5S="n/a"; CUR_TTL="$OVERRIDE_TTL"
  S5=("$OVERRIDE_TTL|skipped")
else
  for v in "${TTLS[@]}"; do
    prog "ttl=$v"
    s="$(run_with ttl="$v")"
    prog "ttl=$v -> $s Mbit/s"
    S5+=("$v|$s")
    is_better "$s" "$BEST5S" && { BEST5S="$s"; BEST5="$v"; }
  done
  [[ -n "$BEST5" ]] || die "No valid TTL result."
  CUR_TTL="$BEST5"
  ok "Best TTL: $BEST5 ($BEST5S Mbit/s)"
fi

# ---------------- Stage 6: MASQUERADE ----------------
step "Stage 6: MASQUERADE sweep"
declare -a S6=()
BEST6=""; BEST6S="0.00"
if [[ -n "$OVERRIDE_MASQ" ]]; then
  step "Stage 6: SKIPPED (MASQ=$OVERRIDE_MASQ)"
  BEST6="$OVERRIDE_MASQ"; BEST6S="n/a"; CUR_MASQ="$OVERRIDE_MASQ"
  S6=("$OVERRIDE_MASQ|skipped")
else
  for v in "${MASQS[@]}"; do
    prog "masq=$v"
    s="$(run_with masq="$v")"
    prog "masq=$v -> $s Mbit/s"
    S6+=("$v|$s")
    is_better "$s" "$BEST6S" && { BEST6S="$s"; BEST6="$v"; }
  done
  [[ -n "$BEST6" ]] || die "No valid MASQ result."
  CUR_MASQ="$BEST6"
  ok "Best MASQ: $BEST6 ($BEST6S Mbit/s)"
fi

# ---------------- Stage 7: MSS clamp ----------------
step "Stage 7: MSS clamp sweep"
declare -a S7=()
BEST7=""; BEST7S="0.00"
if [[ -n "$OVERRIDE_MSS" ]]; then
  step "Stage 7: SKIPPED (MSS_CLAMP=$OVERRIDE_MSS)"
  BEST7="$OVERRIDE_MSS"; BEST7S="n/a"; CUR_MSS="$OVERRIDE_MSS"
  S7=("$OVERRIDE_MSS|skipped")
else
  for v in "${MSS_CLAMPS[@]}"; do
    prog "mss_clamp=$v"
    s="$(run_with mss="$v")"
    prog "mss_clamp=$v -> $s Mbit/s"
    S7+=("$v|$s")
    is_better "$s" "$BEST7S" && { BEST7S="$s"; BEST7="$v"; }
  done
  [[ -n "$BEST7" ]] || die "No valid MSS result."
  CUR_MSS="$BEST7"
  ok "Best MSS clamp: $BEST7 ($BEST7S Mbit/s)"
fi

# ---------------- Stage 8: offload ----------------
step "Stage 8: offload sweep"
declare -a S8=()
BEST8=""; BEST8S="0.00"
if [[ -n "$OVERRIDE_OFFLOAD" ]]; then
  step "Stage 8: SKIPPED (OFFLOAD=$OVERRIDE_OFFLOAD)"
  BEST8="$OVERRIDE_OFFLOAD"; BEST8S="n/a"; CUR_OFFLOAD="$OVERRIDE_OFFLOAD"
  S8=("$OVERRIDE_OFFLOAD|skipped")
else
  for v in "${OFFLOADS[@]}"; do
    prog "offload=$v"
    s="$(run_with offload="$v")"
    prog "offload=$v -> $s Mbit/s"
    S8+=("$v|$s")
    is_better "$s" "$BEST8S" && { BEST8S="$s"; BEST8="$v"; }
  done
  [[ -n "$BEST8" ]] || die "No valid offload result."
  CUR_OFFLOAD="$BEST8"
  ok "Best offload: $BEST8 ($BEST8S Mbit/s)"
fi

# ---------------- Stage 9: txqueuelen ----------------
step "Stage 9: txqueuelen sweep"
declare -a S9=()
BEST9=""; BEST9S="0.00"
if [[ -n "$OVERRIDE_TXQLEN" ]]; then
  step "Stage 9: SKIPPED (TXQLEN=$OVERRIDE_TXQLEN)"
  BEST9="$OVERRIDE_TXQLEN"; BEST9S="n/a"; CUR_TXQLEN="$OVERRIDE_TXQLEN"
  S9=("$OVERRIDE_TXQLEN|skipped")
else
  for v in "${TXQLENS[@]}"; do
    prog "txqueuelen=$v"
    s="$(run_with txqlen="$v")"
    prog "txqueuelen=$v -> $s Mbit/s"
    S9+=("$v|$s")
    is_better "$s" "$BEST9S" && { BEST9S="$s"; BEST9="$v"; }
  done
  [[ -n "$BEST9" ]] || die "No valid txqueuelen result."
  CUR_TXQLEN="$BEST9"
  ok "Best txqueuelen: $BEST9 ($BEST9S Mbit/s)"
fi

# ---------------- Stage 10: TCP sysctl ----------------
step "Stage 10: TCP sysctl sweep"
declare -a S10=()
BEST10=""; BEST10S="0.00"
if [[ -n "$OVERRIDE_TCP_TUNED" ]]; then
  step "Stage 10: SKIPPED (TCP_TUNED=$OVERRIDE_TCP_TUNED)"
  BEST10="$OVERRIDE_TCP_TUNED"; BEST10S="n/a"; CUR_TCP_TUNED="$OVERRIDE_TCP_TUNED"
  S10=("$OVERRIDE_TCP_TUNED|skipped")
else
  for v in "${TCP_TUNEDS[@]}"; do
    prog "tcp_tuned=$v"
    s="$(run_with tcp_tuned="$v")"
    prog "tcp_tuned=$v -> $s Mbit/s"
    S10+=("$v|$s")
    is_better "$s" "$BEST10S" && { BEST10S="$s"; BEST10="$v"; }
  done
  [[ -n "$BEST10" ]] || die "No valid TCP sysctl result."
  CUR_TCP_TUNED="$BEST10"
  ok "Best TCP tuning: $BEST10 ($BEST10S Mbit/s)"
fi

# ============================================================
#  FINAL REPORT
# ============================================================
cleanup_local
cleanup_remote

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
    printf '  %-24s %10s Mbit/s\n' "$k" "$v" >&2
  done
}

print_stage "Stage 1 - GRE mode"    "${S1[@]}";  echo "  -> $CUR_GRE_MODE" >&2; echo >&2
print_stage "Stage 2 - MTU"         "${S2[@]}";  echo "  -> $CUR_MTU" >&2; echo >&2
print_stage "Stage 3 - IPsec"       "${S3[@]}";  echo "  -> $CUR_IPSEC" >&2; echo >&2
print_stage "Stage 4 - IPsec cipher" "${S4[@]}"; echo "  -> ${CUR_IPSEC_CIPHER:-n/a}" >&2; echo >&2
print_stage "Stage 5 - TTL"         "${S5[@]}";  echo "  -> $CUR_TTL" >&2; echo >&2
print_stage "Stage 6 - MASQUERADE"  "${S6[@]}";  echo "  -> $CUR_MASQ" >&2; echo >&2
print_stage "Stage 7 - MSS clamp"   "${S7[@]}";  echo "  -> $CUR_MSS" >&2; echo >&2
print_stage "Stage 8 - offload"     "${S8[@]}";  echo "  -> $CUR_OFFLOAD" >&2; echo >&2
print_stage "Stage 9 - txqueuelen"  "${S9[@]}";  echo "  -> $CUR_TXQLEN" >&2; echo >&2
print_stage "Stage 10 - TCP sysctl" "${S10[@]}"; echo "  -> $CUR_TCP_TUNED" >&2; echo >&2

echo -e "${GREEN}${BOLD}Best overall config:" >&2
echo "  gre_mode=$CUR_GRE_MODE mtu=$CUR_MTU ipsec=$CUR_IPSEC" >&2
[[ "$CUR_IPSEC" == "on" ]] && echo "  cipher=$CUR_IPSEC_CIPHER" >&2
echo "  ttl=$CUR_TTL masq=$CUR_MASQ mss_clamp=$CUR_MSS" >&2
echo -e "  offload=$CUR_OFFLOAD txqueuelen=$CUR_TXQLEN tcp_tuned=$CUR_TCP_TUNED${NC}" >&2
echo >&2
echo "Ready-to-use setup commands:" >&2
echo >&2
echo "==========================================================" >&2
echo "Kharej side (${KHAREJ_IP})" >&2
echo "==========================================================" >&2
echo "sysctl -w net.ipv4.ip_forward=1" >&2
echo "ip tunnel del $TUN_NAME 2>/dev/null || true" >&2
echo "ip tunnel add $TUN_NAME mode $CUR_GRE_MODE remote $IRAN_IP local $KHAREJ_IP ttl $CUR_TTL" >&2
echo "ip addr add $TUN_LOCAL_IP/$TUN_PREFIX dev $TUN_NAME" >&2
echo "ip link set $TUN_NAME mtu $CUR_MTU up" >&2
echo "ip link set $TUN_NAME txqueuelen $CUR_TXQLEN" >&2
if [[ "$CUR_OFFLOAD" == "off" ]]; then
  echo "ethtool -K $TUN_NAME gro off gso off tso off" >&2
fi
echo >&2
if [[ "$CUR_MSS" == "on" ]]; then
  echo "iptables -t mangle -C FORWARD -o $TUN_NAME -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \" >&2
  echo "  iptables -t mangle -A FORWARD -o $TUN_NAME -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" >&2
fi
if [[ "$CUR_MASQ" == "on" ]]; then
  echo "iptables -t nat -C POSTROUTING -o $TUN_NAME -j MASQUERADE 2>/dev/null || \" >&2
  echo "  iptables -t nat -A POSTROUTING -o $TUN_NAME -j MASQUERADE" >&2
fi
if [[ "$CUR_TCP_TUNED" == "tuned" ]]; then
  echo "sysctl -w net.core.rmem_max=33554432" >&2
  echo "sysctl -w net.core.wmem_max=33554432" >&2
  echo "sysctl -w net.ipv4.tcp_rmem='4096 87380 33554432'" >&2
  echo "sysctl -w net.ipv4.tcp_wmem='4096 65536 33554432'" >&2
  echo "sysctl -w net.ipv4.tcp_mtu_probing=1" >&2
fi
echo >&2
if [[ "$CUR_IPSEC" == "on" ]]; then
  echo "--- IPsec (transport mode over GRE, proto 47) ---" >&2
  echo "# generate key once, use on both sides:" >&2
  echo "#   KEY=\$(openssl rand -hex 20)" >&2
  echo "ip xfrm state flush; ip xfrm policy flush" >&2
  echo "ip xfrm state add src $KHAREJ_IP dst $IRAN_IP proto esp spi $IPSEC_SPI_OUT reqid $IPSEC_REQID mode transport aead \"<CIPHER_ALG> <KEY> <KEYBITS>\"" >&2
  echo "ip xfrm state add src $IRAN_IP dst $KHAREJ_IP proto esp spi $IPSEC_SPI_IN  reqid $IPSEC_REQID mode transport aead \"<CIPHER_ALG> <KEY> <KEYBITS>\"" >&2
  echo "ip xfrm policy add dir out src $KHAREJ_IP dst $IRAN_IP proto gre tmpl proto esp reqid $IPSEC_REQID mode transport" >&2
  echo "ip xfrm policy add dir in  src $IRAN_IP dst $KHAREJ_IP proto gre tmpl proto esp reqid $IPSEC_REQID mode transport" >&2
  case "$CUR_IPSEC_CIPHER" in
    aes128gcm)        echo "# CIPHER_ALG=rfc4106(gcm(aes))  KEYBITS=128" >&2;;
    aes256gcm)        echo "# CIPHER_ALG=rfc4106(gcm(aes))  KEYBITS=256" >&2;;
    chacha20poly1305) echo "# CIPHER_ALG=rfc7539(chacha20,poly1305)  KEYBITS=(omit)" >&2;;
  esac
fi
echo >&2
echo "==========================================================" >&2
echo "Iran side (${IRAN_IP})" >&2
echo "==========================================================" >&2
echo "sysctl -w net.ipv4.ip_forward=1" >&2
echo "ip tunnel del $TUN_NAME 2>/dev/null || true" >&2
echo "ip tunnel add $TUN_NAME mode $CUR_GRE_MODE remote $KHAREJ_IP local $IRAN_IP ttl $CUR_TTL" >&2
echo "ip addr add $TUN_REMOTE_IP/$TUN_PREFIX dev $TUN_NAME" >&2
echo "ip link set $TUN_NAME mtu $CUR_MTU up" >&2
echo "ip link set $TUN_NAME txqueuelen $CUR_TXQLEN" >&2
if [[ "$CUR_OFFLOAD" == "off" ]]; then
  echo "ethtool -K $TUN_NAME gro off gso off tso off" >&2
fi
echo >&2
if [[ "$CUR_MSS" == "on" ]]; then
  echo "iptables -t mangle -C FORWARD -o $TUN_NAME -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \" >&2
  echo "  iptables -t mangle -A FORWARD -o $TUN_NAME -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" >&2
fi
if [[ "$CUR_MASQ" == "on" ]]; then
  echo "iptables -t nat -C POSTROUTING -o $TUN_NAME -j MASQUERADE 2>/dev/null || \" >&2
  echo "  iptables -t nat -A POSTROUTING -o $TUN_NAME -j MASQUERADE" >&2
fi
if [[ "$CUR_TCP_TUNED" == "tuned" ]]; then
  echo "sysctl -w net.core.rmem_max=33554432" >&2
  echo "sysctl -w net.core.wmem_max=33554432" >&2
  echo "sysctl -w net.ipv4.tcp_rmem='4096 87380 33554432'" >&2
  echo "sysctl -w net.ipv4.tcp_wmem='4096 65536 33554432'" >&2
  echo "sysctl -w net.ipv4.tcp_mtu_probing=1" >&2
fi
echo >&2
if [[ "$CUR_IPSEC" == "on" ]]; then
  echo "--- IPsec (transport mode over GRE, proto 47) ---" >&2
  echo "ip xfrm state flush; ip xfrm policy flush" >&2
  echo "ip xfrm state add src $IRAN_IP dst $KHAREJ_IP proto esp spi $IPSEC_SPI_OUT reqid $IPSEC_REQID mode transport aead \"<CIPHER_ALG> <KEY> <KEYBITS>\"" >&2
  echo "ip xfrm state add src $KHAREJ_IP dst $IRAN_IP proto esp spi $IPSEC_SPI_IN  reqid $IPSEC_REQID mode transport aead \"<CIPHER_ALG> <KEY> <KEYBITS>\"" >&2
  echo "ip xfrm policy add dir out src $IRAN_IP dst $KHAREJ_IP proto gre tmpl proto esp reqid $IPSEC_REQID mode transport" >&2
  echo "ip xfrm policy add dir in  src $KHAREJ_IP dst $IRAN_IP proto gre tmpl proto esp reqid $IPSEC_REQID mode transport" >&2
fi
echo >&2
echo "==========================================================" >&2
echo "Notes" >&2
echo "==========================================================" >&2
echo "- Replace <KEY> and <CIPHER_ALG> with the values you generated." >&2
echo "- <KEYBITS> = 128 for aes128gcm, 256 for aes256gcm; omit for chacha20poly1305." >&2
echo "- After applying IPsec on both sides, verify with:" >&2
echo "    ping -I $TUN_LOCAL_IP $TUN_REMOTE_IP     # from Kharej" >&2
echo "    ip xfrm state; ip xfrm policy" >&2
echo "- To persist sysctl across reboots, add them to /etc/sysctl.conf." >&2
echo "- To persist iptables, use iptables-save > /etc/iptables/rules.v4" >&2
echo -e "${BOLD}${CYAN}==========================================================${NC}" >&2
ok "Tuning completed."

