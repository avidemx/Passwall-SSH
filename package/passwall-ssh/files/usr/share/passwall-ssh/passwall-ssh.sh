#!/bin/sh

TUN_DEV="tun0"
TUN_IP="172.25.0.1/30" 
ENV_FILE="/usr/share/passwall-ssh/passwall-ssh.env"
[ -f "$ENV_FILE" ] || exit 1
. "$ENV_FILE"

LOG="/tmp/etc/passwall-ssh.log"
NFT_TABLE="tunfw"
ROUTE_TABLE="100"
TUN2SOCKS_PID="/var/run/passwall-ssh-tun2socks.pid"
DNSPROXY_PID="/var/run/pw_dnsproxy.pid"

log() {
    echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] $*</span>" >> "$LOG"
}

fatal() {
    log "FATAL: $1"
    log "Memicu proses rollback..."
    stop
    touch /tmp/etc/passwall-ssh.need_restart
    exit 1
}

resolve_server() {
    log "Upstream connection and DNS resolution of outbound connection..."

    if echo "$HOST" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        DNS_IPS="$HOST"
    else
        DNS_IPS=$(resolveip -4 -t 5 "$HOST" 2>/dev/null)
    fi

    ACTIVE_IPS=$(netstat -tn 2>/dev/null | grep -i 'estab' | awk '{print $5}' | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sort -u | grep -vE '^(127\.|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)')

    ALL_BYPASS_IPS=$(
        {
            echo "$DNS_IPS"
            echo "$ACTIVE_IPS"
        } | grep -E '^[0-9]' | sort -u
    )

    if [ -z "$ALL_BYPASS_IPS" ]; then
        fatal "Tidak ada IP Bypass yang terdeteksi. Pastikan koneksi SSH/Stunnel sudah established."
    fi

    TMP_HOSTS=$(mktemp)
    cp /etc/hosts "$TMP_HOSTS"
    sed -i '/#PASSWALLSSH/d' "$TMP_HOSTS" 2>/dev/null
    for ip in $ALL_BYPASS_IPS; do
        echo "$ip $HOST #PASSWALLSSH" >> "$TMP_HOSTS"
    done
    cat "$TMP_HOSTS" > /etc/hosts
    rm -f "$TMP_HOSTS"

    NFT_IP_LIST=$(echo "$ALL_BYPASS_IPS" | tr '\n' ',' | sed 's/,$//')
}

create_tun() {
    ip link show "$TUN_DEV" >/dev/null 2>&1 && ip link del "$TUN_DEV"
    ip tuntap add mode tun dev "$TUN_DEV" || fatal "Gagal membuat interface $TUN_DEV"
    ip addr add "$TUN_IP" dev "$TUN_DEV" || fatal "Gagal menetapkan IP ke $TUN_DEV"
    ip link set "$TUN_DEV" up || fatal "Gagal mengaktifkan (UP) interface $TUN_DEV"
}

start_tun2socks() {
    /usr/bin/badvpn-tun2socks \
        --tundev "$TUN_DEV" \
        --netif-ipaddr 172.25.0.2 \
        --netif-netmask 255.255.255.252 \
        --socks-server-addr 127.0.0.1:1080 \
        --udpgw-remote-server-addr 127.0.0.1:$UDPGW_PORT \
        >/dev/null 2>&1 &

    echo $! > "$TUN2SOCKS_PID"
    
    sleep 1
    PID=$(cat "$TUN2SOCKS_PID" 2>/dev/null)
    if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
        fatal "badvpn-tun2socks crash atau gagal berjalan!"
    fi
    sleep 2
}

