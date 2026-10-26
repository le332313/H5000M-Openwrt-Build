#
# h5000m-integration — board glue for the Hiveton H5000M on mainline OpenWrt.
#
# This package has TWO jobs, and which one is live depends on the modem stack
# the image was built with.  Keeping them in one package is deliberate: the
# first-boot defaults below are needed by every image, and the WWAN seam is
# inert when its stack is absent (see the DEPENDS comment).
#
# ---------------------------------------------------------------------------
# JOB 1 (every image): product defaults that make a fresh flash usable.
#
#   usr/sbin/h5000m-firstboot          turn the radios on, enable the PPE
#                                      hardware flow offload
#   etc/uci-defaults/92-h5000m-defaults
#   etc/hotplug.d/ieee80211/20-h5000m-defaults
#   lib/upgrade/keep.d/h5000m-defaults
#
# This is the part that matters on a QModem build, and it is why the package
# cannot simply be deleted when wwand is off.
#
# ---------------------------------------------------------------------------
# JOB 2 (wwand images only): the wwand <-> netmode seam.
#
# The H5000M's built-in cellular module is a TD Tech MT5700M (USB 3466:3301)
# which enumerates as a cdc_ncm device with AT side channels.  wwand dials it
# through its NCM backend; luci-app-h5000m-netmode arbitrates between the wired
# WAN (eth1) and that cellular interface.
#
# The two daemons never meet on their own, so this package is the seam:
#
#   * luci-app-h5000m-netmode discovers the 5G side by NAME.  Its
#     discover_modem_interfaces() reads network.MT5700M.device / .ifname and
#     otherwise falls back to a section literally named MT5700M or USB.  Its
#     iface hotplug guard additionally ignores events for any interface that
#     carries neither `modem_config` nor `managed_by mt5700m`.
#
#   * wwand has no /etc/config/wwand — configuration lives in
#     /etc/config/network as `config wwand_modem` + `config interface`
#     with `option proto 'wwand'`.
#
# So the first-boot provisioner creates exactly that shape:
#
#   config wwand_modem 'm0'        option device/path -> the MT5700M
#   config interface 'MT5700M'     proto wwand, modem m0, modem_config set
#
# IPv6 is deliberately NOT given a companion dhcpv6 interface.  wwand's own
# docs (docs/reference.md, "RNDIS IPv6 — the dhcpv6 subinterface") are explicit
# that the `<parent>_6` dhcpv6 subinterface belongs to the **rndis_host**
# datapath, that `extendprefix '1'` applies **only to `pdp_type 'ipv6'`**, and
# that "the `proto wwand` path needs no equivalent — the shim already shares its
# own /64".  The MT5700M is a cdc_ncm modem on the proto wwand path, so a
# companion interface here would be wrong twice over: it would set prefix
# sharing on a dual-stack APN, and because wwand treats a user-defined
# `device '@<parent>'` + proto dhcpv6 section as "the user owns this", it would
# also stop wwand from managing IPv6 at all.
#
# Result: wwand owns the datapath and its own IPv6, netmode sees a first-class
# modem interface, and neither package is forked or patched.  If the module is
# not yet enumerated the provisioner leaves the box alone and wwand's own
# autosetup creates its default `wwan0`/`wwmodem_auto` interface instead.
#
# On a QModem image (the H5000M's current configuration — the units in the wild
# carry a Quectel RG520N-CN, and HigoOS drives it through the QModem ubus
# objects) resolve_modem_stack() forces ENABLE_WWAND=false, so this half simply
# never fires: the provisioner exits at its first line because
# /lib/netifd/proto/wwand.sh is absent.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-integration
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=AutoBuild-H5000M-Openwrt <noreply@example.invalid>

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-integration
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=Hiveton H5000M WWAN <-> netmode integration glue
  # NO wwand dependency, conditional or otherwise.
  #
  # This used to read `DEPENDS:=+PACKAGE_wwand:wwand +PACKAGE_wwand:luci-proto-wwand`,
  # meaning "require wwand only when it is already selected".  That form is a
  # trap: the wwand feed is installed only when ENABLE_WWAND=true, so on a
  # QModem build the symbol PACKAGE_wwand does not exist at all.  A conditional
  # dependency on a symbol that is absent degrades into a bad reference:
  #
  #   WARNING: Makefile 'package/h5000m-integration/Makefile' has a dependency
  #            on 'wwand', which does not exist
  #
  # and kconfig then drops PACKAGE_h5000m-integration — which is DEFAULT:=y and
  # sits in REQUIRED_PACKAGES.  Measured: dropping it took the whole QModem
  # chain (qmodem, luci-app-qmodem-next, luci-app-qmodem-generic) with it, and
  # verify_config() refused the build.  The guard rail was right; the Makefile
  # was wrong.
  #
  # Nothing here actually needs wwand.  Of the seven files this package
  # installs, only h5000m-wwan-provision touches wwand, and it begins with
  #
  #   [ ! -e /lib/netifd/proto/wwand.sh ] && exit 0
  #
  # so it no-ops by itself on a QModem image.  Its other three callers
  # (uci-defaults/91, hotplug.d/usb/50, and the two ieee80211/uci-defaults
  # wrappers) just invoke it and are equally inert.  What remains —
  # h5000m-firstboot with uci-defaults/92 and hotplug.d/ieee80211/20 — turns
  # the radios on and enables the PPE flow offload, and needs only busybox
  # (uci, logger) plus the base system.
  #
  # So the correct dependency set is "no third-party package at all", not a
  # different package name.  Deliberately empty rather than `+netifd +ubus`:
  # those would be invented, and an invented dependency is exactly the kind of
  # thing that fails a build the day upstream renames a symbol.
  DEPENDS:=
  DEFAULT:=y if TARGET_mediatek_filogic_DEVICE_hiveton_h5000m
