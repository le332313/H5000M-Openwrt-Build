#
# Copyright (C) 2009-2016 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#
# ============================================================================
# WHY THIS PACKAGE IS HERE INSTEAD OF COMING FROM UPSTREAM
#
# Upstream moved libffi BETWEEN repository boundaries and the move does not
# line up with this build's pin, so nothing provides it — and a cold build
# fails in python3 with `ffi.h: No such file or directory`, while a build that
# restores the CI cache succeeds because the cached python3 is never recompiled.
# A firmware that can only be built from a cache is not a release.
#
# The sequence, verified from the upstream history on 2026-10-20:
#
#   * openwrt/openwrt main gained `libffi: add package` (9b835ec6) on
#     2026-10-19 12:22 +0200 — i.e. libffi became a package of the TREE.
#   * Before that it lived in the packages feed (libs/libffi) and was removed
#     from there in the same move.
#   * This build pins the tree at 99426e4 (2026-10-16) and lets the feeds
#     follow the branch (FEEDS_FOLLOW_TREE=true), so the tree predates the move
#     while the feed already postdates it. Tree and feed are then from either
#     side of the same relocation, and libffi is on neither side of this build.
#
# The file below is upstream's 9b835ec6 copy verbatim, with only this header
# added, so that the pinned tree keeps being the tree that passed the gates.
# Adding it as a local package (staged into package/libffi) is deliberate: it
# changes nothing else in the tree.
#
# REMOVE THIS DIRECTORY once OPENWRT_PINNED_REVISION moves past 9b835ec6 — at
# that point upstream provides the same package and a second copy would be a
# name clash, not a fix.
# ============================================================================

include $(TOPDIR)/rules.mk

PKG_NAME:=libffi
PKG_VERSION:=3.4.7
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/libffi/libffi/releases/download/v$(PKG_VERSION)
PKG_HASH:=138607dee268bdecf374adf9144c00e839e38541f75f24a1fcf18b78fda48b2d

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_CPE_ID:=cpe:/a:libffi_project:libffi

PKG_INSTALL:=1
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/host-build.mk

define Package/libffi
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=Foreign Function Interface (FFI) library
  URL:=https://sourceware.org/libffi/
  MAINTAINER:=Peter Wagner <tripolar@gmx.at>
endef

define Package/libffi/description
The libffi library provides a portable, high level programming interface to
various calling conventions. This allows a programmer to call any function
specified by a call interface description at run-time.

FFI stands for Foreign Function Interface. A foreign function interface is the
popular name for the interface that allows code written in one language to call
code written in another language. The libffi library really only provides the
lowest, machine dependent layer of a fully featured foreign function interface.
A layer must exist above libffi that handles type conversions for values passed
between the two languages.
endef

HOST_CONFIGURE_ARGS += \
	--disable-shared \
	--disable-docs \
	--disable-multi-os-directory \
	--disable-raw-api \
	--disable-structs \
	--with-pic

CONFIGURE_ARGS += \
	--disable-docs \
	--disable-multi-os-directory \
	--disable-raw-api \
	--disable-structs

define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/lib/pkgconfig
	$(CP) \
		$(PKG_INSTALL_DIR)/usr/lib/libffi.{so*,a,la} \
		$(1)/usr/lib/
	$(CP) \
		$(PKG_INSTALL_DIR)/usr/lib/pkgconfig/* \
		$(1)/usr/lib/pkgconfig/
	$(SED) 's,includedir=.*,includedir=$$$${prefix}/include,' $(1)/usr/lib/pkgconfig/libffi.pc

	$(INSTALL_DIR) $(1)/usr/include
	$(CP) \
		$(PKG_INSTALL_DIR)/usr/include/*.h \
		$(1)/usr/include/
endef

define Package/libffi/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) \
		$(PKG_INSTALL_DIR)/usr/lib/libffi.so.* \
		$(1)/usr/lib/
endef

$(eval $(call HostBuild))
$(eval $(call BuildPackage,libffi))
