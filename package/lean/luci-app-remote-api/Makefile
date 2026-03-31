include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-remote-api
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=bigbugcc
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=OpenWrt Remote Access API
LUCI_DESCRIPTION:=Provides a REST API service for remote management of OpenWrt via Android apps or WeChat mini-programs. Includes token-based authentication, CORS support, and optional cloud relay integration.
LUCI_DEPENDS:=+uhttpd +uhttpd-mod-ubus +rpcd +libubus +libuci +ubus +openssl-util

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE)
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  $(LUCI_DESCRIPTION)
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
	$(INSTALL_CONF) ./files/etc/config/remote_api $(1)/etc/config/remote_api

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/remote_api $(1)/etc/init.d/remote_api

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/remote-api-ctl $(1)/usr/bin/remote-api-ctl

	$(INSTALL_DIR) $(1)/usr/lib/remote-api
	$(INSTALL_DATA) ./files/usr/lib/remote-api/api.uc $(1)/usr/lib/remote-api/api.uc

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/remote-api.json \
		$(1)/usr/share/rpcd/acl.d/remote-api.json

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/remote_api.lua \
		$(1)/usr/lib/lua/luci/controller/remote_api.lua

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./luasrc/model/cbi/remote_api.lua \
		$(1)/usr/lib/lua/luci/model/cbi/remote_api.lua
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# Generate API secret on first install
if [ ! -f /etc/remote-api.secret ]; then
    /usr/bin/remote-api-ctl generate-secret 2>/dev/null || true
fi
# Enable and start service
/etc/init.d/remote_api enable
/etc/init.d/remote_api start
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/remote_api stop
/etc/init.d/remote_api disable
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
