#!/bin/bash
# GRE EXTREME MANAGER – Stable Mode (v3.0)
# نصب:
#   nano /root/gre_extreme.sh && chmod +x /root/gre_extreme.sh && bash /root/gre_extreme.sh run
# دستورات: run | check | status | stop

export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

###############################################################################
#                          ★★★  تنظیمات (VARIABLES)  ★★★
###############################################################################

# --- این سرور کدام طرف است؟  "IRAN" یا "KHAREJ" ---
RUN_SCRIPT="IRAN"
#RUN_SCRIPT="KHAREJ"

# --- IP عمومی دو سرور ---
GRE_LOCAL_IP_IRAN="27.30.125.94"
GRE_LOCAL_IP_KHAREJ="207.131.135.125"

# --- مشخصات تونل ---
GRE_NAME="gre1"
GRE_TUN_IP_IRAN="172.31.255.1/30"
GRE_TUN_IP_KHAREJ="172.31.255.2/30"
GRE_TTL="255"

# --- MTU ---
# GRE_MTU_MAX: سقف MTU تونل (پیشنهاد 1400)
# GRE_MTU_MIN: کمترین مقدار قابل قبول هنگام تشخیص
# GRE_MTU_FALLBACK: اگر تشخیص خودکار جواب نداد (مثلاً ICMP بلاک بود)
# GRE_MTU_AUTO: yes = تشخیص خودکار | no = مستقیماً GRE_MTU_FALLBACK اعمال شود
GRE_MTU_AUTO="yes"
GRE_MTU_MAX="1400"
GRE_MTU_MIN="1280"
GRE_MTU_FALLBACK="1400"

# --- پورت فوروارد (فقط روی سرور ایران اعمال می‌شود) ---
# GRE_PORT_FORWARD_ENABLE: yes / no
# GRE_PORT_FORWARD_MODE:
#     "limited" = فقط پورت‌های GRE_PORT_FORWARD فوروارد شوند
#     "all"     = همه‌ی پورت‌ها به‌جز SSH و GRE_PORT_FORWARD_EXCLUDE فوروارد شوند
# GRE_PORT_FORWARD: لیست پورت‌ها با کاما، رنج با دونقطه (مثال: 80,443,2053,10000:10100)
# GRE_PORT_FORWARD_PROTO: tcp / udp / "tcp udp"
# GRE_PORT_FORWARD_EXCLUDE: پورت‌های مستثنی در حالت all (علاوه بر SSH)
# GRE_PORT_FORWARD_MASQ: yes = روی تونل MASQUERADE شود (توصیه می‌شود)
GRE_PORT_FORWARD_ENABLE="yes"
GRE_PORT_FORWARD_MODE="limited"
GRE_PORT_FORWARD="80,443,2053"
GRE_PORT_FORWARD_PROTO="tcp"
GRE_PORT_FORWARD_EXCLUDE=""
GRE_PORT_FORWARD_MASQ="yes"

# --- SSH و اینترفیس عمومی (خالی = تشخیص خودکار) ---
SSH_PORT=""
PUBLIC_IF=""

# --- سلامت تونل (Health Check) ---
HEALTH_PING_TRIES="5"        # تعداد تلاش پینگ
HEALTH_PING_TIMEOUT="2"      # timeout هر پینگ (ثانیه)
HEALTH_RECREATE_SLEEP="2"    # مکث بین حذف و ساخت مجدد

# --- کرون (دقیقه) ---
CHECK_INTERVAL_IRAN="12"
CHECK_INTERVAL_KHAREJ="10"

# --- تیونینگ کرنل ---
APPLY_TUNING="yes"           # yes / no
TUNING_CONNTRACK_MAX="131072"
TUNING_CONNTRACK_ESTABLISHED="7200"
TUNING_TCP_TW_REUSE="1"
TUNING_TCP_FIN_TIMEOUT="60"
TUNING_KEEPALIVE_TIME="60"
TUNING_KEEPALIVE_INTVL="10"
TUNING_KEEPALIVE_PROBES="10"
TUNING_TCP_RETRIES2="15"     # پیش‌فرض لینوکس 15 است؛ مقدار کمتر اتصال را زودتر قطع می‌کند
TUNING_TCP_RETRIES1="3"
TUNING_TCP_SYN_RETRIES="5"
TUNING_TCP_SYNACK_RETRIES="5"
TUNING_RMEM_MAX="16777216"
TUNING_WMEM_MAX="16777216"
TUNING_TCP_MTU_PROBING="1"

