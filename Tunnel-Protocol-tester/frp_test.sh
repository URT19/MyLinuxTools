#!/bin/bash

# ============================================================
# FRP Multi-Protocol Tunnel Tester v2.4
# Protocols: TCP | KCP | QUIC | WebSocket
# Better non-root (sudo) support
# Example Command
# bash frp_test.sh --iran-host IP.IP.IP.IP --iran-port 22 --iran-user root --iran-pass 'PASSWORD'
# ============================================================

set -uo pipefail

# --------------- Colors ---------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --------------- Globals ---------------
FRP_VERSION="0.71.0"
BIN_DIR="/opt/frp_tester/bin"
WORK_DIR="/tmp/frp_test_$$"
LOG="${WORK_DIR}/debug.log"

declare -A RESULTS
TCP_PORT=""
KCP_PORT=""
QUIC_PORT=""
TEST_PORT=""
TOKEN=""

mkdir -p "$WORK_DIR" "$BIN_DIR"
exec > >(tee -a "$LOG") 2>&1

# --------------- Helpers ---------------
log() {
    local level=$1
    shift
    local msg="$*"
    local ts=$(date '+%H:%M:%S')
    case $level in
        INFO)  echo -e "${CYAN}[${ts}]${NC}  $msg" ;;
        OK)    echo -e "${GREEN}[${ts}]${NC}  $msg" ;;
        WARN)  echo -e "${YELLOW}[${ts}]${NC}  $msg" ;;
        ERR)   echo -e "${RED}[${ts}]${NC}  $msg" ;;
        *)     echo -e "[${ts}]  $msg" ;;
    esac
}

banner() {
    clear
    echo -e "${CYAN}"
    echo "  ███████╗██████╗ ██████╗     ████████╗███████╗███████╗████████╗"
    echo "  ██╔════╝██╔══██╗██╔══██╗    ╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝"
    echo "  █████╗  ██████╔╝██████╔╝       ██║   █████╗  ███████╗   ██║   "
    echo "  ██╔══╝  ██╔══██╗██╔═══╝        ██║   ██╔══╝  ╚════██║   ██║   "
    echo "  ██║     ██║  ██║██║            ██║   ███████╗███████║   ██║   "
    echo "  ╚═╝     ╚═╝  ╚═╝╚═╝            ╚═╝   ╚══════╝╚══════╝   ╚═╝   "
    echo -e "${YELLOW}          Multi-Protocol FRP Tunnel Tester  v2.4${NC}"
    echo -e "${DIM}          TCP • KCP • QUIC • WebSocket${NC}"
    echo
}

# --------------- SSH Helpers ---------------
ssh_cmd() {
    sshpass -p "$IRAN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
        -p "$IRAN_PORT" "${IRAN_USER}@${IRAN_HOST}" "$@"
}

# Run command with sudo -i if needed
remote_sudo() {
    local cmd="$1"
    ssh_cmd "sudo -i bash -c $(printf '%q' "$cmd")"
}

# --------------- Main ---------------
banner

IRAN_HOST=""
IRAN_PORT=22
IRAN_USER="root"
IRAN_PASS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --iran-host) IRAN_HOST="$2"; shift 2 ;;
        --iran-port) IRAN_PORT="$2"; shift 2 ;;
        --iran-user) IRAN_USER="$2"; shift 2 ;;
        --iran-pass) IRAN_PASS="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$IRAN_HOST" || -z "$IRAN_PASS" ]]; then
    echo -e "${YELLOW}Enter IRAN server details:${NC}"
    read -p "IP / Domain          : " IRAN_HOST
    read -p "SSH Port        [22] : " tmp; IRAN_PORT=${tmp:-22}
    read -p "SSH User      [root] : " tmp; IRAN_USER=${tmp:-root}
    read -sp "SSH Password         : " IRAN_PASS
    echo; echo
fi

echo -e "Target Server : ${BOLD}${IRAN_USER}@${IRAN_HOST}:${IRAN_PORT}${NC}"
echo -e "Log File      : ${DIM}${LOG}${NC}"
echo

# ========== 1. SSH Test ==========
echo -e "${BOLD}[1/7] SSH Connection${NC}"
if ssh_cmd "echo SSH_OK" 2>/dev/null | grep -q "SSH_OK"; then
    log OK "SSH connection successful"
else
    log ERR "Cannot connect via SSH"
    exit 1
fi
echo

# ========== 2. Local FRP ==========
echo -e "${BOLD}[2/7] Local FRP Binary${NC}"
if [[ -x "$BIN_DIR/frps" && -x "$BIN_DIR/frpc" ]]; then
    log OK "Found $($BIN_DIR/frps -v 2>/dev/null | head -1)"
