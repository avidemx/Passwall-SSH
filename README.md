# Passwall-SSH Openwrt 24 dan 25🚀

**Passwall-SSH** adalah *client* SSH Tunnel tingkat lanjut untuk OpenWrt yang dioptimalkan untuk stabilitas tinggi dan efisiensi CPU/RAM. Proyek ini memadukan kekuatan **OpenSSH**, **Stunnel** (untuk *SSL/TLS cloaking*), dan **BadVPN-tun2Socks** ke dalam satu paket instalasi yang ringan dan mudah digunakan.

---

## ✨ Fitur Utama
* **Multi-Version Support:** Tersedia untuk OpenWrt 24 (`.ipk`) dan OpenWrt 25 (`.apk`).
* **Multi-Architecture:** Mendukung berbagai jenis arsitektur router (RAMIPS, Ath79, Sunxi, Rockchip, Mvebu, dan x86/i386).
* **Watchdog Cerdas:** Memantau ketersediaan port secara *real-time* dan melakukan pemulihan otomatis (auto-restart) secara senyap tanpa membebani sistem.
* **Integrasi BadVPN Bawaan:** File instalasi sudah secara otomatis mencakup *binary* `badvpn-tun2socks` terkompilasi yang disesuaikan khusus dengan arsitektur router Anda.
* **Mendukung TLS/SSL:** Dilengkapi dengan konfigurasi otomatis untuk Stunnel.
* **Performa Optimal:** Telah dioptimalkan untuk mendeteksi kegagalan koneksi atau internet bengong secara cerdas.


**WARNING!!** Hanya bekerja dengan jaringan IPv4. Untuk memulainya, pastikan untuk menonaktifkan IPv6 terlebih dahulu.

---

## 📸 Tampilan Antarmuka

![Screenshot](main.JPG)

---

## 🛠️ Cara Instalasi

1. Buka halaman **[Releases](../../releases/latest)** di repositori ini.
2. Unduh file yang sesuai dengan versi OpenWrt dan arsitektur router Anda:
   * Gunakan format **`.ipk`** untuk **OpenWrt 24.x**
   * Gunakan format **`.apk`** untuk **OpenWrt 25.x**
3. Upload file tersebut ke router OpenWrt (misalnya ke folder `/tmp/`).
4. Jalankan perintah instalasi melalui terminal (SSH):

```bash
# Untuk OpenWrt 24 (.ipk)
opkg update
opkg install --force-depends /tmp/passwall-ssh_24_3.4.0_*.ipk

# Untuk OpenWrt 25 (.apk)
apk update
apk add --allow-untrusted /tmp/passwall-ssh_25_3.4.0_*.apk
```
---

## Thanks To

- [ambrop72](https://github.com/ambrop72/badvpn) — Creator of BadVPN.
- [ChatGPT](https://chatgpt.com) — Assistance with development and debugging.
- [Gemini](https://gemini.google.com) — Assistance with development and scripting.
