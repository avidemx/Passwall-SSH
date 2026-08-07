![Screenshot](main.JPG)

# Passwall-SSH for OpenWrt 24 & 25 🚀

**Passwall-SSH** is a lightweight and advanced SSH Tunnel client for OpenWrt, designed for high stability, low CPU/RAM usage, and automatic recovery.

It combines **OpenSSH**, **HTTP Payload Engine**, **Stunnel (TLS/SSL)**, and **BadVPN-tun2socks** into a single easy-to-install package.

---

# ✨ Features

- Supports **OpenWrt 24 (.ipk)** and **OpenWrt 25 (.apk)**
- Supports multiple CPU architectures
- Lightweight and optimized for low-memory routers
- Automatic watchdog with smart connection recovery
- Built-in **BadVPN tun2socks**
- Built-in **Stunnel** for SSL/TLS tunneling
- HTTP Proxy & HTTP Injector support
- Dynamic HTTP Payload Engine
- WebSocket payload support
- HTTP CONNECT support
- Automatic SOCKS5 tunnel creation
- Optimized asynchronous Lua proxy engine
- IPv4 support

---

# HTTP Payload Engine

Passwall-SSH includes a built-in HTTP payload engine compatible with most common HTTP Injector / HTTP Custom payloads used for SSH tunneling.

## Supported Payload Features

- Static payload parsing
- Dynamic token replacement
- HTTP GET / POST / CONNECT payloads
- WebSocket payloads
- HTTP Proxy payloads
- SSL/TLS (Stunnel) payloads
- Payload Split
- Delay Split
- Rotate Payload
- Random Payload
- Automatic HTTP CONNECT handling
- WebSocket Key generation

---

# Supported Tokens

## Server

| Token | Description |
|-------|-------------|
| `[host]` | SSH Host |
| `[server]` | Alias of `[host]` |
| `[ssh]` | Alias of `[host]` |
| `[ssh_host]` | SSH Host |
| `[ip]` | Alias of `[host]` |
| `[host_no_port]` | SSH Host |
| `[port]` | SSH Port |
| `[ssh_port]` | SSH Port |
| `[host_port]` | host:port |
| `[ip_port]` | host:port |

---

## Proxy

| Token | Description |
|-------|-------------|
| `[proxy]` | Proxy Host |
| `[proxy_host]` | Proxy Host |
| `[proxy_port]` | Proxy Port |

---

## TLS / SNI

| Token | Description |
|-------|-------------|
| `[sni]` | SNI Host |
| `[sni_host]` | SNI Host |
| `[sni_port]` | SNI Port (443) |

---

## HTTP Request

| Token | Description |
|-------|-------------|
| `[method]` | HTTP Method |
| `[protocol]` | HTTP/1.1 |
| `[raw]` | Original client request |
| `[real_raw]` | Original client request |
| `[realData]` | Original client request |
| `[netData]` | Original client request |
| `[ua]` | Default User-Agent |

---

## WebSocket

| Token | Description |
|-------|-------------|
| `[ws_key]` | Random Sec-WebSocket-Key |
| `[ws-key]` | Alias of `[ws_key]` |

---

## Special Characters

| Token | Result |
|-------|--------|
| `[crlf]` | `\r\n` |
| `[cr]` | `\r` |
| `[lf]` | `\n` |

Supports multiplier:

```
[crlf*2]
[crlf*3]
[lf*5]
```

---

## Payload Control

### Split

```
GET / HTTP/1.1
...
[split]
SECOND PAYLOAD
```

### Delay Split

```
GET / HTTP/1.1
...
[delay_split]
SECOND PAYLOAD
```

Delay duration follows the configured Delay value.

---

## Rotate

Cycles through payload variants.

```
[rotate=a;b;c]
```

Output:

```
a
b
c
a
b
...
```

---

## Random

Chooses one payload randomly.

```
[random=a;b;c]
```

---

# Token Names

Token names are **case-sensitive**.

Correct:

```
[host]
[server]
[port]
[ua]
[method]
[ws_key]
```

Incorrect:

```
[HOST]
[Host]
[PORT]
[Ua]
[Method]
```

Always use lowercase token names exactly as documented.

---

# Installation

1. Download the latest package from the **Releases** page.
2. Choose the correct package:
   - `.ipk` for OpenWrt 24
   - `.apk` for OpenWrt 25
3. Upload it to `/tmp`
4. Install via SSH

```bash
# OpenWrt 24
opkg update
opkg install --force-depends /tmp/passwall-ssh_24_*.ipk

# OpenWrt 25
apk update
apk add --allow-untrusted /tmp/passwall-ssh_25_*.apk
```

---

# Requirements

- IPv4 only
- Disable IPv6 before use
- OpenSSH
- BadVPN tun2socks
- Stunnel for TLS mode

---

# Thanks

- ambrop72 — BadVPN
- OpenSSH Developers
- LuaSocket Developers
- ChatGPT — Development assistance
- Gemini — Development assistance
