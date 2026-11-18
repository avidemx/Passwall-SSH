#!/bin/sh
# Experimental Passwall-SSH SlowDNS backend.
# DNSTT Go client -> local SSH SOCKS -> badvpn-tun2socks.
# Independent from passwall-ssh-http.lua. The LAN routing block mirrors the
# already validated SlowDNS supervisor.

UCI_PACKAGE="passwall-ssh-slowdns"
UCI_SECTION="SlowDNS"
RUN="/var/run/passwall-ssh-slowdns"
STATUS="/tmp/etc/passwall-ssh.state"
LOG="/tmp/etc/passwall-ssh.log"
SSH_LOG="$RUN/ssh-debug.log"
SSH_OUTPUT_LOG="$RUN/ssh-output.log"
DNSTT_LOG="$RUN/dnstt.log"

DNSTT_BIN="/usr/bin/dnstt-client"
DNSTT_LOCAL_PORT="2222"
DNSTT_LOCAL_ADDR="127.0.0.1:$DNSTT_LOCAL_PORT"

TUN_DEV="tun0"
TUN_IP="172.25.0.1/30"
TUN_NET="172.25.0.0/30"
TUN_GATEWAY="172.25.0.2"
SOCKS_PORT="1080"
SOCKS_ADDR="127.0.0.1:$SOCKS_PORT"
TUN2SOCKS_BIN="/usr/bin/badvpn-tun2socks"
TUN2SOCKS_PID="$RUN/tun2socks.pid"
TUN_CREATED="$RUN/tun.created"
RP_FILTER_BACKUP="$RUN/rp_filter.all"

# Keep the same routing identifiers as Passwall-SSH (passwall-ssh.sh).
# The DNS resolver is explicitly bypassed so DNSTT UDP/53 never loops into tun0.
ROUTE_TABLE="100"
ROUTE_MARK="1"
ROUTE_PREF="11530"
BYPASS_PREF="11520"
NFT_TABLE="tunfw"
FW_CHAIN="passwall_fwd"

mkdir -p "$RUN" /tmp/etc
umask 077

# Remove temporary logs created by older versions.
rm -f /tmp/etc/passwall-ssh-slowdns-dnstt.log /tmp/etc/passwall-ssh-slowdns-routing.log

SSH_PID=""
DNSTT_PID=""
STOPPING=0
SSH_AUTH_TIMEOUT=10
SSH_TIMEOUT_LIMIT=10
SSH_TIMEOUT_COUNT=0
AUTO_STOP=0
LAN_IF=""
LAN_SUBNET=""
WAN_GW=""
WAN_IF=""
WAN_IP=""
DNS_TRANSPORT="UDP"
DNS_RESOLVER=""
DNS_RESOLVER_HOST=""
DNS_RESOLVER_IPS=""
DNS_UDP_IP=""
DNS_UDP_PORT=""
DNS_QTYPE=""
DNSTT_DOMAIN=""
DNSTT_SERVER_PUBLIC_KEY=""
SSH_USERNAME=""
SSH_PASSWORD=""

write_status() {
    printf '%s\n' "$1" > "$STATUS.tmp"
    mv "$STATUS.tmp" "$STATUS"
}

