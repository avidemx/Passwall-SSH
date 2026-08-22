#!/bin/sh

LOG="/tmp/etc/passwall-ssh.log"
ENV_FILE="/usr/share/passwall-ssh/passwall-ssh.env"
LOCKFILE="/var/run/passwall-client.pid"

# ===================================================================
# 1. SMART LOCK FILE (Mencegah Zombie & Mengatasi Stale Lock)
# ===================================================================
if [ -f "$LOCKFILE" ]; then
    OLD_PID=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        exit 1
    else
        rm -f "$LOCKFILE"
    fi
fi

echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE" /tmp/etc/passwall-ssh.fail_count /tmp/etc/passwall-ssh.is_reconnect 2>/dev/null' EXIT INT TERM
# ===================================================================

[ -r "$ENV_FILE" ] || exit 1

. "$ENV_FILE"

rm -f /tmp/etc/passwall-ssh.auth_failed
rm -f /tmp/etc/passwall-ssh.kex_failed
rm -f /tmp/etc/passwall-ssh.stop_loop
rm -f /tmp/etc/passwall-ssh.need_restart

export SSHPASS="$PASSWORD"

# LOOP UTAMA SSH
while true; do
    if [ -f /tmp/etc/passwall-ssh.stop_loop ] || [ -f /tmp/etc/passwall-ssh.need_restart ]; then
        break
    fi
    
    IS_BANNER=0

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

        SAFE_LINE="$line"

        if [ -f /tmp/etc/passwall-ssh.stop_loop ] || [ -f /tmp/etc/passwall-ssh.need_restart ]; then
            break
        fi

        case "$line" in
        *"HTTP/1.1 101 Switching Protocols"*)
            IS_BANNER=0
            echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] HTTP/1.1 101 Switching Protocols</span>" >> "$LOG"
            continue
            ;;
            
        *"debug1:"*|*"debug2:"*|*"debug3:"*)
            IS_BANNER=0
            continue
            ;;

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
            IS_BANNER=0 # Reset penanda banner
            continue 
            ;;

        *"Permission denied"*)
            IS_BANNER=0 # Reset penanda banner
            if [ -f /tmp/etc/passwall-ssh.kex_failed ]; then
                echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] Permission denied (Ignored, network glitch)</span>" >> "$LOG"
            else
                echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] Authentication Failed</span>" >> "$LOG"
                echo "$line" >> "$LOG"
                echo "$line" > /tmp/etc/passwall-ssh.auth_failed
                touch /tmp/etc/passwall-ssh.stop_loop
            fi
            break
            ;;

        *"Killed by signal"*|\
        *"Received disconnect"*|\
        *"Received signal"*|\
        *"Killed"*|\
        *"Disconnected from"*)
            IS_BANNER=0
            echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] Service Stopped / SSH Terminated</span>" >> "$LOG"
            touch /tmp/etc/passwall-ssh.stop_loop
            break
            ;;

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
            IS_BANNER=0
            echo "<font color=\"#FF0000\">[$(date '+%Y-%m-%d %H:%M:%S')] $line</font>" >> "$LOG"
            touch /tmp/etc/passwall-ssh.need_restart
            break
            ;;

        *"Local version string SSH-2.0-"*)
            IS_BANNER=0
            VER="${line##*SSH-2.0-}"
            echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] SSH Client : $VER</span>" >> "$LOG"
            continue
            ;;

        *"Remote protocol version "*)
            IS_BANNER=0
            VER="${line##*remote software version }"
            echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] SSH Server : $VER</span>" >> "$LOG"
            continue
            ;;

        *"SSH2_MSG_KEXINIT sent"*)
            IS_BANNER=0
            echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] Starting Key Exchange</span>" >> "$LOG"
            continue
            ;;

        *"kex: algorithm: "*)
            IS_BANNER=0
            ALGO="${line##*algorithm: }"
            echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] Key Exchange : $ALGO</span>" >> "$LOG"
            continue
            ;;

        *"kex: host key algorithm: "*)
            IS_BANNER=0
            HOSTKEY="${line##*algorithm: }"
            echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] Host Key : $HOSTKEY</span>" >> "$LOG"
            continue
            ;;

        *"Server host key: "*)
            IS_BANNER=0
            KEY="${line##*Server host key: }"
            TYPE="${KEY%% SHA256:*}"
            HASH="${KEY#*SHA256:}"
            echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] Fingerprint : SHA256:$HASH</span>" >> "$LOG"
            continue
            ;;

        *"SSH2_MSG_NEWKEYS received"*)
            IS_BANNER=0
            echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] Session Keys Established</span>" >> "$LOG"
            continue
            ;;

        *"Local forwarding listening on 127.0.0.1 port 1080."*)
            IS_BANNER=0
            echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] SOCKS5 Listening : 127.0.0.1:1080</span>" >> "$LOG"
            continue
            ;;

        *)
            CLEAN_LINE="$SAFE_LINE"
            while true; do
                case "$CLEAN_LINE" in
                    *"<"*">"*)
                        left="${CLEAN_LINE%%<*}"
                        right="${CLEAN_LINE#*>}"
                        CLEAN_LINE="${left}${right}"
                        ;;
                    *)
                        break
                        ;;
                esac
            done

            [ -z "$CLEAN_LINE" ] && continue

            if [ "$IS_BANNER" -eq 0 ]; then
                echo "<span color=\"#3C86AB\">[$(date '+%Y-%m-%d %H:%M:%S')] Server Message:</span>" >> "$LOG"
                IS_BANNER=1
            fi
            
            echo "$CLEAN_LINE" >> "$LOG"
            ;;
        esac
    done
    
    if [ -f /tmp/etc/passwall-ssh.stop_loop ] || [ -f /tmp/etc/passwall-ssh.need_restart ]; then
        break
    fi
    
    sleep 5
done