endef

define Package/h5000m-integration/description
  Board glue for the Hiveton H5000M.  Two jobs, one package.

  Every image gets the product defaults: the radios are switched on with a
  documented country and SSID, and the PPE hardware flow offload is enabled
  through the standard netfilter flowtable API (mainline has no MTK HNAT, so
  this is what hardware acceleration means here).

  A wwand image additionally gets the WWAN seam: the TD Tech MT5700M is
  provisioned as a single dual-stack wwand interface and published under the
  name luci-app-h5000m-netmode expects, so 5G / wired-WAN egress priority
  works without patching either package.  wwand's proto shim already handles
  IPv6 including sharing its own /64, and its documentation warns that a
  hand-written companion dhcpv6 interface would both mis-set extendprefix and
  take IPv6 away from wwand.

  On a QModem image that seam is inert by design — the provisioner exits
  immediately when the wwand protocol handler is not installed — which is why
  this package declares no dependency on wwand.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/h5000m-integration/install
	# Copy the whole files/ tree rather than naming each file.  Naming them is
	# how the first-boot defaults ended up committed but never installed: the
	# Makefile listed three files and silently ignored the four new ones.
	#
	# ★ 2026-10-19 更正：这里原来写着「$(CP) preserves the source modes, so
	# scripts stay 0755」，那句话是错的。$(CP) 保留的是**源文件**权限，而源权限
	# 在 CI 上完全由 git 索引决定 —— Windows checkout 不体现权限，`ls -l` 看着
	# 是 755 也没用。h5000m-devices-collect.sh 的索引记录是 100644，于是
	# CI 拿到 644、装进镜像 644，设备上 cron 每分钟 Permission denied：
	# 文件在、md5 对、闸门全绿，而 v4 巡检能力实际为零，刷机后两天没人发现。
	# 所以显式 chmod，让结果不再取决于谁在哪个操作系统上提交。
	#
	# Layout, all under files/:
	#   usr/sbin/h5000m-wwan-provision          wwand interface provisioning
	#   usr/sbin/h5000m-firstboot               WiFi + flow-offload defaults
	#   usr/sbin/h5000m-devices-collect.sh      device-page cache health check
	#   etc/uci-defaults/91-h5000m-wwan         first boot: provision the modem
	#   etc/uci-defaults/92-h5000m-defaults     first boot: WiFi + offload
	#   etc/hotplug.d/usb/50-h5000m-wwan        modem enumerated later
	#   etc/hotplug.d/ieee80211/20-h5000m-defaults  radio appeared (after
	#                                          10-wifi-detect, which is what
	#                                          creates /etc/config/wireless)
	#   etc/higoros/higoros-devices-cache.json  boot seed for the device page,
	#                                          deliberately empty (see keep.d)
	#   lib/upgrade/keep.d/h5000m-defaults      preserve the applied marker
	#   etc/h5000m-defaults.conf                generated at build time
	#   etc/apk/repositories.d/50-h5000m.list   generated when a repo URL is set
	$(INSTALL_DIR) $(1)
	$(CP) ./files/* $(1)/
	chmod 0755 $(1)/usr/sbin/h5000m-*
	chmod 0755 $(1)/etc/uci-defaults/9?-h5000m-*
	chmod 0755 $(1)/etc/hotplug.d/usb/50-h5000m-*
	chmod 0755 $(1)/etc/hotplug.d/ieee80211/20-h5000m-*
endef

$(eval $(call BuildPackage,h5000m-integration))