log() {
    printf '<span color="#3C86AB">[%s] %s</span>\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

log_success() {
    printf '<font color="#00FF00">[%s] %s</font>\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

log_warning() {
    printf '<font color="#FFA500">[%s] WARNING: %s</font>\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

log_error() {
    printf '<font color="#FF5555">[%s] ERROR: %s</font>\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

route_log() {
    log "$*"
}

resolve_ipv4_list() {
    _host="$1"
    if ipv4_ok "$_host"; then
        printf '%s\n' "$_host"
        return 0
    fi

    _resolved=""
    if command -v resolveip >/dev/null 2>&1; then
        _resolved=$(resolveip -4 -t 5 "$_host" 2>/dev/null |
            grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' |
            awk '!seen[$0]++')
    fi

    if [ -z "$_resolved" ] && command -v nslookup >/dev/null 2>&1; then
        _resolved=$(nslookup "$_host" 2>/dev/null |
            awk '
                $1 == "Name:" { found=1; next }
                found && $1 == "Address:" { print $2 }
                found && $1 == "Address" && $2 ~ /^[0-9]+:/ { print $3 }
            ' |
            grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' |
            awk '!seen[$0]++')
    fi

    [ -n "$_resolved" ] || return 1
    printf '%s\n' "$_resolved"
}

valid_port() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

read_config() {
    DNS_TRANSPORT=$(uci -q get "$UCI_PACKAGE.$UCI_SECTION.DNS_TRANSPORT" 2>/dev/null)
    DNS_RESOLVER=$(uci -q get "$UCI_PACKAGE.$UCI_SECTION.DNS_RESOLVER" 2>/dev/null)
    _legacy_dns_ip=$(uci -q get "$UCI_PACKAGE.$UCI_SECTION.DNS_UDP_IP" 2>/dev/null)
    DNS_QTYPE=$(uci -q get "$UCI_PACKAGE.$UCI_SECTION.Type_DNS" 2>/dev/null)
    DNSTT_DOMAIN=$(uci -q get "$UCI_PACKAGE.$UCI_SECTION.DNSTT_DOMAIN" 2>/dev/null)
    DNSTT_SERVER_PUBLIC_KEY=$(uci -q get "$UCI_PACKAGE.$UCI_SECTION.DNSTT_SERVER_PUBLIC_KEY" 2>/dev/null)
    SSH_USERNAME=$(uci -q get "$UCI_PACKAGE.$UCI_SECTION.SSH_USERNAME" 2>/dev/null)
    SSH_PASSWORD=$(uci -q get "$UCI_PACKAGE.$UCI_SECTION.SSH_PASSWORD" 2>/dev/null)
    CONFIG_ERROR=""

    [ -n "$DNS_TRANSPORT" ] || DNS_TRANSPORT="UDP"
    DNS_TRANSPORT=$(printf '%s' "$DNS_TRANSPORT" | tr '[:lower:]' '[:upper:]')
    [ -n "$DNS_RESOLVER" ] || DNS_RESOLVER="$_legacy_dns_ip"
    [ -n "$DNS_RESOLVER" ] || DNS_RESOLVER="1.1.1.1"
    [ -n "$DNS_QTYPE" ] || DNS_QTYPE="AUTO"

    case "$DNS_TRANSPORT" in
        UDP)
            ipv4_ok "$DNS_RESOLVER" || {
                CONFIG_ERROR="Resolver UDP harus berupa alamat IPv4 yang valid"
                return 1
            }
            DNS_RESOLVER_HOST="$DNS_RESOLVER"
            DNS_UDP_PORT="53"
            case "$DNS_QTYPE" in
                AUTO|auto) DNS_QTYPE="auto" ;;
                NS|ns) DNS_QTYPE="ns" ;;
                TXT|txt) DNS_QTYPE="txt" ;;
                MX|mx) DNS_QTYPE="mx" ;;
                CNAME|cname) DNS_QTYPE="cname" ;;
                NULL|null) DNS_QTYPE="null" ;;
                SRV|srv) DNS_QTYPE="srv" ;;
                *)
                    CONFIG_ERROR="QTYPE tidak didukung: $DNS_QTYPE"
                    return 1
                    ;;
            esac
            ;;
        DOH)
            case "$DNS_RESOLVER" in
                https://*) ;;
                *)
                    CONFIG_ERROR="Resolver DoH harus berupa URL HTTPS lengkap"
                    return 1
                    ;;
            esac
            _authority=${DNS_RESOLVER#https://}
            _authority=${_authority%%/*}
            _authority=${_authority%%\?*}
            _authority=${_authority%%#*}
            DNS_RESOLVER_HOST=${_authority%%:*}
            printf '%s\n' "$DNS_RESOLVER_HOST" | grep -qE '^[A-Za-z0-9.-]+$' || {
                CONFIG_ERROR="URL DoH mengandung nama host yang tidak valid"
                return 1
            }
            DNS_UDP_PORT="443"
            case "$_authority" in
                *:*)
                    _port=${_authority##*:}
                    valid_port "$_port" || {
                        CONFIG_ERROR="Port pada URL DoH harus antara 1 sampai 65535"
                        return 1
                    }
                    DNS_UDP_PORT="$_port"
                    ;;
            esac
            ;;
        DOT)
            case "$DNS_RESOLVER" in
                *:*)
                    DNS_RESOLVER_HOST=${DNS_RESOLVER%:*}
                    DNS_UDP_PORT=${DNS_RESOLVER##*:}
                    ;;
                *)
                    DNS_RESOLVER_HOST="$DNS_RESOLVER"
                    DNS_UDP_PORT="853"
                    DNS_RESOLVER="$DNS_RESOLVER_HOST:853"
                    ;;
            esac
            printf '%s\n' "$DNS_RESOLVER_HOST" | grep -qE '^[A-Za-z0-9.-]+$' || {
                CONFIG_ERROR="Resolver DoT harus berupa hostname atau IPv4 (dengan port opsional)"
                return 1
            }
            valid_port "$DNS_UDP_PORT" || {
                CONFIG_ERROR="Port DoT harus antara 1 sampai 65535"
                return 1
            }
            ;;
        *)
            CONFIG_ERROR="Transport DNS tidak didukung: $DNS_TRANSPORT"
            return 1
            ;;
    esac

    DNS_RESOLVER_IPS=$(resolve_ipv4_list "$DNS_RESOLVER_HOST") || {
        CONFIG_ERROR="Gagal meresolve endpoint DNS '$DNS_RESOLVER_HOST' ke alamat IPv4"
        return 1
    }
    DNS_UDP_IP=$(printf '%s\n' "$DNS_RESOLVER_IPS" | head -n 1)
    ipv4_ok "$DNS_UDP_IP" || {
        CONFIG_ERROR="Endpoint DNS tidak memiliki alamat IPv4 yang valid"
        return 1
    }

    [ -n "$DNSTT_DOMAIN" ] || {
        CONFIG_ERROR="Name Server (domain DNSTT) belum diisi"
        return 1
    }
    printf '%s\n' "$DNSTT_DOMAIN" | grep -qE '^[A-Za-z0-9.-]+$' || {
        CONFIG_ERROR="Name Server (domain DNSTT) mengandung karakter yang tidak valid"
        return 1
    }

    [ -n "$DNSTT_SERVER_PUBLIC_KEY" ] || {
        CONFIG_ERROR="Public Key server DNSTT belum diisi"
        return 1
    }
    case "$DNSTT_SERVER_PUBLIC_KEY" in
        /*)
            [ -r "$DNSTT_SERVER_PUBLIC_KEY" ] || {
                CONFIG_ERROR="File Public Key tidak ditemukan atau tidak dapat dibaca"
                return 1
            }
            ;;
        *)
            printf '%s' "$DNSTT_SERVER_PUBLIC_KEY" | grep -qE '^[[:xdigit:]]{64}$' || {
                CONFIG_ERROR="Public Key harus berupa path file absolut atau 64 karakter heksadesimal"
                return 1
            }
            ;;
    esac

    [ -n "$SSH_USERNAME" ] || {
        CONFIG_ERROR="Username SSH belum diisi"
        return 1
    }
    printf '%s\n' "$SSH_USERNAME" | grep -qE '^[A-Za-z0-9._-]+$' || {
        CONFIG_ERROR="Username SSH mengandung karakter yang tidak valid"
        return 1
    }
    [ -n "$SSH_PASSWORD" ] || {
        CONFIG_ERROR="Password SSH belum diisi"
        return 1
    }

    return 0
}

terminate_pid() {
    target="$1"
    [ -n "$target" ] || return 0
    if kill -0 "$target" 2>/dev/null; then
        kill "$target" 2>/dev/null
        _n=0
        while kill -0 "$target" 2>/dev/null && [ "$_n" -lt 5 ]; do
            sleep 1
            _n=$((_n + 1))
        done
        if kill -0 "$target" 2>/dev/null; then
            kill -9 "$target" 2>/dev/null
        fi
    fi
    wait "$target" 2>/dev/null
    return 0
}

ipv4_ok() {
    printf '%s\n' "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

port_listening() {
    _port="$1"
    { netstat -lnt 2>/dev/null; ss -lnt 2>/dev/null; } |
        grep -E "[:.]$_port([^0-9]|$)" >/dev/null 2>&1
}

pid_alive() {
    _file="$1"
    [ -f "$_file" ] || return 1
    _pid=$(cat "$_file" 2>/dev/null) || return 1
    [ -n "$_pid" ] || return 1
    kill -0 "$_pid" 2>/dev/null
}

routing_fail() {
    log_error "$1"
    stop_routing
    return 1
}

detect_network() {
    LAN_IF=$(uci -q get network.lan.device)
    [ -n "$LAN_IF" ] || LAN_IF=$(uci -q get network.lan.ifname)
    [ -n "$LAN_IF" ] || LAN_IF="br-lan"

    LAN_SUBNET=$(ip -4 route show dev "$LAN_IF" proto kernel scope link 2>/dev/null |
        awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ { print $1; exit }')
    [ -n "$LAN_SUBNET" ] || LAN_SUBNET=$(ip -4 route show dev "$LAN_IF" 2>/dev/null |
        awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ { print $1; exit }')

    _def=$(ip -4 route show default 2>/dev/null | awk 'NR == 1 { print; exit }')
    WAN_GW=$(printf '%s\n' "$_def" | awk '{
        for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit }
    }')
    WAN_IF=$(printf '%s\n' "$_def" | awk '{
        for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
    }')
    WAN_IP=""
    if [ -n "$WAN_IF" ]; then
        WAN_IP=$(ip -4 -o addr show dev "$WAN_IF" 2>/dev/null |
            awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }')
    fi
}

cleanup_fw4() {
    _handle=""
    while true; do
        _handle=$(nft -a list chain inet fw4 forward 2>/dev/null |
            grep "jump $FW_CHAIN" |
            awk '{ print $NF; exit }')
        [ -n "$_handle" ] || break
        nft delete rule inet fw4 forward handle "$_handle" 2>/dev/null || break
    done

    nft flush chain inet fw4 "$FW_CHAIN" 2>/dev/null
    nft delete chain inet fw4 "$FW_CHAIN" 2>/dev/null

    while true; do
        _handle=$(nft -a list chain inet fw4 srcnat 2>/dev/null |
            grep "oifname \"$TUN_DEV\" masquerade" |
            awk '{ print $NF; exit }')
        [ -n "$_handle" ] || break
        nft delete rule inet fw4 srcnat handle "$_handle" 2>/dev/null || break
    done
}

setup_fw4() {
    nft add chain inet fw4 "$FW_CHAIN" 2>/dev/null
    if ! nft flush chain inet fw4 "$FW_CHAIN" 2>/dev/null; then
        log_error "Gagal menyiapkan chain firewall $FW_CHAIN."
        return 1
    fi

    # MSS clamping must come before accept rules so matching SYN packets reach it.
    if ! nft add rule inet fw4 "$FW_CHAIN" oifname "$TUN_DEV" tcp flags syn tcp option maxseg size set rt mtu; then
        log_warning "MSS clamping tidak didukung oleh fw4."
    fi

    if ! nft add rule inet fw4 "$FW_CHAIN" iifname "$LAN_IF" oifname "$TUN_DEV" accept ||
       ! nft add rule inet fw4 "$FW_CHAIN" iifname "$TUN_DEV" oifname "$LAN_IF" accept; then
        log_error "Gagal menambahkan aturan forwarding firewall."
        return 1
    fi

    if ! nft -a list chain inet fw4 forward 2>/dev/null | grep -q "jump $FW_CHAIN"; then
        if ! nft insert rule inet fw4 forward jump "$FW_CHAIN"; then
            log_error "Gagal menautkan $FW_CHAIN ke chain forward fw4."
            return 1
        fi
    fi

    if ! nft -a list chain inet fw4 srcnat 2>/dev/null |
         grep -q "oifname \"$TUN_DEV\" masquerade"; then
        if ! nft add rule inet fw4 srcnat oifname "$TUN_DEV" masquerade; then
            log_error "Gagal menambahkan aturan masquerade untuk $TUN_DEV."
            return 1
        fi
    fi

    return 0
}

restore_rp_filter() {
    if [ -f "$RP_FILTER_BACKUP" ]; then
        _old=$(cat "$RP_FILTER_BACKUP" 2>/dev/null)
        case "$_old" in
            0|1|2) sysctl -w net.ipv4.conf.all.rp_filter="$_old" >/dev/null 2>&1 ;;
        esac
        rm -f "$RP_FILTER_BACKUP"
    fi
}

relax_rp_filter() {
    if [ ! -f "$RP_FILTER_BACKUP" ]; then
        cat /proc/sys/net/ipv4/conf/all/rp_filter > "$RP_FILTER_BACKUP" 2>/dev/null
    fi
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1
    sysctl -w "net.ipv4.conf.$TUN_DEV.rp_filter=0" >/dev/null 2>&1
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
}

stop_routing() {
    if [ -f "$TUN2SOCKS_PID" ]; then
        terminate_pid "$(cat "$TUN2SOCKS_PID" 2>/dev/null)"
        rm -f "$TUN2SOCKS_PID"
    fi

    while ip rule del pref "$BYPASS_PREF" 2>/dev/null; do :; done
    while ip rule del pref "$ROUTE_PREF" 2>/dev/null; do :; done
    while ip rule del fwmark "$ROUTE_MARK" table "$ROUTE_TABLE" 2>/dev/null; do :; done
    ip route flush table "$ROUTE_TABLE" 2>/dev/null

    cleanup_fw4
    if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        nft delete table inet "$NFT_TABLE" 2>/dev/null
    fi
    rm -f "$RUN/nft.rules"

    if [ -f "$TUN_CREATED" ]; then
        ip link del "$TUN_DEV" 2>/dev/null
        rm -f "$TUN_CREATED"
    fi

    restore_rp_filter
}

apply_nft() {
    _rules="$RUN/nft.rules"
    _resolver_set=""
    for _resolver_ip in $DNS_RESOLVER_IPS; do
        [ -n "$_resolver_set" ] && _resolver_set="$_resolver_set, "
        _resolver_set="${_resolver_set}${_resolver_ip}"
    done
    {
        cat <<EOF
add table inet $NFT_TABLE
add chain inet $NFT_TABLE prerouting { type filter hook prerouting priority mangle; policy accept; }
add chain inet $NFT_TABLE output { type route hook output priority mangle; policy accept; }
add chain inet $NFT_TABLE forward { type filter hook forward priority -1; policy accept; }
add rule inet $NFT_TABLE forward meta nfproto ipv6 drop

# DNS endpoint, loopback and local tunnel networks must stay direct.
add rule inet $NFT_TABLE prerouting ip daddr 127.0.0.0/8 accept
add rule inet $NFT_TABLE prerouting ip daddr $TUN_NET accept
add rule inet $NFT_TABLE output ip daddr 127.0.0.0/8 accept
add rule inet $NFT_TABLE output ip daddr $TUN_NET accept
add rule inet $NFT_TABLE output ip daddr 224.0.0.0/4 accept
add rule inet $NFT_TABLE output ip daddr 255.255.255.255 accept
EOF
        for _resolver_ip in $DNS_RESOLVER_IPS; do
            cat <<EOF
add rule inet $NFT_TABLE prerouting ip daddr $_resolver_ip accept
add rule inet $NFT_TABLE output ip daddr $_resolver_ip accept
EOF
        done
        if [ -n "$LAN_SUBNET" ]; then
            cat <<EOF
add rule inet $NFT_TABLE prerouting iifname "$LAN_IF" ip daddr $LAN_SUBNET accept
add rule inet $NFT_TABLE output ip daddr $LAN_SUBNET accept
EOF
        fi
        if [ -n "$WAN_GW" ] && ipv4_ok "$WAN_GW"; then
            cat <<EOF
add rule inet $NFT_TABLE prerouting iifname "$LAN_IF" ip daddr $WAN_GW accept
add rule inet $NFT_TABLE output ip daddr $WAN_GW accept
EOF
        fi

        # Mark TCP only because OpenSSH -D and tun2socks (without udpgw) do not forward UDP.
        cat <<EOF
add rule inet $NFT_TABLE prerouting iifname "$LAN_IF" meta nfproto ipv4 udp dport { 443, 853 } ip daddr != { $_resolver_set } drop
add rule inet $NFT_TABLE prerouting iifname "$LAN_IF" meta nfproto ipv4 meta l4proto tcp meta mark set $ROUTE_MARK
add rule inet $NFT_TABLE output meta nfproto ipv4 meta l4proto tcp meta mark set $ROUTE_MARK
EOF
    } > "$_rules" || return 1

    nft delete table inet "$NFT_TABLE" 2>/dev/null
    nft -f "$_rules"
}

start_routing() {
    if [ ! -x "$TUN2SOCKS_BIN" ]; then
        log_error "$TUN2SOCKS_BIN tidak ditemukan atau tidak executable."
        return 1
    fi
    if ! command -v nft >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1; then
        log_error "Perintah 'nft' atau 'ip' tidak ditemukan."
        return 1
    fi
    if [ -z "$DNS_RESOLVER_IPS" ]; then
        log_error "Alamat IPv4 resolver DNS tidak tersedia. Routing dibatalkan untuk mencegah loop."
        return 1
    fi
    if ip link show "$TUN_DEV" >/dev/null 2>&1; then
        log_error "Interface $TUN_DEV sedang digunakan layanan lain (Passwall/OpenVPN). Hentikan layanan tersebut terlebih dahulu."
        return 1
    fi

    _n=0
    while [ "$STOPPING" = "0" ] && [ "$_n" -lt 10 ]; do
        port_listening "$SOCKS_PORT" && break
        _n=$((_n + 1))
        sleep 1
    done
    if [ "$STOPPING" != "0" ]; then
        return 1
    fi
    if ! port_listening "$SOCKS_PORT"; then
        log_error "Proxy SOCKS5 di $SOCKS_ADDR tidak aktif."
        return 1
    fi

    detect_network
    if [ -z "$WAN_IF" ]; then
        log_error "Rute default upstream (internet) tidak ditemukan."
        return 1
    fi
    if [ -z "$LAN_SUBNET" ]; then
        log_warning "Subnet LAN tidak terdeteksi; sebagian trafik lokal mungkin ikut melewati tunnel."
    fi

    _fo=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)
    _foh=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
    if [ "$_fo" = "1" ] || [ "$_foh" = "1" ]; then
        log_warning "Firewall flow offloading aktif dan dapat melewati penandaan paket nftables. Sebaiknya nonaktifkan flow offloading."
    fi

    if ! ip tuntap add mode tun dev "$TUN_DEV"; then
        log_error "Gagal membuat interface TUN $TUN_DEV."
        return 1
    fi
    : > "$TUN_CREATED"

    if ! ip addr add "$TUN_IP" dev "$TUN_DEV" || ! ip link set "$TUN_DEV" up; then
        routing_fail "Gagal mengonfigurasi atau mengaktifkan interface $TUN_DEV."
        return 1
    fi
    relax_rp_filter

    "$TUN2SOCKS_BIN" \
        --tundev "$TUN_DEV" \
        --netif-ipaddr "$TUN_GATEWAY" \
        --netif-netmask 255.255.255.252 \
        --socks-server-addr "$SOCKS_ADDR" \
        >/dev/null 2>&1 &
    _pid=$!
    printf '%s\n' "$_pid" > "$TUN2SOCKS_PID"
    sleep 1
    if ! kill -0 "$_pid" 2>/dev/null; then
        routing_fail "BadVPN tun2socks gagal dijalankan."
        return 1
    fi

    if [ -n "$LAN_SUBNET" ]; then
        if ! ip route replace "$LAN_SUBNET" dev "$LAN_IF" table "$ROUTE_TABLE"; then
            routing_fail "Gagal menambahkan rute LAN $LAN_SUBNET."
            return 1
        fi
    fi

    # Keep all resolver IPv4 addresses on the physical WAN, outside tun0.
    for _resolver_ip in $DNS_RESOLVER_IPS; do
        if [ -n "$WAN_GW" ]; then
            if ! ip route replace "$_resolver_ip/32" via "$WAN_GW" dev "$WAN_IF" table "$ROUTE_TABLE"; then
                routing_fail "Gagal melewati bypass endpoint DNS $_resolver_ip melalui gateway $WAN_GW."
                return 1
            fi
        else
            if ! ip route replace "$_resolver_ip/32" dev "$WAN_IF" table "$ROUTE_TABLE"; then
                routing_fail "Gagal melewati bypass endpoint DNS $_resolver_ip melalui interface $WAN_IF."
                return 1
            fi
        fi
    done

    if ! ip route replace default dev "$TUN_DEV" table "$ROUTE_TABLE"; then
        routing_fail "Gagal menambahkan rute default pada tabel $ROUTE_TABLE."
        return 1
    fi

    while ip rule del pref "$BYPASS_PREF" 2>/dev/null; do :; done
    while ip rule del pref "$ROUTE_PREF" 2>/dev/null; do :; done
    while ip rule del fwmark "$ROUTE_MARK" table "$ROUTE_TABLE" 2>/dev/null; do :; done

    for _resolver_ip in $DNS_RESOLVER_IPS; do
        if ! ip rule add pref "$BYPASS_PREF" to "$_resolver_ip/32" table main; then
            log_warning "Aturan bypass resolver untuk $_resolver_ip tidak tersedia; nftables dan rute /32 tetap digunakan."
        fi
    done
    if ! ip rule add pref "$ROUTE_PREF" fwmark "$ROUTE_MARK" table "$ROUTE_TABLE"; then
        routing_fail "Gagal menambahkan aturan policy fwmark."
        return 1
    fi

    if ! apply_nft; then
        routing_fail "Gagal membuat tabel nftables $NFT_TABLE."
        return 1
    fi

    if ! setup_fw4; then
        routing_fail "Gagal mengizinkan forwarding antara LAN dan $TUN_DEV pada fw4."
        return 1
    fi

    ip route flush cache 2>/dev/null
    return 0
}

routing_watchdog() {
    if ! nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        route_log "Tabel nftables $NFT_TABLE hilang."
        return 1
    fi
    if ! nft -a list chain inet fw4 forward 2>/dev/null | grep -q "jump $FW_CHAIN" ||
       ! nft -a list chain inet fw4 srcnat 2>/dev/null | grep -q "oifname \"$TUN_DEV\" masquerade"; then
        route_log "Aturan forwarding atau masquerade fw4 hilang; memulihkan kembali."
        setup_fw4 || return 1
    fi

    if [ -f "$DNSTT_LOG" ]; then
        _dnstt_log_size=$(wc -c < "$DNSTT_LOG" 2>/dev/null | tr -d '[:space:]')
        case "$_dnstt_log_size" in
            ""|*[!0-9]*) _dnstt_log_size=0 ;;
        esac
        if [ "$_dnstt_log_size" -gt 65536 ]; then
            : > "$DNSTT_LOG"
        fi
    fi

    return 0
}

start_dnstt_client() {
    if [ ! -x "$DNSTT_BIN" ]; then
        log_error "Binary DNSTT client $DNSTT_BIN tidak ditemukan atau tidak executable."
        return 1
    fi
    if [ -f "$DNSTT_SERVER_PUBLIC_KEY" ]; then
        [ -r "$DNSTT_SERVER_PUBLIC_KEY" ] || {
            log_error "File Public Key tidak dapat dibaca."
            return 1
        }
        _key_option="-pubkey-file"
    else
        _key_option="-pubkey"
    fi

    : > "$DNSTT_LOG"

    case "$DNS_TRANSPORT" in
        UDP)
            "$DNSTT_BIN" -httpcustom -qtype "$DNS_QTYPE" -kcp-window 512 -udp "$DNS_RESOLVER:53" "$_key_option" "$DNSTT_SERVER_PUBLIC_KEY" "$DNSTT_DOMAIN" "$DNSTT_LOCAL_ADDR" >> "$DNSTT_LOG" 2>&1 &
            ;;
        DOH)
            "$DNSTT_BIN" -doh "$DNS_RESOLVER" "$_key_option" "$DNSTT_SERVER_PUBLIC_KEY" "$DNSTT_DOMAIN" "$DNSTT_LOCAL_ADDR" >> "$DNSTT_LOG" 2>&1 &
            ;;
        DOT)
            "$DNSTT_BIN" -dot "$DNS_RESOLVER" "$_key_option" "$DNSTT_SERVER_PUBLIC_KEY" "$DNSTT_DOMAIN" "$DNSTT_LOCAL_ADDR" >> "$DNSTT_LOG" 2>&1 &
            ;;
        *)
            log_error "Transport DNS tidak didukung: $DNS_TRANSPORT"
            return 1
            ;;
    esac

    DNSTT_PID=$!
    sleep 1
    if ! kill -0 "$DNSTT_PID" 2>/dev/null; then
        wait "$DNSTT_PID" 2>/dev/null
        _dnstt_rc=$?
        log_error "DNSTT client berhenti saat startup (exit code $_dnstt_rc)."
        diagnose_dnstt_failure "early_exit"
        DNSTT_PID=""
        return 1
    fi
    return 0
}

dnstt_ready() {
    port_listening "$DNSTT_LOCAL_PORT"
}

diagnose_dnstt_failure() {
    _phase="${1:-timeout}"
    [ -s "$DNSTT_LOG" ] || {
        if [ "$DNS_TRANSPORT" = "UDP" ]; then
            log_error "Tidak ada respons (RX) sama sekali dari resolver $DNS_RESOLVER:53. Kemungkinan UDP:53 diblokir atau DNS resolver sedang mati. Silakan ganti DNS resolver."
        else
            log_error "Tidak ada respons (RX) dari endpoint $DNS_TRANSPORT ($DNS_RESOLVER). Periksa koneksi internet atau ganti resolver."
        fi
        return 0
    }

    if grep -Eiq 'address already in use' "$DNSTT_LOG" 2>/dev/null; then
        log_error "Port lokal $DNSTT_LOCAL_ADDR sudah digunakan oleh proses lain. Hentikan proses tersebut lalu coba lagi."
        return 0
    fi

    if grep -Eiq 'pubkey|public key|hex|decode' "$DNSTT_LOG" 2>/dev/null && ! grep -qE '(^|[[:space:]])RX([[:space:]:=]|$)' "$DNSTT_LOG" 2>/dev/null; then
        log_error "Format Public Key tidak valid atau gagal dimuat. Periksa kembali Public Key server SlowDNS Anda."
        return 0
    fi

    if grep -Eiq 'permission denied|operation not permitted' "$DNSTT_LOG" 2>/dev/null; then
        log_error "Akses jaringan atau bind port ditolak sistem (permission denied)."
        return 0
    fi

    # 1. Ada RX payload > 0B namun port lokal 127.0.0.1:2222 gagal terbuka
    if awk '/RX/ && /payload=[1-9][0-9]*B?([^0-9]|$)/ { found=1; exit } END { exit !found }' "$DNSTT_LOG" 2>/dev/null; then
        log_error "Data payload dari server sudah diterima (RX payload>0B), namun port lokal $DNSTT_LOCAL_ADDR tidak kunjung terbuka. Kemungkinan Public Key tidak cocok atau terjadi loss/timeout pada Noise handshake."
        return 0
    fi

    # 2. RX rcode=0, answers>=1, namun payload=0B -> QTYPE tidak cocok
    if awk '/RX/ && /rcode=0([^0-9]|$)/ && /answers=[1-9][0-9]*([^0-9]|$)/ && /payload=0B?([^0-9]|$)/ { found=1; exit } END { exit !found }' "$DNSTT_LOG" 2>/dev/null; then
        log_error "Server merespons query DNS (rcode=0, answers>=1) namun payload kosong (0B). QTYPE ($DNS_QTYPE) kemungkinan tidak cocok dengan balasan server. Silakan ganti QTYPE atau gunakan mode AUTO."
        return 0
    fi

    # 3. RX dengan rcode=2 / 3 / 5
    _bad_rcode=$(awk '/RX/ && match($0, /rcode=(2|3|5)([^0-9]|$)/) {
        s = substr($0, RSTART + 6, RLENGTH - 6);
        gsub(/[^0-9]/, "", s);
        if (s != "") { print s; exit }
    }' "$DNSTT_LOG" 2>/dev/null)

    if [ -n "$_bad_rcode" ]; then
        case "$_bad_rcode" in
            3)
                log_error "Resolver mengembalikan RX rcode=3 (NXDOMAIN). Domain Name Server ($DNSTT_DOMAIN) tidak ditemukan atau pengaturan NS server SlowDNS bermasalah."
                ;;
            5)
                log_error "Resolver menolak permintaan DNS (RX rcode=5 / REFUSED). Silakan ganti DNS resolver lain."
                ;;
            2)
                log_error "Kegagalan resolusi DNS (RX rcode=2 / SERVFAIL). Kemungkinan server SlowDNS tidak aktif, domain NS bermasalah, atau resolver gagal meneruskan query."
                ;;
        esac
        return 0
    fi

    # 4. Tidak ada RX sama sekali
    if ! grep -qE '(^|[[:space:]])RX([[:space:]:=]|$)' "$DNSTT_LOG" 2>/dev/null; then
        if [ "$DNS_TRANSPORT" = "UDP" ]; then
            log_error "Tidak ada RX sama sekali dari $DNS_RESOLVER:53. Kemungkinan port UDP:53 diblokir oleh ISP atau DNS resolver sedang mati. Silakan ganti DNS resolver."
        else
            log_error "Tidak ada RX sama sekali dari endpoint $DNS_TRANSPORT ($DNS_RESOLVER). Periksa koneksi internet, URL/port resolver, atau sertifikat TLS."
        fi
        return 0
    fi

    # 5. Ada RX namun tidak ada jawaban valid (misalnya rcode=0 answers=0 atau rcode lain)
    _other_rcode=$(awk '/RX/ && match($0, /rcode=[1-9][0-9]*/) {
        s = substr($0, RSTART + 6, RLENGTH - 6);
        if (s != "") { print s; exit }
    }' "$DNSTT_LOG" 2>/dev/null)
    if [ -n "$_other_rcode" ]; then
        log_error "Server/resolver mengembalikan error DNS (RX rcode=$_other_rcode). Periksa status server SlowDNS, domain NS, atau ganti resolver."
    else
        log_error "Respons DNS diterima namun belum ada jawaban tunnel yang valid (answers=0). Periksa domain Name Server ($DNSTT_DOMAIN), QTYPE, atau coba ganti DNS resolver."
    fi

    return 0
}

