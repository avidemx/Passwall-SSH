#!/bin/sh
# Validate SlowDNS settings directly from the dedicated UCI package.
# UDP uses HTTP Custom framing; DoH and DoT use standard DNSTT framing.

UCI_PACKAGE="passwall-ssh-slowdns"
UCI_SECTION="SlowDNS"
LOG="/tmp/etc/passwall-ssh.log"

log_error() {
    mkdir -p /tmp/etc
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SlowDNS config ERROR: $*" >> "$LOG"
}

uci_value() {
    uci -q get "$UCI_PACKAGE.$UCI_SECTION.$1" 2>/dev/null
}

host_ok() {
    printf '%s\n' "$1" | grep -qE '^[A-Za-z0-9.-]+$'
}

ipv4_ok() {
    printf '%s\n' "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

valid_port() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

main() {
    command -v uci >/dev/null 2>&1 || {
        log_error "The uci command was not found."
        return 1
    }

    SLOWDNS_ENABLED=$(uci_value enabled)
    DNS_TRANSPORT=$(uci_value DNS_TRANSPORT)
    DNS_RESOLVER=$(uci_value DNS_RESOLVER)
    DNS_UDP_IP=$(uci_value DNS_UDP_IP)
    DNS_QTYPE=$(uci_value Type_DNS)
    DNSTT_DOMAIN=$(uci_value DNSTT_DOMAIN)
    DNSTT_SERVER_PUBLIC_KEY=$(uci_value DNSTT_SERVER_PUBLIC_KEY)
    SSH_USERNAME=$(uci_value SSH_USERNAME)
    SSH_PASSWORD=$(uci_value SSH_PASSWORD)

    [ "$SLOWDNS_ENABLED" = "1" ] || {
        log_error "SlowDNS Main Switch is OFF."
        return 1
    }

    [ -n "$DNS_TRANSPORT" ] || DNS_TRANSPORT="UDP"
    DNS_TRANSPORT=$(printf '%s' "$DNS_TRANSPORT" | tr '[:lower:]' '[:upper:]')
    [ -n "$DNS_RESOLVER" ] || DNS_RESOLVER="$DNS_UDP_IP"
    [ -n "$DNS_RESOLVER" ] || DNS_RESOLVER="1.1.1.1"

    case "$DNS_TRANSPORT" in
        UDP)
            ipv4_ok "$DNS_RESOLVER" || {
                log_error "UDP DNS resolver must be an IPv4 address."
                return 1
            }
            [ -n "$DNS_QTYPE" ] || DNS_QTYPE="NS"
            case "$DNS_QTYPE" in
                NS|ns) DNS_QTYPE="ns" ;;
                TXT|txt) DNS_QTYPE="txt" ;;
                MX|mx) DNS_QTYPE="mx" ;;
                CNAME|cname) DNS_QTYPE="cname" ;;
                NULL|null) DNS_QTYPE="null" ;;
                SRV|srv) DNS_QTYPE="srv" ;;
                *)
                    log_error "Unsupported HTTP Custom QTYPE: $DNS_QTYPE. Choose NS, TXT, MX, CNAME, NULL, or SRV."
                    return 1
                    ;;
            esac
            ;;
        DOH)
            case "$DNS_RESOLVER" in
                https://*) ;;
                *)
                    log_error "DoH resolver must be a complete HTTPS URL, for example https://cloudflare-dns.com/dns-query."
                    return 1
                    ;;
            esac
            DNS_AUTHORITY=${DNS_RESOLVER#https://}
            DNS_AUTHORITY=${DNS_AUTHORITY%%/*}
            DNS_AUTHORITY=${DNS_AUTHORITY%%\?*}
            DNS_AUTHORITY=${DNS_AUTHORITY%%#*}
            DNS_HOST=${DNS_AUTHORITY%%:*}
            host_ok "$DNS_HOST" || {
                log_error "DoH URL contains an invalid or empty hostname."
                return 1
            }
            case "$DNS_AUTHORITY" in
                *:*)
                    DNS_PORT=${DNS_AUTHORITY##*:}
                    valid_port "$DNS_PORT" || {
                        log_error "DoH URL port must be between 1 and 65535."
                        return 1
                    }
                    ;;
            esac
            ;;
        DOT)
            case "$DNS_RESOLVER" in
                *:*)
                    DNS_HOST=${DNS_RESOLVER%:*}
                    DNS_PORT=${DNS_RESOLVER##*:}
                    ;;
                *)
                    DNS_HOST="$DNS_RESOLVER"
                    DNS_PORT="853"
                    DNS_RESOLVER="$DNS_HOST:853"
                    ;;
            esac
            host_ok "$DNS_HOST" || {
                log_error "DoT resolver must be a hostname or IPv4 address, optionally followed by :853."
                return 1
            }
            valid_port "$DNS_PORT" || {
                log_error "DoT port must be between 1 and 65535."
                return 1
            }
            ;;
        *)
            log_error "Unsupported DNS transport '$DNS_TRANSPORT'. Choose UDP, DoH, or DoT."
            return 1
            ;;
    esac

    [ -n "$DNSTT_DOMAIN" ] || {
        log_error "DNSTT domain is missing."
        return 1
    }
    printf '%s\n' "$DNSTT_DOMAIN" | grep -qE '^[A-Za-z0-9.-]+$' || {
        log_error "DNSTT domain contains invalid characters."
        return 1
    }

    [ -n "$DNSTT_SERVER_PUBLIC_KEY" ] || {
        log_error "Public key is missing."
        return 1
    }

    case "$DNSTT_SERVER_PUBLIC_KEY" in
        /*)
            [ -r "$DNSTT_SERVER_PUBLIC_KEY" ] || {
                log_error "Public key file does not exist or cannot be read."
                return 1
            }
            ;;
        *)
            printf '%s' "$DNSTT_SERVER_PUBLIC_KEY" | grep -qE '^[[:xdigit:]]{64}$' || {
                log_error "Public key must be an absolute file path or a 64-character hexadecimal value."
                return 1
            }
            ;;
    esac

    [ -n "$SSH_USERNAME" ] || {
        log_error "SSH username is missing."
        return 1
    }
    printf '%s\n' "$SSH_USERNAME" | grep -qE '^[A-Za-z0-9._-]+$' || {
        log_error "SSH username contains invalid characters."
        return 1
    }

    [ -n "$SSH_PASSWORD" ] || {
        log_error "SSH password is missing."
        return 1
    }

    mkdir -p /tmp/etc || {
        log_error "Unable to create the log directory."
        return 1
    }

    return 0
}

main "$@"