# --- مسیرها ---
SCRIPT_PATH="/root/gre_extreme.sh"
LOCK_FILE="/var/lock/gre_extreme.lock"
LOG_FILE="/var/log/gre_extreme.log"
LOG_MAX_BYTES="1048576"      # 1MB

###############################################################################
#                       پایان تنظیمات – پایین‌تر را دست نزنید
###############################################################################

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RESET="\e[0m"
PF_CHAIN="GRE_PF"

_log() {
    local msg="$1"
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
        : > "$LOG_FILE"
    fi
    echo "$(date '+%F %T') $msg" >> "$LOG_FILE" 2>/dev/null
}
info()  { echo -e "${BLUE}[INFO]${RESET} $1";    _log "[INFO] $1"; }
ok()    { echo -e "${GREEN}[OK]${RESET} $1";     _log "[OK] $1"; }
warn()  { echo -e "${YELLOW}[WARNING]${RESET} $1"; _log "[WARN] $1"; }
error() { echo -e "${RED}[ERROR]${RESET} $1" >&2; _log "[ERROR] $1"; }

# ========================
# مقادیر مشتق‌شده از سمت اجرا
# ========================
resolve_side() {
    case "$RUN_SCRIPT" in
        IRAN)
            LOCAL_IP="$GRE_LOCAL_IP_IRAN";   REMOTE_IP="$GRE_LOCAL_IP_KHAREJ"
            TUN_IP="$GRE_TUN_IP_IRAN";       PEER_TUN_IP="${GRE_TUN_IP_KHAREJ%/*}"
            CHECK_INTERVAL="$CHECK_INTERVAL_IRAN" ;;
        KHAREJ)
            LOCAL_IP="$GRE_LOCAL_IP_KHAREJ"; REMOTE_IP="$GRE_LOCAL_IP_IRAN"
            TUN_IP="$GRE_TUN_IP_KHAREJ";     PEER_TUN_IP="${GRE_TUN_IP_IRAN%/*}"
            CHECK_INTERVAL="$CHECK_INTERVAL_KHAREJ" ;;
        *)
            error "RUN_SCRIPT باید IRAN یا KHAREJ باشد (الان: '$RUN_SCRIPT')"; exit 1 ;;
    esac
}

preflight() {
    if [ "$(id -u)" -ne 0 ]; then error "این اسکریپت باید با root اجرا شود"; exit 1; fi
    local missing=0 c
    for c in ip iptables sysctl ping crontab flock awk grep; do
        command -v "$c" >/dev/null 2>&1 || { error "ابزار '$c' نصب نیست"; missing=1; }
    done
    [ $missing -eq 1 ] && exit 1

    if ! ip -4 addr show | grep -qw "$LOCAL_IP"; then
        warn "IP محلی $LOCAL_IP روی هیچ اینترفیسی نیست (پشت NAT هستید یا IP اشتباه است؟)"
    fi
    [ -z "$SSH_PORT" ] && detect_ssh_port
    [ -z "$PUBLIC_IF" ] && detect_public_if
}

detect_ssh_port() {
    SSH_PORT=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)
    [ -z "$SSH_PORT" ] && SSH_PORT="22"
}

detect_public_if() {
    PUBLIC_IF=$(ip -4 route get "$REMOTE_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -z "$PUBLIC_IF" ] && PUBLIC_IF=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
}

# ========================
# GRE & NETWORK
# ========================
enable_ip_forward() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    ok "IP forwarding enabled"
}

gre_exists() {
    ip link show "$GRE_NAME" >/dev/null 2>&1
}

# آیا تونل موجود با تنظیمات فعلی (local/remote) یکی است؟
gre_config_matches() {
    local line
    line=$(ip tunnel show "$GRE_NAME" 2>/dev/null)
    echo "$line" | grep -qw "remote $REMOTE_IP" && echo "$line" | grep -qw "local $LOCAL_IP"
}