setup_nft() {
    nft delete table inet "$NFT_TABLE" 2>/dev/null
    
    local RULES="add table inet $NFT_TABLE
    add chain inet $NFT_TABLE prerouting { type filter hook prerouting priority mangle; }
    add chain inet $NFT_TABLE output { type route hook output priority mangle; }"

    if [ -n "$LAN_SUBNET" ]; then
        RULES="$RULES
        add rule inet $NFT_TABLE prerouting iifname \"$LAN_IF\" ip daddr $LAN_SUBNET accept
        add rule inet $NFT_TABLE output ip daddr {127.0.0.0/8,$LAN_SUBNET} accept"
    else
        RULES="$RULES
        add rule inet $NFT_TABLE output ip daddr 127.0.0.0/8 accept"
    fi

    if [ -n "$WAN_GW" ]; then
        RULES="$RULES
        add rule inet $NFT_TABLE prerouting iifname \"$LAN_IF\" ip daddr $WAN_GW accept
        add rule inet $NFT_TABLE output ip daddr $WAN_GW accept"
    fi

    if [ -n "$NFT_IP_LIST" ]; then
        RULES="$RULES
        add rule inet $NFT_TABLE prerouting iifname \"$LAN_IF\" ip daddr { $NFT_IP_LIST } accept
        add rule inet $NFT_TABLE output ip daddr { $NFT_IP_LIST } accept"
    fi

    RULES="$RULES
    add rule inet $NFT_TABLE prerouting iifname \"$LAN_IF\" meta mark set 1
    add rule inet $NFT_TABLE output ip daddr 224.0.0.0/4 accept
    add rule inet $NFT_TABLE output ip daddr 255.255.255.255 accept
    add rule inet $NFT_TABLE output meta l4proto { tcp, udp } meta mark set 1"

    echo "$RULES" | nft -f - || fatal "Gagal menerapkan rule nftables"

    nft add chain inet fw4 passwall_fwd 2>/dev/null
    nft flush chain inet fw4 passwall_fwd 2>/dev/null
    
    nft add rule inet fw4 passwall_fwd iifname "$LAN_IF" oifname "$TUN_DEV" accept 2>/dev/null
    nft add rule inet fw4 passwall_fwd iifname "$TUN_DEV" oifname "$LAN_IF" accept 2>/dev/null
    nft add rule inet fw4 passwall_fwd oifname "$TUN_DEV" tcp flags syn tcp option maxseg size set rt mtu 2>/dev/null

    if ! nft -a list chain inet fw4 forward 2>/dev/null | grep -q "jump passwall_fwd"; then
        nft insert rule inet fw4 forward jump passwall_fwd 2>/dev/null
    fi
    
    if ! nft -a list chain inet fw4 srcnat 2>/dev/null | grep -q "oifname \"$TUN_DEV\" masquerade"; then
        nft add rule inet fw4 srcnat oifname "$TUN_DEV" masquerade 2>/dev/null
    fi
}

setup_route() {
    if ! ip link show "$TUN_DEV" 2>/dev/null | grep -q "UP"; then
        fatal "Interface $TUN_DEV tidak UP sebelum memasang route!"
    fi

    ip rule add fwmark 1 table "$ROUTE_TABLE" 2>/dev/null
    
    if [ -n "$LAN_SUBNET" ]; then
        ip route replace "$LAN_SUBNET" dev "$LAN_IF" table "$ROUTE_TABLE" 2>/dev/null
    fi
    ip route replace default dev "$TUN_DEV" table "$ROUTE_TABLE" 2>/dev/null
    
    if [ -n "$WAN_GW" ] && [ -n "$WAN_IF" ]; then
        for ip in $ALL_BYPASS_IPS; do
            ip route replace "$ip" via "$WAN_GW" dev "$WAN_IF" table "$ROUTE_TABLE" 2>/dev/null
        done
    fi
}

start_dnsproxy() {
    log "Starting DNSProxy Resolver ($DNS_PROTO -> $DNS_SERVER)"
    
    local UPSTREAM=""
    case "$DNS_PROTO" in
        "UDP") UPSTREAM="$DNS_SERVER" ;;
        "TCP") UPSTREAM="tcp://$DNS_SERVER" ;;
        "DoT") UPSTREAM="tls://$DNS_SERVER" ;;
        "DoH") UPSTREAM="https://$DNS_SERVER" ;;
        "DoQ") UPSTREAM="quic://$DNS_SERVER" ;;
        "DoH3") UPSTREAM="h3://$DNS_SERVER" ;;
    esac
    
    local DNS_OPTS="--listen=127.0.0.1 --port=5335 --cache --cache-optimistic --ipv6-disabled"
    DNS_OPTS="$DNS_OPTS --upstream=$UPSTREAM"
    
    if echo "$DNS_SERVER" | grep -q "[a-zA-Z]"; then
        DNS_OPTS="$DNS_OPTS --bootstrap=8.8.8.8 --bootstrap=1.1.1.1"
    fi

    dnsproxy $DNS_OPTS >/dev/null 2>&1 &
    echo $! > "$DNSPROXY_PID"
    sleep 2
    
    if ! (netstat -ln 2>/dev/null || ss -ln 2>/dev/null) | grep -q ":5335"; then
        fatal "DNSProxy gagal mendengarkan di port 5335!"
    fi
    
    uci del_list dhcp.@dnsmasq[0].server='127.0.0.1#5335' 2>/dev/null
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5335'
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci commit dhcp
    
    /etc/init.d/dnsmasq reload >/dev/null 2>&1

    log "Checking UDP Support | Port : $UDPGW_PORT"
    if nslookup github.com 1.1.1.1 >/dev/null 2>&1; then
        echo "<font color=\"#00FFFF\">[$(date '+%Y-%m-%d %H:%M:%S')] NICE! Server Support UDP</font>" >> "$LOG"
    else
        log "WARNING: Server Tidak Support UDP atau Periksa Port UDPGW! (Default : 7300)"
    fi
}

