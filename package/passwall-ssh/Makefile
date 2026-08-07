include $(TOPDIR)/rules.mk

PKG_NAME:=passwall-ssh
PKG_VERSION:=3.4.0
PKG_RELEASE:=1

PKG_MAINTAINER:=avidemx
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/passwall-ssh
  SECTION:=net
  CATEGORY:=Network
  TITLE:=SSH Tunnel Client with Stunnel and BadVPN Tun2Socks
  DEPENDS:=+sshpass +curl +openssh-client +stunnel +kmod-tun +dnsproxy +ip-full +lua +luasocket +luci-compat
  PKGARCH:=all
endef

define Package/passwall-ssh/description
  SSH Tunnel Client with Stunnel and BadVPN Tun2Socks for OpenWrt.
endef

# Karena ini cuma script (tidak ada kode C/C++ yang perlu di-compile), Build/Compile dikosongkan
define Build/Compile
endef

define Package/passwall-ssh/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/passwall-ssh
	$(INSTALL_DIR) $(1)/usr/share/passwall-ssh
	
	# Mengopi semua yang ada di folder 'files' ke dalam paket root
	$(CP) ./files/* $(1)/
	
	# Memberi izin eksekusi
	chmod +x $(1)/etc/init.d/passwall-ssh
	chmod +x $(1)/usr/share/passwall-ssh/*.sh
endef

define Package/passwall-ssh/postinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0
for svc in stunnel dnsproxy; do
    if [ -x "/etc/init.d/$$svc" ]; then
        /etc/init.d/$$svc stop >/dev/null 2>&1
        /etc/init.d/$$svc disable >/dev/null 2>&1
        killall "$$svc" >/dev/null 2>&1 || true
    fi
done
exit 0
endef

$(eval $(call BuildPackage,passwall-ssh))