else
    log INFO "Downloading FRP v${FRP_VERSION}..."
    ARCH=$(uname -m)
    case $ARCH in x86_64) ARCH="amd64";; aarch64) ARCH="arm64";; *) log ERR "Unsupported arch"; exit 1;; esac
    wget -q "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${ARCH}.tar.gz" -O /tmp/frp.tar.gz
    tar -xzf /tmp/frp.tar.gz -C /tmp
    cp /tmp/frp_*/frps /tmp/frp_*/frpc "$BIN_DIR/"
    chmod +x "$BIN_DIR"/frps "$BIN_DIR"/frpc
    rm -rf /tmp/frp*
    log OK "FRP installed"
fi
echo

# ========== 3. Sync to Remote (with sudo support) ==========
echo -e "${BOLD}[3/7] Sync FRP to Remote${NC}"

# Kill old process and prepare directories using sudo
ssh_cmd "sudo pkill -f $BIN_DIR/frps 2>/dev/null || true" 2>/dev/null || true
ssh_cmd "sudo mkdir -p $BIN_DIR /tmp/frp_upload && sudo chown $IRAN_USER:$IRAN_USER /tmp/frp_upload" 2>/dev/null || true

# Upload to /tmp (user has permission)
sshpass -p "$IRAN_PASS" scp -o StrictHostKeyChecking=no -P "$IRAN_PORT" \
    "$BIN_DIR/frps" "$BIN_DIR/frpc" \
    "${IRAN_USER}@${IRAN_HOST}:/tmp/frp_upload/" 2>/dev/null

if [[ $? -ne 0 ]]; then
    log ERR "SCP upload failed"
    exit 1
fi

# Move to final location with sudo
ssh_cmd "sudo cp /tmp/frp_upload/frps /tmp/frp_upload/frpc $BIN_DIR/ && \
         sudo chmod +x $BIN_DIR/frps $BIN_DIR/frpc && \
         sudo rm -rf /tmp/frp_upload" 2>/dev/null

# Verify
REMOTE_VER=$(ssh_cmd "sudo $BIN_DIR/frps -v 2>/dev/null || $BIN_DIR/frps -v 2>/dev/null" | head -1)
if [[ -n "$REMOTE_VER" ]]; then
    log OK "Remote version: $REMOTE_VER"
else
    log ERR "Failed to install FRP on remote server"
    exit 1
fi
echo

# ========== 4. Ports ==========
echo -e "${BOLD}[4/7] Generate Ports${NC}"
TCP_PORT=$(shuf -i 45000-52000 -n 1)
KCP_PORT=$(shuf -i 53000-56000 -n 1)
QUIC_PORT=$(shuf -i 57000-60000 -n 1)
TEST_PORT=$(shuf -i 40000-44000 -n 1)
TOKEN=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)

printf "  %-12s %s\n" "TCP/WS:"     "$TCP_PORT"
printf "  %-12s %s\n" "KCP:"        "$KCP_PORT"
printf "  %-12s %s\n" "QUIC:"       "$QUIC_PORT"
printf "  %-12s %s\n" "Test:"       "$TEST_PORT"
printf "  %-12s %s\n" "Token:"      "$TOKEN"
echo

# ========== 5. Firewall ==========
echo -e "${BOLD}[5/7] Firewall (UFW)${NC}"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow $TCP_PORT/tcp  >/dev/null 2>&1
    ufw allow $KCP_PORT/udp  >/dev/null 2>&1
    ufw allow $QUIC_PORT/udp >/dev/null 2>&1
    ufw allow $TEST_PORT/tcp >/dev/null 2>&1
    log OK "Local ports opened"
else
    log INFO "Local UFW not active"
fi

ssh_cmd "sudo ufw allow $TCP_PORT/tcp >/dev/null 2>&1
         sudo ufw allow $KCP_PORT/udp >/dev/null 2>&1
         sudo ufw allow $QUIC_PORT/udp >/dev/null 2>&1
         sudo ufw allow $TEST_PORT/tcp >/dev/null 2>&1
         echo DONE" 2>/dev/null | grep -q DONE && log OK "Remote ports opened" || log INFO "Remote UFW skip"
echo

# ========== 6. Start frps ==========
echo -e "${BOLD}[6/7] Start frps on Remote${NC}"

