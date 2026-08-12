include $(TOPDIR)/rules.mk

PKG_NAME:=passwall-ssh
PKG_VERSION:=4.2.0
PKG_RELEASE:=1

PKG_MAINTAINER:=avidemx
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/passwall-ssh
  SECTION:=net
  CATEGORY:=Network
  TITLE:=SSH Tunnel Client with Stunnel and BadVPN-tun2socks
  DEPENDS:=+sshpass +curl +resolveip +openssh-client +stunnel +kmod-tun +dnsproxy +ip-full +lua +luasocket +luci-compat
endef

define Package/passwall-ssh/description
  SSH Tunnel Client with Stunnel and BadVPN-tun2socks.
endef

define Package/passwall-ssh/conffiles
/etc/config/passwall-ssh
endef

define Build/Compile
endef

define Package/passwall-ssh/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/passwall-ssh
	$(INSTALL_DIR) $(1)/usr/share/passwall-ssh
	
	# Salin semua file dari folder 'files'
	$(CP) ./files/* $(1)/
	
	# Berikan izin eksekusi
	chmod 0755 $(1)/etc/init.d/passwall-ssh 2>/dev/null || true
	chmod 0755 $(1)/usr/bin/* 2>/dev/null || true
	chmod 0755 $(1)/usr/share/passwall-ssh/*.sh 2>/dev/null || true
endef

define Package/passwall-ssh/prerm
#!/bin/sh

if [ -x /etc/init.d/stunnel ]; then
    /etc/init.d/stunnel disable >/dev/null 2>&1 || true
fi

if [ -x /etc/init.d/dnsproxy ]; then
    /etc/init.d/dnsproxy disable >/dev/null 2>&1 || true
fi

[ -x /etc/init.d/passwall-ssh ] && \
    /etc/init.d/passwall-ssh stop >/dev/null 2>&1 || true

if [ -x /etc/init.d/stunnel ]; then
    /etc/init.d/stunnel stop >/dev/null 2>&1 || true
fi

if [ -x /etc/init.d/dnsproxy ]; then
    /etc/init.d/dnsproxy stop >/dev/null 2>&1 || true
fi

/bin/sleep 1

exit 0
endef

define Package/passwall-ssh/postinst
#!/bin/sh
exit 0
endef

$(eval $(call BuildPackage,passwall-ssh))
