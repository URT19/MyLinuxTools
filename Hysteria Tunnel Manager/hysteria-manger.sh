#!/usr/bin/env bash
# =====================================================================
#  Hysteria 2 Interactive Manager  (v5.0)
#
#  Typical setup (two machines):
#    1) FOREIGN server  -> run this script, choose option 1 (Server)
#    2) IRAN server     -> run this script, choose option 2 (Client/Relay)
#
#  Traffic flow:
#    User -> Iran server (forwarded port) -> Hysteria tunnel -> Foreign server -> Internet
# =====================================================================

HYSTERIA_BIN="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hysteria"
SERVICE_DIR="/etc/systemd/system"
FALLBACK_TAG="app/v2.6.0"
INFO_FILE="$CONFIG_DIR/server-info.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------
info() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
note() { echo -e "${CYAN}    $*${NC}"; }
pause() { read -rp "Press Enter to continue..." _; }

print_header() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}    Hysteria 2 Interactive Manager      ${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# confirm "question" [default y|n]
confirm() {
    local def=${2:-n} r
    read -rp "$1 (y/n) [default: $def]: " r
    r=${r:-$def}
    [[ "$r" =~ ^[Yy]$ ]]
}

# ask "prompt" "default" VARNAME   (no eval -> safe against injection)
ask() {
    local prompt=$1 default=$2 __var=$3 reply
    if [[ -n "$default" ]]; then
        read -rp "$prompt [default: $default]: " reply
        reply=${reply:-$default}
    else
        read -rp "$prompt: " reply
    fi
    printf -v "$__var" '%s' "$reply"
}

# ask_valid "prompt" "default" VARNAME validator_function
# Repeats until the value is non-empty and passes the validator.
ask_valid() {
    local prompt=$1 default=$2 __var=$3 validator=$4 val
    while true; do
        ask "$prompt" "$default" val
        if [[ -z "$val" ]]; then
            err "This value cannot be empty."
            continue
        fi
        if "$validator" "$val"; then
            break
        fi
        err "Invalid value, please try again."
    done
    printf -v "$__var" '%s' "$val"
}

# ---------------------------------------------------------------------
#  Validators
# ---------------------------------------------------------------------
is_port()         { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
is_positive_int() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 )); }
is_bandwidth()    { [[ "$1" =~ ^[0-9]+[[:space:]]?[A-Za-z]+$ ]]; }
is_domain()       { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }
is_url()          { [[ "$1" =~ ^https?://[^[:space:]\"\\]+$ ]]; }
is_password()     { [[ "$1" != *\"* && "$1" != *\\* ]]; }
is_pin()          { [[ "$1" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ || "$1" =~ ^[0-9A-Fa-f]{64}$ ]]; }

# Accepts HOST:PORT or HOST:START-END (port hopping range)
is_server_addr() {
    local a=$1 host port lo hi
    [[ "$a" == *:* ]] || return 1
    host=${a%:*}
    port=${a##*:}
    [[ -n "$host" ]] || return 1
    if [[ "$port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        lo=${BASH_REMATCH[1]}
        hi=${BASH_REMATCH[2]}
        is_port "$lo" && is_port "$hi" && (( 10#$lo < 10#$hi ))
    else
        is_port "$port"
    fi
}

backup_file() {
    [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%s)" && note "Existing file backed up: $1.bak.*"
}

# ---------------------------------------------------------------------
#  Installation
# ---------------------------------------------------------------------
install_deps() {
    local missing=() c
    for c in curl wget jq openssl; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    (( ${#missing[@]} == 0 )) && return 0

    info "Installing missing packages: ${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${missing[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${missing[@]}"
    else
        err "No supported package manager found. Please install manually: ${missing[*]}"
        return 1
    fi
}

install_hysteria() {
    install_deps || exit 1

    local tag bin url tmp
    tag=$(curl -fsSL --max-time 15 https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null | jq -r .tag_name 2>/dev/null)
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        warn "Could not query the latest version. Falling back to $FALLBACK_TAG"
        tag="$FALLBACK_TAG"
    fi

    case "$(uname -m)" in
        x86_64|amd64)  bin="hysteria-linux-amd64" ;;
        aarch64|arm64) bin="hysteria-linux-arm64" ;;
        *) err "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac

    url="https://github.com/apernet/hysteria/releases/download/${tag}/${bin}"
    info "Downloading $url"
    tmp=$(mktemp)
    if wget -q --show-progress -O "$tmp" "$url" && [[ -s "$tmp" ]]; then
        install -m 755 "$tmp" "$HYSTERIA_BIN"
        rm -f "$tmp"
        info "Installed: $("$HYSTERIA_BIN" version 2>/dev/null | head -n 1)"
    else
        rm -f "$tmp"
        err "Download failed."
        note "If GitHub is blocked/unreachable from this server:"
        note "  1) Download '$bin' on another machine,"
        note "  2) Upload it to this server as $HYSTERIA_BIN"
        note "  3) Run: chmod +x $HYSTERIA_BIN   and start this script again."
        exit 1
    fi
}

check_installed() {
    if [[ ! -x "$HYSTERIA_BIN" ]]; then
        err "Hysteria 2 is not installed at $HYSTERIA_BIN"
        if confirm "Download and install the latest release from GitHub now?" y; then
            install_hysteria
        else
            echo "Aborting."
            exit 1
        fi
    fi
}

# ---------------------------------------------------------------------
#  Menus with explanations
# ---------------------------------------------------------------------
# select_bandwidth "context"   -> sets BW_RESULT
select_bandwidth() {
    local ctx=$1 c
    echo -e "\n${YELLOW}Select bandwidth (same value for upload and download)${NC}"
    note "What this means: Hysteria sends data at the speed you declare here"
    note "(it does NOT auto-detect). Use the REAL speed of ${ctx}."
    note "  - Too HIGH  -> packet loss, unstable connection, slow speed."
    note "  - Too LOW   -> you waste available speed."
    note "Not sure? Run a speedtest on the server and use ~80-90% of the result."
    echo "  1) 128 mbps"
    echo "  2) 256 mbps"
    echo "  3) 512 mbps"
    echo "  4) 768 mbps"
    echo "  5) 1024 mbps (1 gbps)"
    echo "  6) 1536 mbps"
    echo "  7) 2048 mbps"
    echo "  8) Custom value"
    read -rp "Selection [default: 3 = 512 mbps]: " c
    case "$c" in
        1) BW_RESULT="128mbps" ;;
        2) BW_RESULT="256mbps" ;;
        4) BW_RESULT="768mbps" ;;
        5) BW_RESULT="1024mbps" ;;
        6) BW_RESULT="1536mbps" ;;
        7) BW_RESULT="2048mbps" ;;
        8) ask_valid "Enter custom bandwidth (examples: 100mbps, 2gbps)" "" BW_RESULT is_bandwidth ;;
        *) BW_RESULT="512mbps" ;;
    esac
    info "Bandwidth set to: $BW_RESULT"
}

# select_sni  -> sets SNI_RESULT
select_sni() {
    local c
    echo -e "\n${YELLOW}Select SNI (the website name your traffic will pretend to visit)${NC}"
    note "What this means: the SNI is the domain announced during the TLS handshake."
    note "It makes the tunnel look like normal HTTPS traffic to that site."
    note "Tips:"
    note "  - Choose a popular site that is normally reachable and used a lot."
    note "  - Best practice: use the SAME site as the 'Masquerade URL' you set on"
    note "    the foreign server (the server setup prints a suggested SNI for you)."
    echo "  1) play.google.com    (Google Play)"
    echo "  2) speedtest.net      (Ookla Speedtest)"
    echo "  3) www.cloudflare.com (Cloudflare)"
    echo "  4) www.microsoft.com  (Microsoft)"
    echo "  5) dl.discordapp.net  (Discord CDN)"
    echo "  6) Custom SNI"
    read -rp "Selection [default: 1]: " c
    case "$c" in
        2) SNI_RESULT="speedtest.net" ;;
        3) SNI_RESULT="www.cloudflare.com" ;;
        4) SNI_RESULT="www.microsoft.com" ;;
        5) SNI_RESULT="dl.discordapp.net" ;;
        6) ask_valid "Enter custom SNI (domain only, e.g. example.com)" "" SNI_RESULT is_domain ;;
        *) SNI_RESULT="play.google.com" ;;
    esac
    info "SNI set to: $SNI_RESULT"
}