delete_gre() {
    if gre_exists; then
        ip link set "$GRE_NAME" down 2>/dev/null
        ip tunnel del "$GRE_NAME" 2>/dev/null
        ok "Old GRE tunnel removed"
    fi
}

# ========================
# MTU & MSS
# ========================
# مسیر واقعی را با پینگ (DF) به IP عمومی طرف مقابل می‌سنجد.
# payload + 28 = MTU مسیر  |  MTU تونل = MTU مسیر - 24 (20 IP + 4 GRE)
auto_detect_mtu() {
    local tunnel_mtu="$GRE_MTU_FALLBACK"

    if [ "$GRE_MTU_AUTO" = "yes" ]; then
        local payload=1472 found=0
        while [ $payload -ge $((GRE_MTU_MIN + 20)) ]; do
            if ping -c 1 -W 1 -M do -s $payload "$REMOTE_IP" >/dev/null 2>&1; then
                found=1; break
            fi
            payload=$((payload - 10))
        done
        if [ $found -eq 1 ]; then
            tunnel_mtu=$((payload + 28 - 24))
            [ $tunnel_mtu -gt "$GRE_MTU_MAX" ] && tunnel_mtu="$GRE_MTU_MAX"
            [ $tunnel_mtu -lt "$GRE_MTU_MIN" ] && tunnel_mtu="$GRE_MTU_MIN"
        else
            warn "تشخیص MTU ممکن نشد (ICMP بلاک؟) → استفاده از fallback: $GRE_MTU_FALLBACK"
        fi
    fi

    ip link set dev "$GRE_NAME" mtu "$tunnel_mtu"
    ok "Tunnel MTU applied: $tunnel_mtu"
}

_ipt_add_once() {   # _ipt_add_once <table> <chain> <rule...>
    local table="$1" chain="$2"; shift 2
    iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -A "$chain" "$@"
}

apply_mss_clamp() {
    local f="-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
    _ipt_add_once mangle FORWARD -o "$GRE_NAME" $f
    _ipt_add_once mangle FORWARD -i "$GRE_NAME" $f
    _ipt_add_once mangle OUTPUT  -o "$GRE_NAME" $f
    ok "MSS clamping applied (FORWARD in/out + OUTPUT)"
}

# ========================
# PORT FORWARD (فقط ایران → خارج از طریق تونل)
# ========================
remove_port_forward() {
    local dest="${GRE_TUN_IP_KHAREJ%/*}"
    iptables -t nat -D PREROUTING -j "$PF_CHAIN" 2>/dev/null
    iptables -t nat -F "$PF_CHAIN" 2>/dev/null
    iptables -t nat -X "$PF_CHAIN" 2>/dev/null
    iptables -t nat -D POSTROUTING -o "$GRE_NAME" -j MASQUERADE 2>/dev/null
    while iptables -D FORWARD -o "$GRE_NAME" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$GRE_NAME" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
    : "$dest"
}

pf_chain_exists() {
    iptables -t nat -nL "$PF_CHAIN" >/dev/null 2>&1
}

