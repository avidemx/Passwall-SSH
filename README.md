# Passwall-SSH untuk OpenWrt 24 & 25 🚀

SSH Tunnel ringan untuk OpenWrt dengan dukungan **HTTP Payload**, **TLS (Stunnel)**, **SOCKS5**, dan **BadVPN tun2socks**. Dioptimalkan agar stabil, hemat CPU/RAM, serta memiliki watchdog otomatis untuk menjaga koneksi tetap aktif.

![Screenshot](main.JPG)

## ✨ Fitur

- Mendukung OpenWrt **24 (.ipk)** dan **25 (.apk)**
- Mendukung berbagai arsitektur router
- HTTP Payload (GET, POST, CONNECT, WebSocket)
- HTTP Proxy & TLS (Stunnel)
- BadVPN tun2socks bawaan
- Watchdog otomatis & auto reconnect
- Ringan dan hemat CPU/RAM

---

## 🏷️ Token Payload yang Didukung

### Server

```
[host]
[server]
[ssh]
[ssh_host]
[ip]
[host_no_port]
[port]
[ssh_port]
[host_port]
[ip_port]
```

### Proxy

```
[proxy]
[proxy_host]
[proxy_port]
```

### TLS / SNI

```
[sni]
[sni_host]
[sni_port]
```

### HTTP Request

```
[method]
[protocol]
[raw]
[real_raw]
[realData]
[netData]
[ua]
```

### WebSocket

```
[ws_key]
[ws-key]
```

### Karakter Khusus

```
[crlf]
[cr]
[lf]
```

Mendukung pengulangan:

```
[crlf*2]
[crlf*3]
[lf*5]
```

### Kontrol Payload

```
[split]
[delay_split]
```

### Rotate & Random

```
[rotate=a;b;c]
[random=a;b;c]
```

> **Catatan:** Nama token **case-sensitive**, sehingga harus ditulis persis seperti di atas.
>
> ✅ Benar
> ```
> [host]
> [port]
> [ua]
> ```
>
> ❌ Salah
> ```
> [HOST]
> [Host]
> [PORT]
> ```

---

## 🛠️ Instalasi

Unduh paket yang sesuai pada halaman **Releases**, lalu install melalui SSH.

```bash
# OpenWrt 24
opkg update
opkg install --force-depends /tmp/passwall-ssh_24_*.ipk

# OpenWrt 25
apk update
apk add --allow-untrusted /tmp/passwall-ssh_25_*.apk
```

> **Catatan:** Saat ini hanya mendukung **IPv4**. Nonaktifkan IPv6 sebelum digunakan.

---

## ❤️ Thanks To

- ambrop72 (BadVPN)
- OpenSSH
- ChatGPT
- Gemini