wait_ssh_banner_output() {
    _last_size="-1"
    _stable=0
    _ticks=0

    # SSH writes banner data asynchronously after authentication. Wait until
    # the output file has stopped growing before parsing it.
    while [ "$_ticks" -lt 8 ] && [ "$STOPPING" = "0" ]; do
        _current_size=$(wc -c < "$SSH_OUTPUT_LOG" 2>/dev/null | tr -d '[:space:]')
        case "$_current_size" in
            ""|*[!0-9]*) _current_size=0 ;;
        esac

        _tag_state=$(awk '
        BEGIN { in_tag = 0 }
        {
            for (i = 1; i <= length($0); i++) {
                ch = substr($0, i, 1)
                if (!in_tag && ch == "<") {
                    in_tag = 1
                } else if (in_tag && ch == ">") {
                    in_tag = 0
                }
            }
        }
        END {
            if (in_tag) print "OPEN"
            else print "CLOSED"
        }' "$SSH_OUTPUT_LOG" 2>/dev/null)

        if [ "$_current_size" -gt 0 ] &&
           [ "$_current_size" = "$_last_size" ] &&
           [ "$_tag_state" = "CLOSED" ]; then
            _stable=$((_stable + 1))
        else
            _stable=0
        fi

        [ "$_stable" -ge 3 ] && break

        # If there is no banner output at all, do not delay startup indefinitely.
        if [ "$_current_size" -eq 0 ] && [ "$_ticks" -ge 2 ]; then
            break
        fi

        _last_size="$_current_size"
        sleep 1
        _ticks=$((_ticks + 1))
    done

    return 0
}