apply_port_forward() {
    [ "$RUN_SCRIPT" = "IRAN" ] || return 0
    if [ "$GRE_PORT_FORWARD_ENABLE" != "yes" ]; then
        remove_port_forward
        info "Port forward disabled"
        return 0
    fi

    local dest="${GRE_TUN_IP_KHAREJ%/*}" proto iif=""
    [ -n "$PUBLIC_IF" ] && iif="-i $PUBLIC_IF"

    iptables -t nat -N "$PF_CHAIN" 2>/dev/null
    iptables -t nat -F "$PF_CHAIN"
    iptables -t nat -C PREROUTING -j "$PF_CHAIN" 2>/dev/null || iptables -t nat -I PREROUTING 1 -j "$PF_CHAIN"

    for proto in $GRE_PORT_FORWARD_PROTO; do
        if [ "$GRE_PORT_FORWARD_MODE" = "all" ]; then
            local excl="$SSH_PORT"
            [ -n "$GRE_PORT_FORWARD_EXCLUDE" ] && excl="$excl,$GRE_PORT_FORWARD_EXCLUDE"
            iptables -t nat -A "$PF_CHAIN" $iif -p "$proto" -m multiport --dports "$excl" -j RETURN
            iptables -t nat -A "$PF_CHAIN" $iif -p "$proto" -j DNAT --to-destination "$dest"
        else
            iptables -t nat -A "$PF_CHAIN" $iif -p "$proto" -m multiport --dports "$GRE_PORT_FORWARD" \
                -j DNAT --to-destination "$dest"
        fi
    done

    if [ "$GRE_PORT_FORWARD_MASQ" = "yes" ]; then
        _ipt_add_once nat POSTROUTING -o "$GRE_NAME" -j MASQUERADE
    fi

    # اجازه‌ی عبور در FORWARD (اگر policy روی DROP باشد لازم است)
    iptables -C FORWARD -o "$GRE_NAME" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o "$GRE_NAME" -j ACCEPT
    iptables -C FORWARD -i "$GRE_NAME" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -i "$GRE_NAME" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    if [ "$GRE_PORT_FORWARD_MODE" = "all" ]; then
        ok "Port forward: ALL ports (except SSH $SSH_PORT${GRE_PORT_FORWARD_EXCLUDE:+,$GRE_PORT_FORWARD_EXCLUDE}) → $dest [$GRE_PORT_FORWARD_PROTO]"
    else
        ok "Port forward: $GRE_PORT_FORWARD → $dest [$GRE_PORT_FORWARD_PROTO]"
    fi
}

# ========================
# KERNEL TUNING
# ========================
_sysctl() {
    sysctl -w "$1=$2" >/dev/null 2>&1 || warn "sysctl $1 اعمال نشد"
}

apply_performance_tuning() {
    [ "$APPLY_TUNING" = "yes" ] || { info "Kernel tuning skipped"; return 0; }

    modprobe nf_conntrack 2>/dev/null
    _sysctl net.netfilter.nf_conntrack_max "$TUNING_CONNTRACK_MAX"
    _sysctl net.netfilter.nf_conntrack_tcp_timeout_established "$TUNING_CONNTRACK_ESTABLISHED"
    _sysctl net.ipv4.tcp_tw_reuse "$TUNING_TCP_TW_REUSE"
    _sysctl net.ipv4.tcp_fin_timeout "$TUNING_TCP_FIN_TIMEOUT"
    _sysctl net.ipv4.tcp_keepalive_time "$TUNING_KEEPALIVE_TIME"
    _sysctl net.ipv4.tcp_keepalive_intvl "$TUNING_KEEPALIVE_INTVL"
    _sysctl net.ipv4.tcp_keepalive_probes "$TUNING_KEEPALIVE_PROBES"
    _sysctl net.ipv4.tcp_retries2 "$TUNING_TCP_RETRIES2"
    _sysctl net.ipv4.tcp_retries1 "$TUNING_TCP_RETRIES1"
    _sysctl net.ipv4.tcp_syn_retries "$TUNING_TCP_SYN_RETRIES"
    _sysctl net.ipv4.tcp_synack_retries "$TUNING_TCP_SYNACK_RETRIES"
    _sysctl net.core.rmem_max "$TUNING_RMEM_MAX"
    _sysctl net.core.wmem_max "$TUNING_WMEM_MAX"
    _sysctl net.ipv4.tcp_mtu_probing "$TUNING_TCP_MTU_PROBING"
    ok "Kernel tuning applied"
}

# ========================
# CRON
# ========================
ensure_cron_jobs() {
    info "Checking cron jobs..."
    local reboot="@reboot $SCRIPT_PATH run >/dev/null 2>&1"
    local check="*/$CHECK_INTERVAL * * * * $SCRIPT_PATH check >/dev/null 2>&1"
    local current
    current=$(crontab -l 2>/dev/null)

    if echo "$current" | grep -qFx "$reboot" && echo "$current" | grep -qFx "$check"; then
        ok "Cron jobs already correct (check every $CHECK_INTERVAL min)"
        return 0
    fi

    {
        echo "$current" | grep -vF "$SCRIPT_PATH" | sed '/^[[:space:]]*$/d'
        echo "$reboot"
        echo "$check"
    } | crontab -
    ok "Cron updated (@reboot + check every $CHECK_INTERVAL min)"
}

