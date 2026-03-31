include $(TOPDIR)/rules.mk

PKG_NAME:=remote-api-relay
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=bigbugcc
PKG_LICENSE:=Apache-2.0

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Remote API Cloud Relay Client
  DEPENDS:=+luci-app-remote-api
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  Cloud relay client for the Remote API package. Establishes an outbound
  connection to a relay server so that mobile clients can access the router
  management API without requiring port forwarding or a public IP address.
  Supports SSH reverse-tunnel and WebSocket relay modes.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/relay_client $(1)/etc/config/relay_client

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/relay_client $(1)/etc/init.d/relay_client

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/relay-client $(1)/usr/bin/relay-client

	$(INSTALL_DIR) $(1)/usr/share/remote-api-relay
	$(INSTALL_DATA) ./files/usr/share/remote-api-relay/relay-server-example.conf \
		$(1)/usr/share/remote-api-relay/relay-server-example.conf
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
echo "remote-api-relay installed."
echo "Configure /etc/config/relay_client, then run:"
echo "  /etc/init.d/relay_client enable && /etc/init.d/relay_client start"
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/relay_client stop
/etc/init.d/relay_client disable
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
