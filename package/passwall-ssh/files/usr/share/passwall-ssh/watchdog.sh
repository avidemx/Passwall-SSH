#!/bin/sh

LOG="/tmp/etc/passwall-ssh.log"
ENV_FILE="/usr/share/passwall-ssh/passwall-ssh.env"
TUN2SOCKS_PID="/var/run/passwall-ssh-tun2socks.pid"
RETRY_FILE="/tmp/etc/passwall-ssh.retry"

[ -f "$ENV_FILE" ] && . "$ENV_FILE"

# ==========================================
# INTERNAL WATCHDOG FUNCTIONS
# ==========================================
get_upstream_if() {
    ip route | awk '/default/ {print $5; exit}'
}

get_gateway_ip() {
    ip route | awk '/default/ {print $3; exit}'
}

log() {
    echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] $*</span>" >> "$LOG"
}

trigger_stop() {
    log "Service stopped by Watchdog."
    rm -f "$RETRY_FILE"
    /etc/init.d/passwall-ssh stop &
    exit 0
}

wait_for_upstream() {
    local UPSTREAM_IF=$(get_upstream_if)
    local GW_IP=$(get_gateway_ip)
    
    if [ -z "$UPSTREAM_IF" ] || [ -z "$GW_IP" ]; then
        log "Waiting for Upstream interface & Gateway to be ready..."
        local i=0
        while true; do
            UPSTREAM_IF=$(get_upstream_if)
            GW_IP=$(get_gateway_ip)
            
            if [ -n "$UPSTREAM_IF" ] && [ -n "$GW_IP" ]; then
                log "Upstream recovered on interface ($UPSTREAM_IF) with Gateway ($GW_IP)."
                sleep 2
                return 0
            fi
            
            sleep 2
            i=$((i + 2))
            if [ "$i" -ge 30 ]; then
                log "Timeout waiting for Upstream interface to reconnect (30s)!"
                return 1
            fi
        done
    fi
    return 0
}

trigger_restart() {
    local REASON="$1"
    local ENABLE=$(uci -q get passwall-ssh.main.enabled 2>/dev/null)

    if [ "$ENABLE" = "1" ]; then
        local RETRY_COUNT=0
        [ -f "$RETRY_FILE" ] && RETRY_COUNT=$(cat "$RETRY_FILE")
        
        if [ "$RETRY_COUNT" -ge 30 ]; then
            log "$REASON"
            log "Max restart limit (30x) reached. Force stopping service."
            # Hapus file agar jika di-start manual nanti, kembali ke 0
            rm -f "$RETRY_FILE"
            trigger_stop
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "$RETRY_COUNT" > "$RETRY_FILE"
        
        log "$REASON"
        log "Preparing Restart (Attempt $RETRY_COUNT/30)"

        # BENDERA: Beritahu init.d bahwa ini adalah ulah Watchdog, jangan reset hitungan!
        touch /tmp/etc/passwall-ssh.is_retry
        /etc/init.d/passwall-ssh restart &
    else
        log "$REASON"
        log "Service Disabled | Stopping Service"
        rm -f "$RETRY_FILE"
        /etc/init.d/passwall-ssh stop &
    fi
    exit 0
}

check_ipv6() {
    local UPSTREAM_IF=$(get_upstream_if)
    [ -z "$UPSTREAM_IF" ] && return

    HAS_IPV6_IP=$(ip -6 addr show dev "$UPSTREAM_IF" scope global 2>/dev/null | grep -oE 'inet6 [23][0-9a-f:]+')
    HAS_IPV6_ROUTE=$(ip -6 route show default dev "$UPSTREAM_IF" 2>/dev/null)

    if [ -n "$HAS_IPV6_IP" ] || [ -n "$HAS_IPV6_ROUTE" ]; then
        echo "<font color=\"#FF0000\">[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: Public IPv6 detected on ($UPSTREAM_IF)!</font>" >> "$LOG"
        echo "<font color=\"#FF0000\">[$(date '+%Y-%m-%d %H:%M:%S')] Service stopped. Please Disable IPv6!</font>" >> "$LOG"
        trigger_stop
    fi
}