remove_cron_jobs() {
    crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" | sed '/^[[:space:]]*$/d' | crontab - 2>/dev/null
    ok "Cron jobs removed"
}

# ========================
# GRE CREATE
# ========================
create_gre() {
    if gre_exists && ! gre_config_matches; then
        warn "تنظیمات تونل تغییر کرده → بازسازی"
        delete_gre
    fi

    if ! gre_exists; then
        ip tunnel add "$GRE_NAME" mode gre remote "$REMOTE_IP" local "$LOCAL_IP" ttl "$GRE_TTL" \
            || { error "ساخت تونل ناموفق بود (ماژول ip_gre لود است؟)"; return 1; }
        ok "GRE tunnel created"
    fi

    if ! ip addr show "$GRE_NAME" | grep -qw "${TUN_IP%/*}"; then
        ip addr flush dev "$GRE_NAME" 2>/dev/null
        ip addr add "$TUN_IP" dev "$GRE_NAME"
        ok "Tunnel IP assigned: $TUN_IP"
    fi

    ip link set "$GRE_NAME" up
    ok "GRE interface up"
    auto_detect_mtu
    apply_mss_clamp
    apply_port_forward
    return 0
}

# ========================
# HEALTH CHECK
# ========================
tunnel_healthy() {
    local i
    for i in $(seq 1 "$HEALTH_PING_TRIES"); do
        ping -c 1 -W "$HEALTH_PING_TIMEOUT" "$PEER_TUN_IP" >/dev/null 2>&1 && return 0
    done
    return 1
}

check_mode() {
    if gre_exists && tunnel_healthy; then
        ok "GRE tunnel healthy"
        # اگر قوانین فایروال به هر دلیل پاک شده باشند، دوباره بساز
        if [ "$RUN_SCRIPT" = "IRAN" ] && [ "$GRE_PORT_FORWARD_ENABLE" = "yes" ] && ! pf_chain_exists; then
            warn "قوانین port-forward پیدا نشد → اعمال مجدد"
            apply_port_forward
        fi
        return 0
    fi

    warn "GRE tunnel down. Recreating..."
    delete_gre
    sleep "$HEALTH_RECREATE_SLEEP"
    enable_ip_forward
    create_gre
}

# ========================
# RUN / STOP / STATUS
# ========================
run_mode() {
    enable_ip_forward
    apply_performance_tuning
    create_gre || exit 1
    ensure_cron_jobs
    ok "GRE tunnel stable and operational"
}

stop_mode() {
    remove_port_forward
    delete_gre
    remove_cron_jobs
    ok "Everything stopped and cleaned"
}

status_mode() {
    echo "Side        : $RUN_SCRIPT"
    echo "Local/Remote: $LOCAL_IP -> $REMOTE_IP"
    echo "Tunnel      : $GRE_NAME  $TUN_IP  (peer $PEER_TUN_IP)"
    echo "Public IF   : $PUBLIC_IF   SSH port: $SSH_PORT"
    if gre_exists; then
        ip -br addr show "$GRE_NAME"
        echo "MTU         : $(cat /sys/class/net/$GRE_NAME/mtu 2>/dev/null)"
        if tunnel_healthy; then ok "Tunnel healthy"; else error "Tunnel NOT responding"; fi
    else
        error "Tunnel $GRE_NAME does not exist"
    fi
    if [ "$RUN_SCRIPT" = "IRAN" ]; then
        echo "--- NAT chain $PF_CHAIN ---"
        iptables -t nat -nL "$PF_CHAIN" 2>/dev/null || echo "(not present)"
    fi
}

# ========================
# MAIN
# ========================
resolve_side
preflight

case "$1" in
    run|check)
        exec 200>"$LOCK_FILE"
        flock -n 200 || { warn "نمونه‌ی دیگری در حال اجراست"; exit 0; }
        [ "$1" = "run" ] && run_mode || check_mode
        ;;
    stop)   stop_mode ;;
    status) status_mode ;;
    *)      echo "Usage: $0 {run|check|status|stop}"; exit 1 ;;
esac
