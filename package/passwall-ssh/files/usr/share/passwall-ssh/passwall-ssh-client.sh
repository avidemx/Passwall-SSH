#!/bin/sh

LOG="/tmp/passwall-ssh.log"
ENV_FILE="/usr/share/passwall-ssh/passwall-ssh.env"
LOCKFILE="/var/run/passwall-client.pid"

# ===================================================================
# 1. SMART LOCK FILE (Mencegah Zombie & Mengatasi Stale Lock)
# ===================================================================
if [ -f "$LOCKFILE" ]; then
    OLD_PID=$(cat "$LOCKFILE" 2>/dev/null)
    # Cek apakah PID lama benar-benar masih hidup di memori
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "<font color=\"#FFA500\">[$(date '+%H:%M:%S')] Script client sudah berjalan. Membatalkan eksekusi duplikat.</font>" >> "$LOG"
        exit 1
    else
        # Ini adalah gembok berkarat (stale lock), hancurkan!
        rm -f "$LOCKFILE"
    fi
fi

# Buat gembok baru dengan PID saat ini
echo $$ > "$LOCKFILE"
# Bersihkan gembok saat script berhenti normal
trap 'rm -f "$LOCKFILE" /tmp/passwall-ssh.fail_count /tmp/passwall-ssh.is_reconnect 2>/dev/null' EXIT INT TERM
# ===================================================================

[ -r "$ENV_FILE" ] || {
    echo "<font color=\"#FF0000\">[$(date '+%H:%M:%S')] ==GAGAL== File konfigurasi tidak ditemukan: $ENV_FILE</font>" >> "$LOG"
    exit 1
}
. "$ENV_FILE"

# Bersihkan flag lama
rm -f /tmp/passwall-ssh.auth_failed
rm -f /tmp/passwall-ssh.kex_failed
rm -f /tmp/passwall-ssh.stop_loop
rm -f /tmp/passwall-ssh.need_restart

# Setup File State (Mengakali Subshell Memory Loss)
FAIL_FILE="/tmp/passwall-ssh.fail_count"
RECONNECT_FILE="/tmp/passwall-ssh.is_reconnect"
echo "0" > "$FAIL_FILE"
echo "0" > "$RECONNECT_FILE"

export SSHPASS="$PASSWORD"

