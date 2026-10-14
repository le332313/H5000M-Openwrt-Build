#!/usr/bin/env bash
#
# rootfs-script-test.sh — run the firmware's own first-boot scripts against the
# REAL aarch64 uci binary, on the host, without root.
#
# Why this exists: the first-boot defaults were written, reviewed, and "verified"
# with a shell mock of uci — and shipped a bug that made both headline features
# silently do nothing.  The script called
#
#     uci -q set "wireless.radio0.disabled='0'"
#
# where the quotes sit INSIDE the double-quoted argument, so uci stores the value
# as the literal `'0'` rather than `0`.  OpenWrt's config_get_bool does not
# recognise `'0'` as false and falls back to the default, so the radio stayed
# disabled while /etc/config/wireless looked correct.  A mock that echoes back
# whatever string it is handed cannot catch that; the real parser can.  Note that
# `uci batch` DOES strip the quotes, so both forms are in use in this tree and
# only one of them is wrong.
#
# How it works: the rootfs tarball is extracted, and the aarch64 uci from that
# rootfs is executed under qemu-aarch64-static with `-c` pointing at a scratch
# config directory.  qemu-user alone would resolve absolute paths against the
# host, and `-L` only fixes the loader, so `-c` is what keeps the test away from
# the host's own /etc — verified: this never writes to the host /etc/config.
#
# Requirements: qemu-aarch64-static on PATH or in $QEMU_AARCH64.
#   curl -sfL -o ~/.local/bin/qemu-aarch64-static \
#     https://github.com/multiarch/qemu-user-static/releases/latest/download/qemu-aarch64-static
#   chmod +x ~/.local/bin/qemu-aarch64-static
#
# Usage: scripts/rootfs-script-test.sh [path/to/rootfs.tar.gz]
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The real artifact name ends in -targz-rootfs.tar.gz: image.mk builds device
# images as $(IMG_PREFIX)-$(PROFILE)-<fs>-<image>, i.e.
# openwrt-mediatek-filogic-hiveton_h5000m-targz-rootfs.tar.gz.  A hardcoded
# ...-rootfs.tar.gz guess made this script refuse its own build output, so with
# no argument pick whatever rootfs tarball the last local build produced.
ROOTFS_TARBALL="${1:-}"
if [ -z "$ROOTFS_TARBALL" ]; then
	for f in "${ROOT_DIR}"/artifacts/*-targz-rootfs.tar.gz "${ROOT_DIR}"/artifacts/*-rootfs.tar.gz; do
		if [ -f "$f" ]; then
			ROOTFS_TARBALL="$f"
			break
		fi
	done
fi
: "${ROOTFS_TARBALL:=${ROOT_DIR}/artifacts/openwrt-mediatek-filogic-hiveton_h5000m-targz-rootfs.tar.gz}"
QEMU_AARCH64="${QEMU_AARCH64:-$(command -v qemu-aarch64-static || true)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() {
	printf '  \033[1;32mPASS\033[0m %s\n' "$1"
	pass=$((pass + 1))
}
bad() {
	printf '  \033[1;31mFAIL\033[0m %s\n' "$1"
	fail=$((fail + 1))
}
check() { # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 — expected [$2], got [$3]"; fi
}

[ -n "$QEMU_AARCH64" ] || {
	echo "qemu-aarch64-static not found; see the header of this script" >&2
	exit 2
}
[ -f "$ROOTFS_TARBALL" ] || {
	echo "rootfs tarball not found: $ROOTFS_TARBALL" >&2
	exit 2
}

echo "== extracting $(basename "$ROOTFS_TARBALL")"
mkdir -p "$WORK/root"
tar -xzf "$ROOTFS_TARBALL" -C "$WORK/root"

UCI="$WORK/root/sbin/uci"
[ -x "$UCI" ] || {
	echo "no uci in the rootfs" >&2
	exit 2
}
file "$UCI" | grep -q aarch64 || {
	echo "$UCI is not aarch64 — wrong artifact?" >&2
	exit 2
}

# The real uci, with -c so it reads and writes our scratch config dir and never
# the host's /etc/config.
mkdir -p "$WORK/bin" "$WORK/config"
cat >"$WORK/bin/uci" <<EOF
#!/bin/sh
exec "${QEMU_AARCH64}" -L "$WORK/root" "$UCI" -c "$WORK/config" "\$@"
EOF
chmod +x "$WORK/bin/uci"
export PATH="$WORK/bin:$PATH"

# The script under test, with its absolute runtime paths redirected.  Only the
# paths change; the uci invocations are exactly what ships.
SCRIPT="$WORK/root/usr/sbin/h5000m-firstboot"
[ -f "$SCRIPT" ] || {
	echo "h5000m-firstboot missing from the rootfs" >&2
	exit 2
}
sed -e "s|/etc/config/|$WORK/config/|g" \
	-e "s|/etc/h5000m-defaults.conf|$WORK/h5000m-defaults.conf|g" \
	-e "s|/etc/h5000m-wifi-applied|$WORK/marker-wifi|g" \
	-e "s|/etc/h5000m-offload-applied|$WORK/marker-offload|g" \
	-e 's|^\[ -n "${IPKG_INSTROOT:-}" \]|false|' \
	"$SCRIPT" >"$WORK/firstboot"

# /etc/h5000m-defaults.conf as the package installs it.
cp "$WORK/root/etc/h5000m-defaults.conf" "$WORK/h5000m-defaults.conf"
# shellcheck source=/dev/null
. "$WORK/h5000m-defaults.conf"

seed_wireless() { # seed_wireless <ssid2g> [ssid5g]
	# Two names can be seeded independently because the default is one name per
	# band; a single argument still seeds both, which is how a factory-fresh or
	# an owner-configured (shared name) wireless config looks.
	local s2g="$1" s5g="${2:-$1}"
	cat >"$WORK/config/wireless" <<EOF
config wifi-device 'radio0'
	option type 'mac80211'
	option band '2g'
	option disabled '1'

config wifi-device 'radio1'
	option type 'mac80211'
	option band '5g'
	option disabled '1'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option mode 'ap'
	option ssid '$s2g'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option mode 'ap'
	option ssid '$s5g'
EOF
	printf "config defaults\n\toption input 'REJECT'\n" >"$WORK/config/firewall"
	rm -f "$WORK/marker-wifi" "$WORK/marker-offload"
}

echo
echo "== profile: untouched first boot — WiFi must come up and offload turn on"
seed_wireless OpenWrt
sh "$WORK/firstboot"

check "radio0.country" "$H5000M_WIFI_COUNTRY" "$(uci -q get wireless.radio0.country)"
check "radio0.disabled" "0" "$(uci -q get wireless.radio0.disabled)"
check "radio0.htmode" "$H5000M_WIFI_HTMODE_2G" "$(uci -q get wireless.radio0.htmode)"
check "radio1.htmode" "$H5000M_WIFI_HTMODE_5G" "$(uci -q get wireless.radio1.htmode)"
# Each band carries its own name, and BOTH are asserted: with distinct per-band
# names a copy/paste error in one of them leaves the other band looking fine.
check "default_radio0.ssid (2.4 GHz name)" "$H5000M_WIFI_SSID_2G" "$(uci -q get wireless.default_radio0.ssid)"
check "default_radio1.ssid (5 GHz name)" "$H5000M_WIFI_SSID_5G" "$(uci -q get wireless.default_radio1.ssid)"
check "default_radio0.key" "$H5000M_WIFI_KEY" "$(uci -q get wireless.default_radio0.key)"
check "default_radio0.enc" "$H5000M_WIFI_ENCRYPTION" "$(uci -q get wireless.default_radio0.encryption)"
check "default_radio1.key" "$H5000M_WIFI_KEY" "$(uci -q get wireless.default_radio1.key)"
check "default_radio1.enc" "$H5000M_WIFI_ENCRYPTION" "$(uci -q get wireless.default_radio1.encryption)"
# sae-mixed is refused by hostapd unless PMF is at least optional, so the two
# settings ship together or the AP does not come up at all.
check "default_radio0.ieee80211w (PMF optional, required by sae-mixed)" "1" "$(uci -q get wireless.default_radio0.ieee80211w)"
check "default_radio1.ieee80211w" "1" "$(uci -q get wireless.default_radio1.ieee80211w)"
check "flow_offloading" "$H5000M_FLOW_OFFLOAD" "$(uci -q get firewall.@defaults[0].flow_offloading)"
check "flow_offloading_hw" "$H5000M_FLOW_OFFLOAD_HW" "$(uci -q get firewall.@defaults[0].flow_offloading_hw)"

# The bug this test was written for: a value stored with literal quotes still
# reads back looking plausible, so assert on the raw file too.
if grep -q "disabled ''" "$WORK/config/wireless"; then
	bad "wireless config holds quote-wrapped values (uci set \"k='v'\" bug)"
else
	ok "wireless config has no quote-wrapped values"
fi

echo
echo "== profile: the SSID already carries THIS image's name — the pass stays idempotent"
# A lost marker must not freeze the WiFi defaults at the previous build just
# because the guard read our own SSID as "the owner's choice".  Re-applying has
# to be a no-op in effect: same names, same key, same country.
seed_wireless "$H5000M_WIFI_SSID_2G" "$H5000M_WIFI_SSID_5G"
sh "$WORK/firstboot"
check "still our 2.4 GHz name" "$H5000M_WIFI_SSID_2G" "$(uci -q get wireless.default_radio0.ssid)"
check "still our 5 GHz name" "$H5000M_WIFI_SSID_5G" "$(uci -q get wireless.default_radio1.ssid)"
check "key reapplied" "$H5000M_WIFI_KEY" "$(uci -q get wireless.default_radio0.key)"
check "country reapplied" "$H5000M_WIFI_COUNTRY" "$(uci -q get wireless.radio0.country)"
check "marker written (the pass really did apply)" "yes" "$([ -e "$WORK/marker-wifi" ] && echo yes || echo no)"

echo
echo "== profile: the SSID is the BASE name (a half-applied state) — must be split"
# The base name is what an interrupted run, or a device configured before the
# per-band split existed, looks like.  It has to count as default as well: a
# guard that reads it as the owner's choice freezes the device on the base name
# and the per-band names never arrive.  Measured on a real device: the run
# returned 1, wrote no marker, logged nothing, and both radios stayed on
# "Higoros-H5000M".
seed_wireless "$H5000M_WIFI_SSID"
sh "$WORK/firstboot"
check "base name split to the 2.4 GHz name" "$H5000M_WIFI_SSID_2G" "$(uci -q get wireless.default_radio0.ssid)"
check "base name split to the 5 GHz name" "$H5000M_WIFI_SSID_5G" "$(uci -q get wireless.default_radio1.ssid)"
check "key applied on the split" "$H5000M_WIFI_KEY" "$(uci -q get wireless.default_radio0.key)"

echo
echo "== profile: owner already changed the SSID — nothing may be touched"
seed_wireless MyOwnWiFi
sh "$WORK/firstboot"
check "ssid preserved (2.4 GHz)" "MyOwnWiFi" "$(uci -q get wireless.default_radio0.ssid)"
check "ssid preserved (5 GHz)" "MyOwnWiFi" "$(uci -q get wireless.default_radio1.ssid)"
check "radio0.disabled kept" "1" "$(uci -q get wireless.radio0.disabled)"
check "no key written onto the owner's network" "" "$(uci -q get wireless.default_radio0.key)"
check "no htmode written onto the owner's radios" "" "$(uci -q get wireless.radio0.htmode)"
check "offload still applied" "$H5000M_FLOW_OFFLOAD" "$(uci -q get firewall.@defaults[0].flow_offloading)"

echo
echo "== profile: ONE band carries our name, the other is the owner's — all or nothing"
# The guard is per-device, not per-radio: one owner-changed band stops the whole
# pass.  Mixed state is exactly what a half-applied config leaves behind, and
# overwriting the owner's band to "fix" it is worse than doing nothing.
seed_wireless "$H5000M_WIFI_SSID_2G" 'MyOwnWiFi'
sh "$WORK/firstboot"
check "the owner's band untouched" "MyOwnWiFi" "$(uci -q get wireless.default_radio1.ssid)"
check "our band not re-keyed either" "" "$(uci -q get wireless.default_radio0.key)"
check "radio0.disabled kept" "1" "$(uci -q get wireless.radio0.disabled)"

echo
echo "== profile: an open network via a build override (ENCRYPTION=none) — no stray key"
# The shipped default is now encrypted, but the key and the encryption mode stay
# build inputs, so the open-network path has to keep working.  An empty key or
# encryption=none must DELETE key and ieee80211w: leaving an empty option behind,
# or asking for PMF on an unencrypted interface, makes hostapd reject the whole
# AP configuration instead of ignoring the extra options.
cp "$WORK/h5000m-defaults.conf" "$WORK/h5000m-defaults.conf.saved"
cat >"$WORK/h5000m-defaults.conf" <<'OPENEOF'
H5000M_WIFI_SSID='OpenNetworkH5000M'
H5000M_WIFI_SSID_2G='OpenNetworkH5000M-2.4G'
H5000M_WIFI_SSID_5G='OpenNetworkH5000M-5G'
H5000M_WIFI_KEY=''
H5000M_WIFI_COUNTRY='CN'
H5000M_WIFI_ENCRYPTION='none'
H5000M_WIFI_HTMODE_2G='EHT40'
H5000M_WIFI_HTMODE_5G='EHT160'
H5000M_FLOW_OFFLOAD='1'
H5000M_FLOW_OFFLOAD_HW='1'
OPENEOF
seed_wireless OpenWrt
sh "$WORK/firstboot"
check "open: encryption" "none" "$(uci -q get wireless.default_radio0.encryption)"
check "open: 2.4 GHz name from the override" "OpenNetworkH5000M-2.4G" "$(uci -q get wireless.default_radio0.ssid)"
check "open: 5 GHz name from the override" "OpenNetworkH5000M-5G" "$(uci -q get wireless.default_radio1.ssid)"
check "open: no empty key left behind" "" "$(uci -q get wireless.default_radio0.key)"
check "open: no PMF left behind" "" "$(uci -q get wireless.default_radio0.ieee80211w)"
mv "$WORK/h5000m-defaults.conf.saved" "$WORK/h5000m-defaults.conf"

echo
echo "== profile: /etc/config/wireless exists but is EMPTY (as the image ships it)"
# The image ships an empty wireless file.  If the marker is written on the
# strength of the file merely existing, the ieee80211 hotplug that later fills in
# the radios finds the marker and skips for ever, and WiFi is never enabled.
cat >"$WORK/config/firewall" <<'FWEOS'
config defaults
	option input 'REJECT'
FWEOS
: >"$WORK/config/wireless"
rm -f "$WORK/marker-wifi" "$WORK/marker-offload"
sh "$WORK/firstboot"
if [ -e "$WORK/marker-wifi" ]; then
	bad "wifi marker written with no radios present — WiFi would never be configured"
else
	ok "wifi marker not written (no radios yet) and the hotplug pass can still apply it"
fi
check "offload still applied independently" "$H5000M_FLOW_OFFLOAD" "$(uci -q get firewall.@defaults[0].flow_offloading)"

echo
echo "== profile: marker present — second boot must be a no-op"
seed_wireless OpenWrt
touch "$WORK/marker-wifi" "$WORK/marker-offload"
sh "$WORK/firstboot"
check "radio0.disabled kept" "1" "$(uci -q get wireless.radio0.disabled)"
check "offload not applied" "" "$(uci -q get firewall.@defaults[0].flow_offloading)"

echo
echo "== the acceleration applier against the real uci (the eBPF IPv6 bypass repair)"
# Why this is here, and why a mock cannot do it: the applier answers "is this
# entry already in the bypass list?" while adding the router's own IPv6 to
# Nikki-RS's eBPF bypass list.  Written against a mock that printed a list one
# value per line, it looked right — but THIS uci prints a list on a SINGLE line
# with the values separated by a space (cli.c: uci_show_value, UCI_TYPE_LIST), so
# the whole-line comparison never matched and every run appended a second copy of
# every entry.  Measured: 7 entries became 17 after two applies, and the list
# would grow by five on every boot.  Only the real parser shows that.
ACCEL_SRC="$WORK/root/usr/sbin/h5000m-accel"
[ -f "$ACCEL_SRC" ] || {
	echo "h5000m-accel missing from the rootfs" >&2
	exit 2
}
# Only the absolute runtime paths change; the uci invocations are what ships.
sed -e "s|/etc/config/|$WORK/config/|g" \
	-e "s|/proc/net/if_inet6|$WORK/if_inet6|g" \
	-e "s|/etc/init.d/nikki-rs|$WORK/no-such-initd|g" \
	-e "s|/etc/init.d/firewall|$WORK/no-such-initd|g" \
	"$ACCEL_SRC" >"$WORK/accel"

# apply_settings really does write net.ipv4.tcp_congestion_control through
# sysctl, and the eBPF path loads modules: none of that belongs on the machine
# running the test, so the three commands that reach outside the scratch config
# are stubbed (the harness already has $WORK/bin first on PATH for uci).
for t in sysctl modprobe logger; do
	printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/$t"
	chmod +x "$WORK/bin/$t"
done

# Two prefixes on the filtered interface, plus the three shapes that have to be
# ignored: link-local (scope 0x20), host scope (0x10), and a global address on an
# interface the hook does not filter.  Field order is address, ifindex,
# prefixlen, scope, flags, devname.
cat >"$WORK/if_inet6" <<'IFINET6'
fd12000000000000000000000000002a 02 40 00 00 br-lan
20010db800000000000000000000002a 02 40 00 00 br-lan
fe80000000000000000000000000002a 02 40 20 80 br-lan
00000000000000000000000000000001 01 80 10 80 lo
20010db800000001000000000000002a 03 40 00 00 wan0
IFINET6

seed_ebpf() { # seed_ebpf <enabled>
	cat >"$WORK/config/nikki-rs" <<EOF
config ebpf 'ebpf'
	option enabled '${1:-1}'
	list lan_interface 'br-lan'
	list bypass_dst_ips '127.0.0.0/8'
	list bypass_dst_ips '169.254.0.0/16'
	list bypass_dst_ips '192.168.0.0/16'
	list bypass_dst_ips '224.0.0.0/4'
	list bypass_dst_ips '::1/128'
	list bypass_dst_ips 'fe80::/10'
	list bypass_dst_ips 'ff00::/8'
EOF
	# The applier refuses to touch the firewall before this section exists, and
	# the eBPF path is left to Nikki-RS by the 'keep' default.
	printf "config defaults\n\toption input 'REJECT'\n" >"$WORK/config/firewall"
	printf "config settings 'settings'\n\toption profile 'compat'\n\toption fullcone '0'\n\toption ebpf_proxy 'keep'\n" >"$WORK/config/h5000m_accel"
}

# Count tokens, not lines: counting lines would itself encode the bug this test
# exists for.
bypass_count() { uci -q get nikki-rs.ebpf.bypass_dst_ips | tr ' ' '\n' | grep -c .; }
bypass_has() {
	case " $(uci -q get nikki-rs.ebpf.bypass_dst_ips) " in
		*" $1 "*) return 0 ;;
		*) return 1 ;;
	esac
}

seed_ebpf 1
sh "$WORK/accel" apply
check "bypass entries after the first apply" "10" "$(bypass_count)"
for entry in 'fc00::/7' 'fd12:0:0:0:0:0:0:0/64' '2001:db8:0:0:0:0:0:0/64'; do
	if bypass_has "$entry"; then
		ok "the router's own IPv6 is in the bypass list: $entry"
	else
		bad "the router's own IPv6 is missing from the bypass list: $entry"
	fi
done
for entry in 'fe80:0:0:0:0:0:0:0/64' '2001:db8:0:1:0:0:0:0/64'; do
	if bypass_has "$entry"; then
		bad "added an address the hook does not filter: $entry"
	else
		ok "not added (not a global address on the filtered interface): $entry"
	fi
done

sh "$WORK/accel" apply
check "a second apply adds nothing (the whole-line bug appended copies)" "10" "$(bypass_count)"
if grep -q "''" "$WORK/config/nikki-rs"; then
	bad "bypass config holds quote-wrapped values (uci set \"k='v'\" bug)"
else
	ok "the bypass list has no quote-wrapped values"
fi
check "check-bypass reports nothing missing once repaired" "" "$(sh "$WORK/accel" check-bypass)"

seed_ebpf 0
sh "$WORK/accel" apply
check "with eBPF disabled the list is left exactly as it was" "7" "$(bypass_count)"

printf '\n\033[1m== summary ==\033[0m\n  passed: %s\n  failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "  the first-boot scripts and the acceleration applier behave correctly under the real uci"