start() {
    LAN_IF=$(uci -q get network.lan.device)
    [ -z "$LAN_IF" ] && LAN_IF=$(uci -q get network.lan.ifname)
    [ -z "$LAN_IF" ] && LAN_IF="br-lan"
    LAN_SUBNET=$(ip -4 route show dev "$LAN_IF" 2>/dev/null | awk 'NR==1{print $1}')
    
    WAN_GW=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')
    WAN_IF=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
    
    resolve_server
    create_tun
    log "Preparing VPN routes"
    start_tun2socks
    setup_nft
    setup_route
    start_dnsproxy
    echo "<font color=\"#00FF00\">[$(date '+%Y-%m-%d %H:%M:%S')] Service Started</font>" >> "$LOG"
}

stop() {
    log "Stopping service and cleaning rules..."
    
    if [ -f "$TUN2SOCKS_PID" ]; then
        PID=$(cat "$TUN2SOCKS_PID" 2>/dev/null)
        if [ -n "$PID" ]; then
            kill "$PID" 2>/dev/null
            sleep 1
            kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
        fi
        rm -f "$TUN2SOCKS_PID"
    fi

    ip link del "$TUN_DEV" 2>/dev/null
    ip route flush table "$ROUTE_TABLE" 2>/dev/null

    while ip rule show | grep -q "lookup $ROUTE_TABLE"; do
        ip rule del fwmark 1 table "$ROUTE_TABLE" 2>/dev/null
    done

    nft delete table inet "$NFT_TABLE" 2>/dev/null

    handle=$(nft -a list chain inet fw4 forward 2>/dev/null | grep "jump passwall_fwd" | awk '{print $NF}')
    if [ -n "$handle" ]; then
        nft delete rule inet fw4 forward handle $handle 2>/dev/null
    fi
    nft flush chain inet fw4 passwall_fwd 2>/dev/null
    nft delete chain inet fw4 passwall_fwd 2>/dev/null

    handle_nat=$(nft -a list chain inet fw4 srcnat 2>/dev/null | grep "oifname \"$TUN_DEV\" masquerade" | awk '{print $NF}')
    if [ -n "$handle_nat" ]; then
        nft delete rule inet fw4 srcnat handle $handle_nat 2>/dev/null
    fi

    TMP_HOSTS=$(mktemp)
    cp /etc/hosts "$TMP_HOSTS"
    sed -i '/#PASSWALLSSH/d' "$TMP_HOSTS" 2>/dev/null
    cat "$TMP_HOSTS" > /etc/hosts
    rm -f "$TMP_HOSTS"

    if [ -f "$DNSPROXY_PID" ]; then
        PID=$(cat "$DNSPROXY_PID" 2>/dev/null)
        if [ -n "$PID" ]; then
            kill "$PID" 2>/dev/null
            sleep 1
            kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
        fi
        rm -f "$DNSPROXY_PID"
    fi

    killall dnsproxy 2>/dev/null
    killall badvpn-tun2socks 2>/dev/null

    uci del_list dhcp.@dnsmasq[0].server='127.0.0.1#5335' 2>/dev/null
    uci delete dhcp.@dnsmasq[0].noresolv 2>/dev/null
    uci commit dhcp
    
    /etc/init.d/dnsmasq reload >/dev/null 2>&1
    log "DNSProxy Stopped - DNS Restored"
    echo "<font color=\"#FF0000\">[$(date '+%Y-%m-%d %H:%M:%S')] Service Stopped</font>" >> "$LOG"
}

case "$1" in
start)
    start
;;
stop)
    stop
;;
*)
    echo "Usage: $0 {start|stop}"
;;
esac