log_server_banner() {
    [ -s "$SSH_OUTPUT_LOG" ] || return 0

    _banner_clean="$RUN/ssh-banner-clean.txt"

    awk '
    BEGIN {
        in_tag = 0
        tagbuf = ""
    }
    {
        src = $0
        out = ""

        for (i = 1; i <= length(src); i++) {
            ch = substr(src, i, 1)

            if (in_tag) {
                tagbuf = tagbuf ch
                if (ch == ">") {
                    tag = tolower(tagbuf)
                    if (tag ~ /^<br[[:space:]]*\/?[[:space:]]*>$/ ||
                        tag ~ /^<\/(p|div|li|pre|h[1-6])[[:space:]]*>$/) {
                        out = out "\n"
                    }
                    in_tag = 0
                    tagbuf = ""
                }
                continue
            }

            if (ch == "<") {
                in_tag = 1
                tagbuf = "<"
                continue
            }

            out = out ch
        }

        gsub(/&#x20;/, " ", out)
        gsub(/&#X20;/, " ", out)
        gsub(/&#160;/, " ", out)
        gsub(/&nbsp;/, " ", out)
        gsub(/&amp;/, "\\&", out)
        gsub(/&lt;/, "<", out)
        gsub(/&gt;/, ">", out)
        gsub(/&quot;/, "\"", out)
        gsub(/&#39;/, "\047", out)

        sub(/^[ \t]*/, "", out)
        sub(/[ \t]*$/, "", out)
        gsub(/\n+/, "\n", out)
        sub(/^\n+/, "", out)
        sub(/\n+$/, "", out)

        if (out != "") {
            print out
        }
    }' "$SSH_OUTPUT_LOG" > "$_banner_clean" 2>/dev/null || return 0

    [ -s "$_banner_clean" ] || return 0

    printf '<span color="#3C86AB">[%s] Server Message:</span>\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"

    while IFS= read -r _line || [ -n "$_line" ]; do
        [ -n "$_line" ] || continue

        _safe_line=$(printf '%s' "$_line" | sed \
            -e 's/&/\&amp;/g' \
            -e 's/</\&lt;/g' \
            -e 's/>/\&gt;/g')
        printf '%s\n' "$_safe_line" >> "$LOG"
    done < "$_banner_clean"

    return 0
}

ssh_connection_timed_out() {
    grep -Eiq 'Connection timed out|Operation timed out|Timeout, server .* not responding' "$SSH_LOG" "$SSH_OUTPUT_LOG" 2>/dev/null
}

log_ssh_failure_details() {
    if grep -Eiq 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED|Offending .* key' "$SSH_LOG" "$SSH_OUTPUT_LOG" 2>/dev/null; then
        log_error "Verifikasi host key SSH gagal."
    elif grep -Eiq 'Permission denied|Authentication failed' "$SSH_LOG" "$SSH_OUTPUT_LOG" 2>/dev/null; then
        log_error "Login SSH ditolak oleh server. Silakan periksa kembali Username, Password, atau kebijakan login password pada server."
    elif grep -Eiq 'Too many authentication failures' "$SSH_LOG" "$SSH_OUTPUT_LOG" 2>/dev/null; then
        log_error "Terlalu banyak percobaan autentikasi SSH yang gagal."
    elif grep -Eiq 'Connection timed out|Operation timed out|Timeout, server .* not responding' "$SSH_LOG" "$SSH_OUTPUT_LOG" 2>/dev/null; then
        log_error "Koneksi ke server SSH mengalami timeout melalui tunnel DNSTT."
    elif grep -Eiq 'Connection refused' "$SSH_LOG" "$SSH_OUTPUT_LOG" 2>/dev/null; then
        log_error "Koneksi ditolak oleh layanan SSH tujuan. Pastikan port SSH pada server SlowDNS aktif."
    elif grep -Eiq 'kex_exchange_identification|banner exchange|Connection reset by peer|closed by remote host' "$SSH_LOG" "$SSH_OUTPUT_LOG" 2>/dev/null; then
        log_error "Koneksi terputus saat negosiasi SSH (kemungkinan loss/latensi tinggi pada jalur DNSTT atau server menutup koneksi)."
    elif grep -Eiq 'No route to host|Network is unreachable' "$SSH_LOG" "$SSH_OUTPUT_LOG" 2>/dev/null; then
        log_error "Server SSH tujuan tidak dapat dijangkau melalui DNSTT."
    elif grep -Eiq 'Address already in use|forwarding failed' "$SSH_LOG" "$SSH_OUTPUT_LOG" 2>/dev/null; then
        log_error "Gagal membuka port SOCKS5 lokal (port $SOCKS_PORT kemungkinan sedang digunakan proses lain)."
    else
        log_error "Handshake SSH gagal; detail diagnostik tersimpan di $SSH_LOG."
    fi
}

stop_children() {
    stop_routing
    terminate_pid "$SSH_PID"
    terminate_pid "$DNSTT_PID"
    SSH_PID=""
    DNSTT_PID=""
}

on_signal() {
    STOPPING=1
    write_status "STOPPING"
    log "Menghentikan layanan dan membersihkan aturan routing..."
    stop_children
}

trap on_signal TERM INT

log_success "Memulai Layanan SlowDNS"
stop_routing
detect_network
if [ -n "$WAN_IF" ]; then
    if [ -n "$WAN_IP" ]; then
        log "Upstream Interface: $WAN_IF ($WAN_IP)"
    else
        log "Upstream Interface: $WAN_IF"
    fi
fi
NAME_SERVER=$(uci -q get "$UCI_PACKAGE.$UCI_SECTION.DNSTT_DOMAIN" 2>/dev/null)
if [ -n "$NAME_SERVER" ]; then
    log "NameServer : $NAME_SERVER"
fi

END_STATUS="DISCONNECTED"
if ! command -v sshpass >/dev/null 2>&1 || ! command -v ssh >/dev/null 2>&1; then
    log_error "Perintah 'sshpass' atau OpenSSH 'ssh' tidak ditemukan."
    END_STATUS="ERROR"
elif ssh -V 2>&1 | grep -qi dropbear; then
    log_error "Diperlukan OpenSSH client; Dropbear ssh client tidak mendukung opsi -D/-E."
    END_STATUS="ERROR"
elif ! uci -q get "$UCI_PACKAGE.$UCI_SECTION.enabled" >/dev/null 2>&1; then
    log_error "Konfigurasi SlowDNS tidak ditemukan di /etc/config/$UCI_PACKAGE (section $UCI_SECTION)."
    END_STATUS="ERROR"
else
    while [ "$STOPPING" = "0" ]; do
        write_status "STARTING"
        if ! read_config; then
            log_error "Konfigurasi SlowDNS tidak valid: ${CONFIG_ERROR:-periksa UCI $UCI_PACKAGE.$UCI_SECTION}."
            write_status "ERROR"
            END_STATUS="ERROR"
            break
        else
            READY=0
            DNSTT_EARLY_EXIT=0
            if start_dnstt_client; then
                count=0
                while [ "$count" -lt 30 ] && [ "$STOPPING" = "0" ]; do
                    if ! kill -0 "$DNSTT_PID" 2>/dev/null; then
                        wait "$DNSTT_PID" 2>/dev/null
                        _dnstt_rc=$?
                        log_error "DNSTT client berhenti sebelum membuka listener lokal (exit code $_dnstt_rc)."
                        diagnose_dnstt_failure "early_exit"
                        DNSTT_PID=""
                        DNSTT_EARLY_EXIT=1
                        break
                    fi
                    if dnstt_ready; then
                        READY=1
                        break
                    fi
                    sleep 1
                    count=$((count + 1))
                done
            else
                DNSTT_EARLY_EXIT=1
            fi

            if [ "$READY" = "1" ] && [ "$STOPPING" = "0" ]; then
                printf '[%s] DNSTT listener siap di %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$DNSTT_LOCAL_ADDR" >> "$LOG"
                : > "$SSH_LOG"
                : > "$SSH_OUTPUT_LOG"
                export SSHPASS="$SSH_PASSWORD"

                sshpass -e ssh -l "$SSH_USERNAME" 127.0.0.1 \
                    -p "$DNSTT_LOCAL_PORT" \
                    -v -E "$SSH_LOG" -N -D "$SOCKS_ADDR" \
                    -o ConnectTimeout=10 \
                    -o ExitOnForwardFailure=yes \
                    -o ServerAliveInterval=15 \
                    -o ServerAliveCountMax=3 \
                    -o Compression=no \
                    -o NumberOfPasswordPrompts=1 \
                    -o PubkeyAuthentication=no \
                    -o KexAlgorithms=curve25519-sha256,ecdh-sha2-nistp256,diffie-hellman-group14-sha256 \
                    -o HostKeyAlgorithms=ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256,ssh-rsa \
                    -o Ciphers=aes128-ctr,aes256-ctr,chacha20-poly1305@openssh.com,aes128-gcm@openssh.com \
                    -o MACs=hmac-sha2-256,hmac-sha2-512,hmac-sha2-256-etm@openssh.com,hmac-sha1 \
                    -o UserKnownHostsFile=/dev/null \
                    -o StrictHostKeyChecking=no \
                    </dev/null >> "$SSH_OUTPUT_LOG" 2>&1 &

                SSH_PID=$!
                unset SSHPASS SSH_PASSWORD
                log "Memulai handshake SSH dan autentikasi akun..."

                count=0
                AUTH_OK=0
                SOCKS_OK=0
                SSH_WAIT_TIMEOUT=0
                while [ "$count" -lt "$SSH_AUTH_TIMEOUT" ] && [ "$STOPPING" = "0" ]; do
                    if grep -q "Authenticated to" "$SSH_LOG"; then
                        AUTH_OK=1
                        break
                    fi
                    if ! kill -0 "$SSH_PID" 2>/dev/null; then
                        break
                    fi
                    if ! kill -0 "$DNSTT_PID" 2>/dev/null; then
                        break
                    fi
                    sleep 1
                    count=$((count + 1))
                done

                if [ "$AUTH_OK" != "1" ] &&
                   [ "$count" -ge "$SSH_AUTH_TIMEOUT" ] &&
                   kill -0 "$SSH_PID" 2>/dev/null &&
                   [ "$STOPPING" = "0" ]; then
                    SSH_WAIT_TIMEOUT=1
                fi

                if [ "$AUTH_OK" = "1" ]; then
                    SSH_TIMEOUT_COUNT=0
                    wait_ssh_banner_output
                    if [ "$STOPPING" = "0" ]; then
                        log_server_banner
                    fi

                    _socks_wait=0
                    while [ "$_socks_wait" -lt 5 ] &&
                          [ "$STOPPING" = "0" ] &&
                          kill -0 "$SSH_PID" 2>/dev/null; do
                        if port_listening "$SOCKS_PORT"; then
                            SOCKS_OK=1
                            break
                        fi
                        sleep 1
                        _socks_wait=$((_socks_wait + 1))
                    done

                    if [ "$SOCKS_OK" != "1" ] && [ "$STOPPING" = "0" ]; then
                        log_error "Login SSH berhasil, tetapi port SOCKS5 tidak terbuka di $SOCKS_ADDR."
                    fi
                fi

                if [ "$AUTH_OK" = "1" ] &&
                   [ "$SOCKS_OK" = "1" ] &&
                   kill -0 "$SSH_PID" 2>/dev/null &&
                   kill -0 "$DNSTT_PID" 2>/dev/null &&
                   [ "$STOPPING" = "0" ]; then
                    log_success "Autentikasi SSH berhasil. Menyiapkan rute VPN..."
                    if start_routing; then
                        log_success "Service Started"
                        write_status "CONNECTED"
                        _tick=0
                        while [ "$STOPPING" = "0" ] &&
                              kill -0 "$SSH_PID" 2>/dev/null &&
                              kill -0 "$DNSTT_PID" 2>/dev/null &&
                              pid_alive "$TUN2SOCKS_PID"
                        do
                            _tick=$((_tick + 1))
                            if [ "$_tick" -ge 30 ]; then
                                _tick=0
                                routing_watchdog || break
                            fi
                            sleep 1
                        done
                        if [ "$STOPPING" = "0" ]; then
                            pid_alive "$TUN2SOCKS_PID" || route_log "Proses BadVPN tun2socks berhenti."
                            log "Koneksi SSH, DNSTT, atau rute VPN terputus. Mencoba menghubungkan ulang..."
                        fi
                    else
                        log_warning "Pengaturan rute VPN gagal. Koneksi akan dicoba ulang."
                    fi
                else
                    if [ "$STOPPING" = "0" ]; then
                        if [ "$AUTH_OK" != "1" ]; then
                            if [ "$SSH_WAIT_TIMEOUT" = "1" ] || ssh_connection_timed_out; then
                                SSH_TIMEOUT_COUNT=$((SSH_TIMEOUT_COUNT + 1))
                                log_error "Koneksi/login SSH timeout ($SSH_TIMEOUT_COUNT/$SSH_TIMEOUT_LIMIT)."
                                diagnose_dnstt_failure "ssh_timeout"

                                if [ "$SSH_TIMEOUT_COUNT" -ge "$SSH_TIMEOUT_LIMIT" ]; then
                                    log_warning "Login SSH gagal timeout sebanyak $SSH_TIMEOUT_LIMIT kali. Coba lakukan Mode Pesawat untuk mendapatkan IP baru atau periksa akun SSH Anda. Layanan SlowDNS dihentikan."
                                    AUTO_STOP=1
                                    STOPPING=1
                                    END_STATUS="STOPPED"
                                    write_status "STOPPING"
                                fi
                            else
                                SSH_TIMEOUT_COUNT=0
                                log_ssh_failure_details
                            fi
                        elif [ "$SOCKS_OK" != "1" ]; then
                            :
                        else
                            log_error "Proses SSH atau DNSTT berhenti sebelum rute VPN dapat dijalankan."
                        fi
                    fi
                fi
            else
                if [ "$STOPPING" = "0" ] && [ "$DNSTT_EARLY_EXIT" != "1" ]; then
                    log_error "DNSTT tidak membuka listener lokal ($DNSTT_LOCAL_ADDR) dalam 30 detik."
                    diagnose_dnstt_failure "timeout"
                fi
            fi

            if [ "$STOPPING" = "0" ]; then
                write_status "STARTING"
            fi
            stop_children
            if [ "$STOPPING" = "0" ]; then
                log "Mencoba menghubungkan ulang SlowDNS dalam 5 detik..."
                sleep 5
            fi
        fi
    done
fi

if [ "$STOPPING" = "1" ] && [ "$AUTO_STOP" != "1" ]; then
    END_STATUS="DISCONNECTED"
elif [ "$AUTO_STOP" = "1" ]; then
    END_STATUS="STOPPED"
fi

stop_children
write_status "$END_STATUS"
if [ "$END_STATUS" = "ERROR" ]; then
    log_error "Layanan berhenti karena konfigurasi atau proses startup SlowDNS gagal."
else
    log_success "Service Stopped."
fi
