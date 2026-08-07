#!/bin/sh

LOG="/tmp/passwall-ssh.log"
ENV_FILE="/usr/share/passwall-ssh/passwall-ssh.env"
TUN2SOCKS_PID="/var/run/passwall-ssh-tun2socks.pid"
RETRY_FILE="/tmp/passwall-ssh.retry"

[ -f "$ENV_FILE" ] && . "$ENV_FILE"

# ==========================================
# INTERNAL WATCHDOG FUNCTIONS
# ==========================================
get_upstream_if() {
    ip route | awk '/default/ {print $5; exit}'
}

log() {
    local msg="$*"
    local color="#FFFFFF" 

    case "$msg" in
        *"Starting "*) color="#00FFFF" ;;
        *"[OK]"*|*"Started"*|*"RUNNING"*|*"listening "*) color="#00FF00" ;;
        *"FAILED"*|*"Failed"*|*"Restart "*|*"Timeout"*|*"Total "*|*"FATAL"*|*"Max restart "*|*"Disconnected "*|*"Lost "*) color="#FF0000" ;;
        *"Waiting for Upstream"*|*"Upstream recovered"*) color="#FFFF00" ;;
        *"Using Profile"*) color="#FF00FF" ;;
        *"[SERVER LOG]"*) color="#FFA500" ;;
    esac
    echo "<font color=\"$color\">[$(date '+%H:%M:%S')] $msg</font>" >> "$LOG"
}

trigger_stop() {
    log "Service stopped by Watchdog."
    /etc/init.d/passwall-ssh stop &
    exit 0
}

wait_for_upstream() {
    local UPSTREAM_IF=$(get_upstream_if)
    if [ -z "$UPSTREAM_IF" ]; then
        log "Waiting for Upstream interface & default route to recover..."
        local i=0
        while [ -z "$(get_upstream_if)" ]; do
            sleep 2
            i=$((i + 2))
            if [ "$i" -ge 30 ]; then
                log "Timeout waiting for Upstream interface to reconnect (30s)!"
                return 1
            fi
        done
        log "Upstream recovered on interface ($(get_upstream_if))."
        # Jeda 1 detik agar tabel routing benar-benar stabil
        sleep 1
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
            trigger_stop
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "$RETRY_COUNT" > "$RETRY_FILE"
        
        log "$REASON"
        log "Preparing Restart (Attempt $RETRY_COUNT/30)"
        
        # TAHAN RESTART SAMPAI INTERNET / UPSTREAM DAPAT IP DAN RUTE KEMBALI
        wait_for_upstream
        
        /etc/init.d/passwall-ssh restart &
    else
        log "$REASON"
        log "Service Disabled | Stopping Service"
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
        echo "<font color=\"#FF0000\">[$(date '+%H:%M:%S')] FATAL: Public IPv6 detected on ($UPSTREAM_IF)!</font>" >> "$LOG"
        echo "Service stopped. Please Disable IPv6!" >> "$LOG"
        trigger_stop
    fi
}

wait_port() {
    local PORT="$1"
    local TIMEOUT="$2"
    local i=0
    
    while ! netstat -tln 2>/dev/null | grep -q ":$PORT "; do
        if [ -f /tmp/passwall-ssh.auth_failed ]; then
            local SRV_LOG=$(head -n 1 /tmp/passwall-ssh.auth_failed 2>/dev/null)
            [ -n "$SRV_LOG" ] && log "[SERVER LOG] $SRV_LOG"
            log "FAILED: Check Username/Password"
            rm -f /tmp/passwall-ssh.auth_failed
            trigger_stop
        fi
        
        if [ -f /tmp/passwall-ssh.kex_failed ]; then
            local SRV_LOG=$(head -n 1 /tmp/passwall-ssh.kex_failed 2>/dev/null)
            [ -n "$SRV_LOG" ] && log "[SERVER LOG] $SRV_LOG"
            rm -f /tmp/passwall-ssh.kex_failed
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
check_ipv6

if [ "$TRANSPORT" = "TLS" ]; then
    wait_port 4444 15
fi
wait_port 8080 15
wait_port 1080 30

INITIAL_UPSTREAM_IF=$(get_upstream_if)

/usr/share/passwall-ssh/passwall-ssh.sh start &

# ==========================================
# PHASE 3: MAIN MONITORING LOOP (NO PING)
# ==========================================
LOOP_COUNTER=0

while true; do
    sleep 2
    LOOP_COUNTER=$((LOOP_COUNTER + 1))

    if [ "$LOOP_COUNTER" -eq 2 ]; then
        rm -f "$RETRY_FILE"
    fi

    # 1. Cek Kematian SSH
    if [ -f /tmp/passwall-ssh.kex_failed ]; then
        local SRV_LOG=$(head -n 1 /tmp/passwall-ssh.kex_failed 2>/dev/null)
        [ -n "$SRV_LOG" ] && log "[SERVER LOG] $SRV_LOG"
        rm -f /tmp/passwall-ssh.kex_failed
        trigger_restart "Connection Lost (Signal caught from SSH Client)!"
    fi

    # 2. Cek Perubahan Interface Upstream
    CURRENT_UPSTREAM_IF=$(get_upstream_if)
    if [ -z "$CURRENT_UPSTREAM_IF" ]; then
        trigger_restart "Upstream Interface Disconnected (No Default Route)!"
    elif [ -n "$INITIAL_UPSTREAM_IF" ] && [ "$INITIAL_UPSTREAM_IF" != "$CURRENT_UPSTREAM_IF" ]; then
        trigger_restart "Upstream Interface Changed ($INITIAL_UPSTREAM_IF -> $CURRENT_UPSTREAM_IF)!"
    fi

    # 3. Cek Tun2Socks Crash
    if [ -f "$TUN2SOCKS_PID" ]; then
        TUN_PID=$(cat "$TUN2SOCKS_PID" 2>/dev/null)
        if [ -n "$TUN_PID" ] && ! kill -0 "$TUN_PID" 2>/dev/null; then
            trigger_restart "FATAL: badvpn-tun2socks crashed or died!"
        fi
    fi

    # 4. Tangkap permintaan restart dari client.sh
    if [ -f /tmp/passwall-ssh.need_restart ]; then
        rm -f /tmp/passwall-ssh.need_restart
        trigger_restart "Watchdog menerima sinyal (Restarting Service...)"
    fi

    # Log trimming
    if [ $((LOOP_COUNTER % 150)) -eq 0 ]; then
        if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 50 ]; then
            tail -n 50 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
        fi
    fi
done