REMOTE_SCRIPT=$(cat << EOF
#!/bin/bash
sudo pkill -f "$BIN_DIR/frps" 2>/dev/null || true
sleep 1
sudo mkdir -p $WORK_DIR
sudo chown $IRAN_USER:$IRAN_USER $WORK_DIR 2>/dev/null || true

cat > $WORK_DIR/frps.toml << TOML
bindAddr = "0.0.0.0"
bindPort = $TCP_PORT
kcpBindPort = $KCP_PORT
quicBindPort = $QUIC_PORT
auth.method = "token"
auth.token = "$TOKEN"
transport.tcpMux = true
TOML

sudo nohup $BIN_DIR/frps -c $WORK_DIR/frps.toml > $WORK_DIR/frps.log 2>&1 &
echo \$! > $WORK_DIR/frps.pid
sleep 3

if sudo kill -0 \$(cat $WORK_DIR/frps.pid) 2>/dev/null || kill -0 \$(cat $WORK_DIR/frps.pid) 2>/dev/null; then
    echo "REMOTE_OK"
else
    echo "REMOTE_FAIL"
    cat $WORK_DIR/frps.log 2>/dev/null || sudo cat $WORK_DIR/frps.log 2>/dev/null
fi
EOF
)

RESULT=$(ssh_cmd "bash -s" <<< "$REMOTE_SCRIPT" 2>&1)

if echo "$RESULT" | grep -q "REMOTE_OK"; then
    log OK "frps started successfully"
else
    log ERR "frps failed to start"
    echo "$RESULT"
    exit 1
fi

# Wait for slow servers
echo
log INFO "Waiting 8 seconds for remote server to become fully ready..."
sleep 8
log OK "Remote server should be ready now"
echo

# ========== 7. Tests ==========
echo -e "${BOLD}[7/7] Protocol Tests${NC}"
pkill -f "nc -l -p $TEST_PORT" 2>/dev/null || true
while true; do
    echo "FRP-TEST-OK" | nc -l -p $TEST_PORT -q 1 2>/dev/null || true
done &
NC_PID=$!
sleep 1
log OK "Test service ready on port $TEST_PORT"
echo

run_test() {
    local proto=$1
    local port=$2
    local name=$3

    printf "  %-12s " "$name"

    cat > "$WORK_DIR/frpc.toml" << EOF
serverAddr = "$IRAN_HOST"
serverPort = $port
auth.method = "token"
auth.token = "$TOKEN"
transport.protocol = "$proto"
transport.tcpMux = true
loginFailExit = false

[[proxies]]
name = "test"
type = "tcp"
localIP = "127.0.0.1"
localPort = $TEST_PORT
remotePort = $TEST_PORT
EOF

    timeout 18 "$BIN_DIR/frpc" -c "$WORK_DIR/frpc.toml" > "$WORK_DIR/frpc_${proto}.log" 2>&1 &
    local pid=$!
    sleep 8

    local status="FAILED"
    if kill -0 $pid 2>/dev/null; then
        if timeout 5 bash -c "echo ping | nc -w 3 $IRAN_HOST $TEST_PORT" 2>/dev/null | grep -q "FRP-TEST-OK"; then
            status="SUCCESS"
        elif grep -qE "login to server success|start proxy success" "$WORK_DIR/frpc_${proto}.log" 2>/dev/null; then
            status="SUCCESS"
        fi
    fi

    RESULTS["$name"]="$status"

    if [[ "$status" == "SUCCESS" ]]; then
        echo -e "${GREEN}✔  SUCCESS${NC}"
    else
        echo -e "${RED}✘  FAILED${NC}"
        if [[ -f "$WORK_DIR/frpc_${proto}.log" ]]; then
            echo -e "${DIM}$(tail -6 "$WORK_DIR/frpc_${proto}.log" | sed 's/^/      /')${NC}"
        fi
    fi

    kill $pid 2>/dev/null || true
    sleep 2
}

run_test "tcp"       "$TCP_PORT"  "TCP"
run_test "kcp"       "$KCP_PORT"  "KCP"
run_test "quic"      "$QUIC_PORT" "QUIC"
run_test "websocket" "$TCP_PORT"  "WebSocket"

# ========== Final Report ==========
echo
echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║           FINAL TEST RESULTS               ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════╝${NC}"
echo

printf "  ${BOLD}%-14s %-12s${NC}\n" "PROTOCOL" "STATUS"
echo -e "  ${DIM}────────────────────────────${NC}"

for proto in TCP KCP QUIC WebSocket; do
    status="${RESULTS[$proto]:-UNKNOWN}"
    if [[ "$status" == "SUCCESS" ]]; then
        printf "  %-14s ${GREEN}%-12s${NC}\n" "$proto" "✔  SUCCESS"
    else
        printf "  %-14s ${RED}%-12s${NC}\n" "$proto" "✘  FAILED"
    fi
done

echo
echo -e "${DIM}────────────────────────────────────────────${NC}"
echo -e "  Server   : ${IRAN_HOST}"
echo -e "  TCP Port : ${TCP_PORT}"
echo -e "  KCP Port : ${KCP_PORT}"
echo -e "  QUIC Port: ${QUIC_PORT}"
echo -e "  Log      : ${LOG}"
echo -e "${DIM}────────────────────────────────────────────${NC}"
echo

kill $NC_PID 2>/dev/null || true