wait_port() {
    local PORT="$1"
    local TIMEOUT="$2"
    local i=0
    
    while ! netstat -tln 2>/dev/null | grep -q ":$PORT "; do
        if [ -f /tmp/etc/passwall-ssh.auth_failed ]; then
            local SRV_LOG=$(head -n 1 /tmp/etc/passwall-ssh.auth_failed 2>/dev/null)
            [ -n "$SRV_LOG" ] && log "[SERVER LOG] $SRV_LOG"
            echo "<font color=\"#FF0000\">[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: Check Username/Password</font>" >> "$LOG"
            rm -f /tmp/etc/passwall-ssh.auth_failed
            trigger_stop
        fi
        
        if [ -f /tmp/etc/passwall-ssh.kex_failed ]; then
            local SRV_LOG=$(head -n 1 /tmp/etc/passwall-ssh.kex_failed 2>/dev/null)
            [ -n "$SRV_LOG" ] && log "[SERVER LOG] $SRV_LOG"
            rm -f /tmp/etc/passwall-ssh.kex_failed
            trigger_restart "Connection closed by server (KEX Failed) during initialization!"
        fi
        
        sleep 1
        i=$((i+1))
        
        if [ "$i" -ge "$TIMEOUT" ]; then
            trigger_restart "Port $PORT Timeout / Failed to Open!"
        fi
    done
}

# ==========================================
# PHASE 1: PRE-FLIGHT & WARM UP
# ==========================================

log "Checking Upstream interface & Gateway..."
wait_for_upstream || trigger_restart "Upstream/Gateway not ready at startup!"
INITIAL_UPSTREAM_IF=$(get_upstream_if)

check_ipv6

# 1. Tunggu pintu proxy lokal (Stunnel & Lua) terbuka DULU
if [ "$TRANSPORT" = "TLS" ]; then
    wait_port 4444 15
fi
wait_port 8080 15

# 2. Setelah pintu lokal dipastikan terbuka, barulah lepaskan SSH (Client)
sh /usr/share/passwall-ssh/passwall-ssh-client.sh &
echo $! > /var/run/passwall-ssh-client.pid

# 3. Tunggu hingga SSH berhasil membuka SOCKS5
wait_port 1080 30

# 4. Semuanya siap, terapkan rute VPN
/usr/share/passwall-ssh/passwall-ssh.sh start &

# ==========================================
# PHASE 3: MAIN MONITORING LOOP
# ==========================================
LOOP_COUNTER=0

while true; do
    sleep 2
    LOOP_COUNTER=$((LOOP_COUNTER + 1))

    if [ "$LOOP_COUNTER" -eq 2 ]; then
        rm -f "$RETRY_FILE"
    fi

    if [ -f /tmp/etc/passwall-ssh.kex_failed ]; then
        local SRV_LOG=$(head -n 1 /tmp/etc/passwall-ssh.kex_failed 2>/dev/null)
        [ -n "$SRV_LOG" ] && log "[SERVER LOG] $SRV_LOG"
        rm -f /tmp/etc/passwall-ssh.kex_failed
        trigger_restart "Connection Lost (Signal caught from SSH Client)!"
    fi

    CURRENT_UPSTREAM_IF=$(get_upstream_if)
    CURRENT_GW=$(get_gateway_ip)
    
    if [ -z "$CURRENT_UPSTREAM_IF" ] || [ -z "$CURRENT_GW" ]; then
        trigger_restart "Upstream Interface/Gateway Disconnected!"
    elif [ -n "$INITIAL_UPSTREAM_IF" ] && [ "$INITIAL_UPSTREAM_IF" != "$CURRENT_UPSTREAM_IF" ]; then
        trigger_restart "Upstream Interface Changed ($INITIAL_UPSTREAM_IF -> $CURRENT_UPSTREAM_IF)!"
    fi

    if [ -f "$TUN2SOCKS_PID" ]; then
        TUN_PID=$(cat "$TUN2SOCKS_PID" 2>/dev/null)
        if [ -n "$TUN_PID" ] && ! kill -0 "$TUN_PID" 2>/dev/null; then
            trigger_restart "FATAL: badvpn-tun2socks crashed or died!"
        fi
    fi

    if [ -f /tmp/etc/passwall-ssh.need_restart ]; then
        rm -f /tmp/etc/passwall-ssh.need_restart
        trigger_restart "Watchdog menerima sinyal (Restarting Service...)"
    fi

    if [ $((LOOP_COUNTER % 150)) -eq 0 ]; then
        if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 50 ]; then
            tail -n 50 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
        fi
    fi
done