# LOOP UTAMA SSH
while true; do
    if [ -f /tmp/passwall-ssh.stop_loop ] || [ -f /tmp/passwall-ssh.need_restart ]; then
        break
    fi
    
    sshpass -e \
    ssh -v \
    -N \
    -D 1080 \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o NumberOfPasswordPrompts=1 \
    -o HostKeyAlgorithms=+ssh-rsa \
    -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    -o ProxyCommand="nc 127.0.0.1 8080" \
    "$USERNAME@$HOST" 2>&1 | while IFS= read -r raw_line; do

        line="${raw_line//$'\r'/}"
        [ -z "$line" ] && continue

        # Break out dari while read jika ada sinyal eksternal
        if [ -f /tmp/passwall-ssh.stop_loop ] || [ -f /tmp/passwall-ssh.need_restart ]; then
            break
        fi

        case "$line" in
        *"Reading configuration data"*|\
        *"Executing proxy command"*|\
        *"identity file "*|\
        *"load_hostkeys:"*|\
        *"compat_banner:"*|\
        *"order_hostkeyalgs:"*|\
        *"fd "*|\
        *"channel "*|\
        *"OpenSSL "*|\
        *"Connection closed by UNKNOWN"*|\
        *"Warning: Permanently added"*)
            continue 
            ;;

        *"Permission denied"*)
            if [ -f /tmp/passwall-ssh.kex_failed ]; then
                echo "<font color=\"#FFA500\">[$(date '+%H:%M:%S')] Permission denied (Ignored, network glitch)</font>" >> "$LOG"
            else
                echo "<font color=\"#FF0000\">[$(date '+%H:%M:%S')] Authentication Failed</font>" >> "$LOG"
                echo "$line" >> "$LOG"
                echo "$line" > /tmp/passwall-ssh.auth_failed
                touch /tmp/passwall-ssh.stop_loop
            fi
            break
            ;;

        *"Killed by signal"*|\
        *"Received disconnect"*|\
        *"Received signal"*|\
        *"Killed"*|\
        *"Disconnected from"*)
            echo "<font color=\"#FF0000\">[$(date '+%H:%M:%S')] Service Stopped / SSH Terminated</font>" >> "$LOG"
            touch /tmp/passwall-ssh.stop_loop
            break
            ;;

        # ================================================================
        # LOGIKA RESTART (Flag dilempar ke Watchdog)
        # ================================================================
        *"Connection reset"*|\
        *"Connection closed"*|\
        *"Broken pipe"*|\
        *"Connection timed out"*|\
        *"Connection refused"*|\
        *"ssh_exchange_identification:"*|\
        *"kex_exchange_identification: Connection closed"*|\
        *"client_loop:"*|\
        *"packet_write_wait:"*|\
        *"mux_client_request_session:"*|\
        *"Timeout, server "*)
            
            FAILS=$(cat "$FAIL_FILE" 2>/dev/null || echo "0")
            FAILS=$((FAILS + 1))
            echo "$FAILS" > "$FAIL_FILE"
            
            if [ "$FAILS" -ge 3 ]; then
                echo "<font color=\"#FF0000\">[$(date '+%H:%M:%S')] SSH Failed Connected (3x). Meminta Watchdog Restart!</font>" >> "$LOG"
                touch /tmp/passwall-ssh.need_restart
                break
            else
                echo "<font color=\"#FFA500\">[$(date '+%H:%M:%S')] Connection dropped:</font> $line" >> "$LOG"
                echo "<font color=\"#FFFF00\">[$(date '+%H:%M:%S')] SSH Disconnected ($FAILS/3). Retrying...</font>" >> "$LOG"
                continue
            fi
            ;;

        *"Local version string SSH-2.0-"*)
            VER="${line##*SSH-2.0-}"
            echo "<font color=\"#FFFFFF\">[$(date '+%H:%M:%S')] SSH Client : $VER</font>" >> "$LOG"
            continue
            ;;

        *"Remote protocol version "*)
            VER="${line##*remote software version }"
            echo "<font color=\"#FFFFFF\">[$(date '+%H:%M:%S')] SSH Server : $VER</font>" >> "$LOG"
            continue
            ;;

        *"SSH2_MSG_KEXINIT sent"*)
            echo "<font color=\"#FFFFFF\">[$(date '+%H:%M:%S')] Starting Key Exchange</font>" >> "$LOG"
            continue
            ;;

        *"kex: algorithm: "*)
            ALGO="${line##*algorithm: }"
            echo "<font color=\"#FFFFFF\">[$(date '+%H:%M:%S')] Key Exchange : $ALGO</font>" >> "$LOG"
            continue
            ;;

        *"kex: host key algorithm: "*)
            HOSTKEY="${line##*algorithm: }"
            echo "<font color=\"#FFFFFF\">[$(date '+%H:%M:%S')] Host Key : $HOSTKEY</font>" >> "$LOG"
            continue
            ;;

        *"Server host key: "*)
            KEY="${line##*Server host key: }"
            TYPE="${KEY%% SHA256:*}"
            HASH="${KEY#*SHA256:}"
            echo "<font color=\"#FFFFFF\">[$(date '+%H:%M:%S')] Fingerprint : SHA256:$HASH</font>" >> "$LOG"
            continue
            ;;

        *"SSH2_MSG_NEWKEYS received"*)
            echo "<font color=\"#FFFFFF\">[$(date '+%H:%M:%S')] Session Keys Established</font>" >> "$LOG"
            continue
            ;;

        *"Local forwarding listening on 127.0.0.1 port 1080."*)
            echo "<font color=\"#FFFFFF\">[$(date '+%H:%M:%S')] SOCKS5 Listening : 127.0.0.1:1080</font>" >> "$LOG"
            continue
            ;;

        *"Entering interactive session."*)
            echo "0" > "$FAIL_FILE" # Reset error karena berhasil
            
            IS_REC=$(cat "$RECONNECT_FILE" 2>/dev/null || echo "0")
            if [ "$IS_REC" -eq 0 ]; then
                echo "<font color=\"#00FF00\">[$(date '+%H:%M:%S')] Tunnel Ready</font>" >> "$LOG"
                echo "1" > "$RECONNECT_FILE"
            else
                echo "<font color=\"#FFFF00\">[$(date '+%H:%M:%S')] Tunnel Connected</font>" >> "$LOG"
                echo "<font color=\"#00FF00\">[$(date '+%H:%M:%S')] =Service Started=</font>" >> "$LOG"
            fi
            continue
            ;;

        # FILTER DEBUG
        *"debug1:"*|*"debug2:"*|*"debug3:"*)
            continue
            ;;

        *)
            echo "<font color=\"#FFFF00\">[$(date '+%H:%M:%S')] Server Message:</font>" >> "$LOG"
            echo "$line" >> "$LOG"
            ;;
        esac
    done
    
    # Keluar dari inner loop (EOF pipe karena SSH putus/break).
    if [ -f /tmp/passwall-ssh.stop_loop ] || [ -f /tmp/passwall-ssh.need_restart ]; then
        break
    fi
    
    sleep 5
done