# ---------------------------------------------------------------------
#  Systemd + firewall
# ---------------------------------------------------------------------
create_service() {
    local name=$1 cmd=$2

    cat > "$SERVICE_DIR/$name.service" << EOF
[Unit]
Description=Hysteria 2 Service ($name)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$cmd
Restart=always
RestartSec=5
Nice=-10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$name" >/dev/null 2>&1
    systemctl restart "$name"
    sleep 2
    if systemctl is-active --quiet "$name"; then
        info "Service '$name' is active and running."
    else
        err "Service '$name' failed to start. Last log lines:"
        journalctl -u "$name" -n 15 --no-pager
    fi
}

open_firewall_udp() {
    local port=$1
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        confirm "UFW is active. Open UDP port $port now?" y && ufw allow "${port}/udp"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        confirm "firewalld is active. Open UDP port $port now?" y && \
            { firewall-cmd --permanent --add-port="${port}/udp" && firewall-cmd --reload; }
    else
        warn "No active UFW/firewalld detected. Make sure UDP port $port is open"
        warn "(also in your hosting provider's panel / security group, if any)."
    fi
}

# ---------------------------------------------------------------------
#  1) SERVER (foreign server)
# ---------------------------------------------------------------------
manage_server() {
    echo -e "${YELLOW}=== Server Setup (run this on the FOREIGN server) ===${NC}"
    note "This server accepts the tunnel coming from your Iran relay server."
    local config_file="$CONFIG_DIR/server-config.yaml"

    if [[ ! -f "$CONFIG_DIR/self.crt" || ! -f "$CONFIG_DIR/self.key" ]]; then
        info "Generating a 10-year self-signed certificate..."
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$CONFIG_DIR/self.key" \
            -out "$CONFIG_DIR/self.crt" \
            -subj "/CN=myserver" 2>/dev/null
        chmod 600 "$CONFIG_DIR/self.key"
        chmod 644 "$CONFIG_DIR/self.crt"
    fi
    local fingerprint
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$CONFIG_DIR/self.crt" | cut -d'=' -f2)

    echo -e "\n${YELLOW}[1/5] Listen port${NC}"
    note "The UDP port Hysteria listens on. The Iran server will connect to it."
    note "Any free port from 1-65535 works. A random one is suggested."
    local def_port
    def_port=$(shuf -i 10000-65000 -n 1)
    ask_valid "Listen port (UDP)" "$def_port" LISTEN_PORT is_port

    echo -e "\n${YELLOW}[2/5] Obfuscation password (gecko)${NC}"
    note "Scrambles the packets so they are harder to fingerprint."
    note "You must enter the SAME value on the Iran server. Avoid \" and \\ characters."
    ask_valid "Obfs password" "$(openssl rand -hex 12)" OBFS_PASS is_password

    echo -e "\n${YELLOW}[3/5] Authentication password${NC}"
    note "The password the Iran server uses to log in. Keep it secret."
    note "You must enter the SAME value on the Iran server. Avoid \" and \\ characters."
    ask_valid "Auth password" "$(openssl rand -hex 12)" AUTH_PASS is_password

    echo -e "\n${YELLOW}[4/5] Masquerade URL${NC}"
    note "If someone probes your server like a normal website, Hysteria will"
    note "answer by proxying this site, so the server looks like a regular web server."
    note "Use a big, reachable site, e.g. https://play.google.com"
    ask_valid "Masquerade URL (must start with https://)" "https://play.google.com" MASQ_URL is_url

    echo -e "\n${YELLOW}[5/5] Bandwidth${NC}"
    select_bandwidth "this FOREIGN server's internet connection"
    local speed=$BW_RESULT

    backup_file "$config_file"
    cat > "$config_file" << EOC
listen: ":$LISTEN_PORT"

tls:
  cert: $CONFIG_DIR/self.crt
  key: $CONFIG_DIR/self.key

obfs:
  type: gecko
  gecko:
    password: "$OBFS_PASS"
    minPacketSize: 512
    maxPacketSize: 1200

masquerade:
  type: proxy
  proxy:
    url: "$MASQ_URL"
    rewriteHost: true

auth:
  type: password
  password: "$AUTH_PASS"

quic:
  initStreamReceiveWindow: 50331648
  maxStreamReceiveWindow: 100663296
  initConnReceiveWindow: 100663296
  maxConnReceiveWindow: 201326592
  maxIdleTimeout: 30s
  maxIncomingStreams: 8192
  disablePathMTUDiscovery: false

bandwidth:
  up: $speed
  down: $speed

speedTest: true
EOC
    chmod 600 "$config_file"
    info "Server configuration written to $config_file"

    if confirm "Open the config in nano to review/edit?" n; then
        nano "$config_file"
    fi

    create_service "hysteria-server" "$HYSTERIA_BIN server --config $config_file"
    open_firewall_udp "$LISTEN_PORT"

    local public_ip suggested_sni
    public_ip=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")
    suggested_sni=${MASQ_URL#*://}
    suggested_sni=${suggested_sni%%/*}

    {
        echo "FOREIGN SERVER INFO - enter these values on the IRAN server (menu option 2)"
        echo "Generated: $(date)"
        echo "----------------------------------------------------------------"
        echo "Server address (IP:port) : ${public_ip}:${LISTEN_PORT}"
        echo "Auth password            : $AUTH_PASS"
        echo "Obfs password            : $OBFS_PASS"
        echo "TLS SHA256 pin           : $fingerprint"
        echo "Suggested SNI            : $suggested_sni"
        echo "Server bandwidth         : $speed"
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"

    show_server_info
    note "(This summary is saved in $INFO_FILE - menu option 6 shows it again.)"
    echo
    info "NEXT STEP: run this script on the IRAN server and choose option 2."
}

show_server_info() {
    if [[ -f "$INFO_FILE" ]]; then
        echo -e "\n${BLUE}====================================================${NC}"
        cat "$INFO_FILE"
        echo -e "${BLUE}====================================================${NC}"
    else
        warn "No saved server info found. Run server setup (option 1) on the foreign server first."
    fi
}

# ---------------------------------------------------------------------
#  2) CLIENT (Iran relay server)
# ---------------------------------------------------------------------
ask_pin() {
    local v
    while true; do
        ask "Server TLS SHA256 pin (recommended - press Enter to skip)" "" v
        [[ -z "$v" ]] && break
        is_pin "$v" && break
        err "Invalid pin. Expected 64 hex characters, e.g. AA:BB:CC:... (32 pairs)."
    done
    PIN_SHA=$v
}

# Builds FWD_TCP / FWD_UDP YAML blocks
collect_forwarding() {
    FWD_TCP=""
    FWD_UDP=""
    local count i proto lport rport entry

    echo
    note "Each rule opens a port on THIS Iran server. Anything sent to that port"
    note "travels through the tunnel and arrives at a port on the FOREIGN server."
    note "Example: your foreign server runs a panel/inbound on port 443."
    note "  -> Listen port on Iran = 443 , Destination port on foreign = 443"
    note "Users then connect to  <IRAN_SERVER_IP>:443  instead of the foreign IP."
    note "The destination is always 127.0.0.1 on the foreign server, i.e. a service"
    note "that is running on the foreign server itself."
    ask_valid "How many forwarding rules do you want to add?" "1" count is_positive_int

    for (( i = 1; i <= count; i++ )); do
        echo -e "\n${CYAN}--- Rule $i of $count ---${NC}"
        echo "Protocol:  1) TCP + UDP (default)   2) TCP only   3) UDP only"
        read -rp "Selection [default: 1]: " proto
        ask_valid "Listen port on THIS Iran server (users connect here)" "" lport is_port
        ask_valid "Destination port on the FOREIGN server (where your service runs)" "$lport" rport is_port

        entry=$'\n'"  - listen: \"0.0.0.0:${lport}\""$'\n'"    remote: \"127.0.0.1:${rport}\""
        case "$proto" in
            2) FWD_TCP+="$entry" ;;
            3) FWD_UDP+="$entry" ;;
            *) FWD_TCP+="$entry"; FWD_UDP+="$entry" ;;
        esac
    done
    warn "Remember to open these listen ports (TCP/UDP) in the Iran server's firewall."
}

manage_client() {
    echo -e "${YELLOW}=== Client Setup (run this on the IRAN relay server) ===${NC}"
    note "This server connects OUT to your foreign Hysteria server and exposes"
    note "ports locally that are tunneled to it."
    echo
    note "Have these values ready (they were printed at the end of the server setup,"
    note "or run option 6 on the foreign server to show them again):"
    note "  - Foreign server IP and port"
    note "  - Auth password        - Obfs password        - TLS SHA256 pin"

    echo -e "\n${YELLOW}[1/7] Instance number${NC}"
    note "Each tunnel gets its own number: 1, 2, 3 ..."
    note "Use 1 for your first foreign server. Use 2 if you add a second foreign"
    note "server on this same machine. It creates the service 'hysteria-client<N>'."
    ask_valid "Instance number" "1" num is_positive_int
    local config_file="$CONFIG_DIR/client${num}-config.yaml"
    local svc_name="hysteria-client${num}"
    if [[ -f "$config_file" ]]; then
        warn "Instance $num already exists."
        confirm "Overwrite it? (a backup will be created)" n || { echo "Cancelled."; return; }
    fi

    echo -e "\n${YELLOW}[2/7] Foreign server address${NC}"
    note "Format: IP:PORT  of your FOREIGN server, e.g.  203.0.113.10:34567"
    note "The port is the 'Listen port' chosen during server setup."
    note "Advanced (port hopping): IP:START-END, e.g. 203.0.113.10:20000-30000"
    note "  -> only use this if you configured port-range forwarding on the server."
    ask_valid "Foreign server address (IP:PORT)" "" SERVER_ADDR is_server_addr

    echo -e "\n${YELLOW}[3/7] Auth password${NC}"
    note "Must be IDENTICAL to the 'Auth password' on the foreign server."
    ask_valid "Auth password" "" AUTH_PASS is_password

    echo -e "\n${YELLOW}[4/7] Obfs password${NC}"
    note "Must be IDENTICAL to the 'Obfs password' on the foreign server."
    ask_valid "Obfs password" "" OBFS_PASS is_password

    echo -e "\n${YELLOW}[5/7] SNI${NC}"
    select_sni

    echo -e "\n${YELLOW}[6/7] Certificate pin (SHA256)${NC}"
    note "The server uses a self-signed certificate, so the client cannot verify it"
    note "the normal way. The pin lets the client confirm it is talking to YOUR"
    note "server and not someone in the middle."
    note "Copy it from the server setup output ('TLS SHA256 pin'), format AA:BB:CC:..."
    note "If you skip it, the connection works but is NOT protected against"
    note "man-in-the-middle attacks."
    ask_pin

    echo -e "\n${YELLOW}[7/7] Bandwidth${NC}"
    select_bandwidth "this IRAN server's internet connection (and not more than the foreign server)"
    local speed=$BW_RESULT

    echo -e "\n${YELLOW}Port forwarding${NC}"
    collect_forwarding

    backup_file "$config_file"
    local pin_line=""
    [[ -n "$PIN_SHA" ]] && pin_line="  pinSHA256: \"$PIN_SHA\""

    cat > "$config_file" << EOC
server: "$SERVER_ADDR"
auth: "$AUTH_PASS"

tls:
  sni: "$SNI_RESULT"
  insecure: true
$pin_line

obfs:
  type: gecko
  gecko:
    password: "$OBFS_PASS"
    minPacketSize: 512
    maxPacketSize: 1200

transport:
  type: udp
  udp:
    minHopInterval: 15s
    maxHopInterval: 45s

quic:
  initStreamReceiveWindow: 50331648
  maxStreamReceiveWindow: 100663296
  initConnReceiveWindow: 100663296
  maxConnReceiveWindow: 201326592
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false

bandwidth:
  up: $speed
  down: $speed
EOC

    [[ -n "$FWD_TCP" ]] && echo "tcpForwarding:$FWD_TCP" >> "$config_file"
    [[ -n "$FWD_UDP" ]] && echo "udpForwarding:$FWD_UDP" >> "$config_file"
    chmod 600 "$config_file"
    info "Client configuration written to $config_file"

    if confirm "Open the config in nano to review/edit?" n; then
        nano "$config_file"
    fi

    create_service "$svc_name" "$HYSTERIA_BIN client --config $config_file"

    if systemctl is-active --quiet "$svc_name"; then
        note "Check the tunnel logs anytime with:  journalctl -u $svc_name -f"
        note "Look for a line saying the client connected to the server."
    fi
}

# ---------------------------------------------------------------------
#  3) Watchdog
# ---------------------------------------------------------------------
setup_monitor() {
    info "Deploying watchdog (systemd timer)..."
    note "Services already auto-restart on crash. The watchdog is an extra safety net"
    note "that checks every 45 seconds that each client service is still running."

    cat > /usr/local/bin/hysteria-monitor.sh << 'MONITOR'
#!/usr/bin/env bash
for config in /etc/hysteria/client*-config.yaml; do
    [ -f "$config" ] || continue
    base=$(basename "$config" .yaml)       # client1-config
    svc="hysteria-${base%-config}"         # hysteria-client1
    [ -f "/etc/systemd/system/$svc.service" ] || continue
    if ! systemctl is-active --quiet "$svc"; then
        echo "$(date) - Watchdog restarted: $svc" >> /var/log/hysteria-monitor.log
        systemctl restart "$svc"
    fi
done
MONITOR
    chmod +x /usr/local/bin/hysteria-monitor.sh

    cat > "$SERVICE_DIR/hysteria-monitor.service" << EOF
[Unit]
Description=Hysteria Client Watchdog (one-shot check)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hysteria-monitor.sh
EOF

    cat > "$SERVICE_DIR/hysteria-monitor.timer" << EOF
[Unit]
Description=Hysteria Client Watchdog Timer

[Timer]
OnBootSec=30
OnUnitActiveSec=45
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-monitor.timer
    info "Watchdog enabled. Restart events are logged in /var/log/hysteria-monitor.log"
}

# ---------------------------------------------------------------------
#  4-7) Management helpers
# ---------------------------------------------------------------------
list_services() {
    local f name found=0
    for f in "$SERVICE_DIR"/hysteria-*.service; do
        [[ -e "$f" ]] || continue
        found=1
        name=$(basename "${f%.service}")
        printf "  %-28s %s\n" "$name" "$(systemctl is-active "$name")"
    done
    (( found )) || warn "No Hysteria services found."
}

pick_service() {
    local files=() f i n
    for f in "$SERVICE_DIR"/hysteria-*.service; do
        [[ -e "$f" ]] && files+=("$(basename "${f%.service}")")
    done
    if (( ${#files[@]} == 0 )); then
        warn "No Hysteria services found."
        return 1
    fi
    echo "Available services:"
    for i in "${!files[@]}"; do
        printf "  %d) %s (%s)\n" "$((i + 1))" "${files[i]}" "$(systemctl is-active "${files[i]}")"
    done
    read -rp "Choose a number: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#files[@]} )); then
        PICKED_SERVICE=${files[n - 1]}
        return 0
    fi
    err "Invalid choice."
    return 1
}

view_logs() {
    pick_service || return
    info "Last 40 log lines of $PICKED_SERVICE (use: journalctl -u $PICKED_SERVICE -f  for live logs)"
    journalctl -u "$PICKED_SERVICE" -n 40 --no-pager
}

restart_service() {
    pick_service || return
    systemctl restart "$PICKED_SERVICE"
    sleep 2
    systemctl is-active --quiet "$PICKED_SERVICE" \
        && info "$PICKED_SERVICE restarted successfully." \
        || err "$PICKED_SERVICE is not running. Check logs (option 5)."
}

uninstall_all() {
    warn "This stops and removes ALL Hysteria services and the Hysteria binary."
    confirm "Continue?" n || { echo "Cancelled."; return; }
    local f name
    for f in "$SERVICE_DIR"/hysteria-*.service "$SERVICE_DIR"/hysteria-*.timer; do
        [[ -e "$f" ]] || continue
        name=$(basename "$f")
        systemctl disable --now "$name" >/dev/null 2>&1
        rm -f "$f"
    done
    rm -f /usr/local/bin/hysteria-monitor.sh "$HYSTERIA_BIN"
    systemctl daemon-reload
    if confirm "Also delete $CONFIG_DIR (configs, certificate, saved info)?" n; then
        rm -rf "$CONFIG_DIR"
    fi
    info "Uninstall finished."
}

# ---------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    err "Please run this script as root (sudo bash $0)."
    exit 1
fi

mkdir -p "$CONFIG_DIR"
print_header
check_installed

while true; do
    print_header
    echo
    echo "  1) Configure SERVER   (run on the foreign server)"
    echo "  2) Configure CLIENT   (run on the Iran relay server)"
    echo "  3) Deploy / update watchdog (auto-restart monitor)"
    echo "  4) Show status of all Hysteria services"
    echo "  5) View service logs"
    echo "  6) Show saved server info (values to enter on the Iran server)"
    echo "  7) Restart a service"
    echo "  8) Uninstall"
    echo "  0) Exit"
    echo "----------------------------------------"
    read -rp "Selection (0-8): " choice
    echo
    case "$choice" in
        1) manage_server ;;
        2) manage_client ;;
        3) setup_monitor ;;
        4) list_services ;;
        5) view_logs ;;
        6) show_server_info ;;
        7) restart_service ;;
        8) uninstall_all ;;
        0) echo "Bye."; exit 0 ;;
        *) err "Invalid option." ;;
    esac
    echo
    pause
done
