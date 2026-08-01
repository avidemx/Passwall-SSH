include $(TOPDIR)/rules.mk

PKG_NAME:=badvpn
PKG_VERSION:=1.999.130
PKG_RELEASE:=5

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/ambrop72/badvpn/archive/$(PKG_VERSION)
PKG_HASH:=skip

PKG_MAINTAINER:=Ambroz Bizjak <ambrop7@gmail.com>
PKG_LICENSE:=BSD-3-Clause

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

CMAKE_OPTIONS += \
	-DBUILD_NOTHING_BY_DEFAULT=1 \
	-DBUILD_TUN2SOCKS=1 \
	-DBUILD_UDPGW=1

define Package/badvpn/Default
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=BadVPN
  URL:=https://github.com/ambrop72/badvpn
endef

define Package/badvpn-tun2socks
  $(call Package/badvpn/Default)
  TITLE:=BadVPN tun2socks
endef

define Package/badvpn-tun2socks/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/badvpn-tun2socks $(1)/usr/bin/
endef

$(eval $(call BuildPackage,badvpn-tun2socks))