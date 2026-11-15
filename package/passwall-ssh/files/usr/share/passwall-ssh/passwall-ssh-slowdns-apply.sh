#!/bin/sh
# Validate SlowDNS settings directly from the dedicated UCI package.

UCI_PACKAGE="passwall-ssh-slowdns"
UCI_SECTION="SlowDNS"
LOG="/tmp/etc/passwall-ssh.log"

log_error() {
    mkdir -p /tmp/etc
    printf '<font color="#EF4444">[%s] SlowDNS config ERROR: %s</font>\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
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
        log_error "Perintah uci tidak ditemukan."
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
        log_error "SlowDNS Main Switch dalam kondisi mati (OFF)."
        return 1
    }

    [ -n "$DNS_TRANSPORT" ] || DNS_TRANSPORT="UDP"
    DNS_TRANSPORT=$(printf '%s' "$DNS_TRANSPORT" | tr '[:lower:]' '[:upper:]')
    [ -n "$DNS_RESOLVER" ] || DNS_RESOLVER="$DNS_UDP_IP"
    [ -n "$DNS_RESOLVER" ] || DNS_RESOLVER="1.1.1.1"

    case "$DNS_TRANSPORT" in
        UDP)
            ipv4_ok "$DNS_RESOLVER" || {
                log_error "Resolver DNS UDP harus berupa alamat IPv4 yang valid."
                return 1
            }
            [ -n "$DNS_QTYPE" ] || DNS_QTYPE="AUTO"
            case "$DNS_QTYPE" in
                AUTO|Auto|auto) DNS_QTYPE="auto" ;;
                NS|ns) DNS_QTYPE="ns" ;;
                TXT|txt) DNS_QTYPE="txt" ;;
                MX|mx) DNS_QTYPE="mx" ;;
                CNAME|cname) DNS_QTYPE="cname" ;;
                NULL|null) DNS_QTYPE="null" ;;
                SRV|srv) DNS_QTYPE="srv" ;;
                *)
                    log_error "QTYPE tidak didukung: $DNS_QTYPE. Pilih AUTO, NS, TXT, MX, CNAME, NULL, atau SRV."
                    return 1
                    ;;
            esac
            ;;
        DOH)
            case "$DNS_RESOLVER" in
                https://*) ;;
                *)
                    log_error "Resolver DoH harus berupa URL HTTPS lengkap, misalnya https://cloudflare-dns.com/dns-query."
                    return 1
                    ;;
            esac
            DNS_AUTHORITY=${DNS_RESOLVER#https://}
            DNS_AUTHORITY=${DNS_AUTHORITY%%/*}
            DNS_AUTHORITY=${DNS_AUTHORITY%%\?*}
            DNS_AUTHORITY=${DNS_AUTHORITY%%#*}
            DNS_HOST=${DNS_AUTHORITY%%:*}
            host_ok "$DNS_HOST" || {
                log_error "URL DoH mengandung nama host yang kosong atau tidak valid."
                return 1
            }
            case "$DNS_AUTHORITY" in
                *:*)
                    DNS_PORT=${DNS_AUTHORITY##*:}
                    valid_port "$DNS_PORT" || {
                        log_error "Port pada URL DoH harus antara 1 sampai 65535."
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
                log_error "Resolver DoT harus berupa hostname atau alamat IPv4 (opsional diikuti :853)."
                return 1
            }
            valid_port "$DNS_PORT" || {
                log_error "Port DoT harus antara 1 sampai 65535."
                return 1
            }
            ;;
        *)
            log_error "Transport DNS '$DNS_TRANSPORT' tidak didukung. Pilih UDP, DoH, atau DoT."
            return 1
            ;;
    esac

    [ -n "$DNSTT_DOMAIN" ] || {
        log_error "Name Server (domain DNSTT) belum diisi."
        return 1
    }
    printf '%s\n' "$DNSTT_DOMAIN" | grep -qE '^[A-Za-z0-9.-]+$' || {
        log_error "Name Server (domain DNSTT) mengandung karakter yang tidak valid."
        return 1
    }

    [ -n "$DNSTT_SERVER_PUBLIC_KEY" ] || {
        log_error "Public Key belum diisi."
        return 1
    }

    case "$DNSTT_SERVER_PUBLIC_KEY" in
        /*)
            [ -r "$DNSTT_SERVER_PUBLIC_KEY" ] || {
                log_error "File Public Key tidak ditemukan atau tidak dapat dibaca."
                return 1
            }
            ;;
        *)
            printf '%s' "$DNSTT_SERVER_PUBLIC_KEY" | grep -qE '^[[:xdigit:]]{64}$' || {
                log_error "Public Key harus berupa path file absolut atau 64 karakter heksadesimal."
                return 1
            }
            ;;
    esac

    [ -n "$SSH_USERNAME" ] || {
        log_error "Username SSH belum diisi."
        return 1
    }
    printf '%s\n' "$SSH_USERNAME" | grep -qE '^[A-Za-z0-9._-]+$' || {
        log_error "Username SSH mengandung karakter yang tidak valid."
        return 1
    }

    [ -n "$SSH_PASSWORD" ] || {
        log_error "Password SSH belum diisi."
        return 1
    }

    mkdir -p /tmp/etc || {
        log_error "Gagal membuat direktori log."
        return 1
    }

    return 0
}

main "$@"
