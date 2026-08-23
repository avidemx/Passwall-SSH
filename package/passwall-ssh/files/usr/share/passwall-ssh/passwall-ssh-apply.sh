#!/bin/sh

LOG_FILE="/tmp/etc/passwall-ssh.log"

SELECTED=$(uci -q get passwall-ssh.main.selected_profile)

if [ -z "$SELECTED" ]; then
    echo "<font color=\"#FF0000\">[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: Failed to apply Profile configuration!</font>" >> "$LOG_FILE"
    exit 1
fi

HOST=$(uci -q get passwall-ssh.$SELECTED.host)
HOST_PORT=$(uci -q get passwall-ssh.$SELECTED.host_port)
USERNAME=$(uci -q get passwall-ssh.$SELECTED.username)
PASSWORD=$(uci -q get passwall-ssh.$SELECTED.password)
PROXY_TYPE=$(uci -q get passwall-ssh.$SELECTED.proxy_type)
TLS_TYPE=$(uci -q get passwall-ssh.$SELECTED.tls_type)
PROXY=$(uci -q get passwall-ssh.$SELECTED.proxy)
PROXY_PORT=$(uci -q get passwall-ssh.$SELECTED.proxy_port)
SNI=$(uci -q get passwall-ssh.$SELECTED.sni)
UDPGW_PORT=$(uci -q get passwall-ssh.$SELECTED.udpgw_port)
PAYLOAD_RAW=$(uci -q get passwall-ssh.$SELECTED.payload)

[ -z "$UDPGW_PORT" ] && UDPGW_PORT="7200"

### TRANSLASI PAYLOAD ###
PAYLOAD_PY=$(printf '%s' "$PAYLOAD_RAW" \
    | sed "s/\[host\]/$HOST/g" \
    | sed 's|\[ua\]|Mozilla/5.0 (Windows NT 6.3; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/45.0.2454.85 Safari/537.36|g')

if [ "$PROXY_TYPE" = "HTTP" ]; then
    [ -z "$PROXY_PORT" ] && PROXY_PORT="80"
    STUNNEL_CONNECT="$PROXY:$PROXY_PORT"
else
    STUNNEL_CONNECT="$HOST:443"
    PROXY=""
    PROXY_PORT=""
fi

if [ "$TLS_TYPE" = "TLS" ]; then
    cat > /usr/share/passwall-ssh/stunnel.conf <<EOF
setuid = nobody
setgid = nogroup
foreground = yes
syslog = yes

[cf]
client = yes
accept = 127.0.0.1:4444
connect = $STUNNEL_CONNECT
sni = $SNI
EOF
    
    TRANSPORT="TLS"
else
    > /usr/share/passwall-ssh/stunnel.conf
    TRANSPORT="TCP"
fi

printf '%s' "$PAYLOAD_PY" |
sed 's/\[crlf\]/\
/g' >/usr/share/passwall-ssh/passwall-ssh.payload

DNS_PROTO=$(uci -q get passwall-ssh.main.dns_proto)
[ -z "$DNS_PROTO" ] && DNS_PROTO="UDP"

if [ "$DNS_PROTO" = "DoH" ] || [ "$DNS_PROTO" = "DoH3" ]; then
    DNS_SERVER=$(uci -q get passwall-ssh.main.dns_url)
    [ "$DNS_SERVER" = "manual" ] && DNS_SERVER=$(uci -q get passwall-ssh.main.dns_manual)
else
    DNS_SERVER=$(uci -q get passwall-ssh.main.dns_ip)
    [ "$DNS_SERVER" = "manual" ] && DNS_SERVER=$(uci -q get passwall-ssh.main.dns_manual)
fi

cat >/usr/share/passwall-ssh/passwall-ssh.env <<EOF
PROFILE_NAME='$SELECTED'
TRANSPORT='$TRANSPORT'
HOST='$HOST'
HOST_PORT='$HOST_PORT'
USERNAME='$USERNAME'
PASSWORD='$PASSWORD'
PROXY='$PROXY'
PROXY_PORT='$PROXY_PORT'
SNI='$SNI'
UDPGW_PORT='$UDPGW_PORT'
DNS_PROTO='$DNS_PROTO'
DNS_SERVER='$DNS_SERVER'
EOF
