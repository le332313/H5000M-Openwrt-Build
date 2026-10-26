#!/usr/bin/env bash
#
# verify-apk-repo.sh — check a package repository the way a device checks it.
#
# Why this exists: "the package is in the repository" and "the package can be
# installed" are different claims, and the gap between them has already shipped
# two broken firmwares.  `luci-app-ssr-plus` resolved cleanly while declaring no
# core at all, so `apk add luci-app-ssr-plus` produced a panel that answered
#
#   Main node:Xray 和 Mihomo 内核均不存在，无法启动。
#
# and the pinned sing-box was silently replaced by the official snapshot's newer
# one.  Neither is visible in a `.config`, a package count, or an exit code — both
# need a real apk solver asking a real index.
#
# A third gap turned up on a real device: a package can be in the repository, can
# install cleanly, and still not satisfy whatever asked for it.  adblock-fast
# clears its "gawk, grep, sed, coreutils-sort are missing" warning by probing four
# FIXED GNU paths, so "the four are in the source" only helps if they install to
# exactly those paths — busybox's own grep/sed/sort sit elsewhere and never count.
# A presence check cannot see that difference, so the install check below does the
# install and looks at the paths.
#
# This script builds a throw-away apk database, points it at one repository, and
# asks the same questions the device's apk asks.  With --with-official-feeds it
# also configures the snapshot sources a firmware ships with, which is how the
# version-shadowing is reproduced.
#
# Usage:
#   scripts/verify-apk-repo.sh                      # artifacts/apk-repo/ if built
#   scripts/verify-apk-repo.sh <url-or-path>        # a published repository
#   scripts/verify-apk-repo.sh --with-official-feeds [url-or-path]
#
# Exit status: 0 when every check passes, 1 otherwise.
#
# The CI step "Verify the built repository can satisfy every frontend on its own"
# makes the same assertions against the index before it is published; keep the
# two in step when the package set changes.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT_DIR}/openwrt"
ARCH="${APK_ARCH:-aarch64_cortex-a53}"

WITH_FEEDS=false
TARGET=""
for arg in "$@"; do
	case "$arg" in
		--with-official-feeds) WITH_FEEDS=true ;;
		-h | --help)
			sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*) TARGET="$arg" ;;
	esac
done

# The apk this tree built speaks the same index format the firmware does, so it
# is the only tool that answers the question exactly.  A system apk of a
# different major version reads a different format and would give a false answer.
if [ -x "${SRC}/staging_dir/host/bin/apk" ]; then
	APK="${SRC}/staging_dir/host/bin/apk"
elif command -v apk >/dev/null 2>&1; then
	APK="$(command -v apk)"
	echo "warning: using $(command -v apk); the version this tree builds is preferred" >&2
else
	echo "error: no apk tool found.  Build once (scripts/local-build.sh) so that" >&2
	echo "       openwrt/staging_dir/host/bin/apk exists, or install apk-tools." >&2
	exit 1
fi

if [ -z "$TARGET" ]; then
	# The built repository is laid out one directory per kernel ABI, so the
	# index is not at a fixed path.  Prefer a caller-supplied ABI, then the one
	# BUILD-INFO.txt records for this build, then the newest directory — taking
	# "newest" only as a last resort, because a stale ABI directory from an
	# earlier build must not shadow the one just produced.
	REPO_DIR="${ROOT_DIR}/artifacts/apk-repo"
	ABI="${H5000M_KERNEL_ABI:-}"
	if [ -z "$ABI" ] && [ -f "${ROOT_DIR}/artifacts/BUILD-INFO.txt" ]; then
		ABI="$(sed -n 's/^kernel_abi=//p' "${ROOT_DIR}/artifacts/BUILD-INFO.txt" | head -n1)"
	fi
	if [ -z "$ABI" ] && [ -d "$REPO_DIR" ]; then
		# `-newer $REPO_DIR/public-key.pem` would be nicer, but the key is only
		# written when one exists; newest-first on the index itself is enough
		# to pick the build that just ran.
		ABI="$(find "$REPO_DIR" -mindepth 1 -maxdepth 1 -type d ! -name firmware 2>/dev/null |
			while read -r d; do
				[ -f "${d}/packages.adb" ] && printf '%s\n' "$d"
			done |
			xargs -r ls -dt 2>/dev/null | head -n1 | xargs -r basename)"
	fi

	if [ -n "$ABI" ] && [ -s "${REPO_DIR}/${ABI}/packages.adb" ]; then
		TARGET="${REPO_DIR}/${ABI}/packages.adb"
	elif [ -s "${REPO_DIR}/packages.adb" ]; then
		# The flat layout: an older build, or a build that could not determine
		# its own ABI.  Reading it is still useful — it is what devices flashed
		# from that build actually use.
		TARGET="${REPO_DIR}/packages.adb"
		echo "note: no per-ABI index found; checking the flat legacy repository" >&2
	else
		TARGET="https://existyay.github.io/AutoBuild-H5000M-Openwrt/packages.adb"
		echo "note: no local build found; checking the published repository" >&2
	fi
fi

# ------------------------------------------------ what has to be installable ---
#
# Front-ends a user may `apk add`.  The LuCI app AND its Chinese translation,
# because upstream ships the translation separately and nothing pulls it in.
FRONTENDS=(
	luci-app-passwall luci-app-passwall2 luci-app-ssr-plus luci-app-homeproxy
	luci-app-nikki-rs luci-app-momo luci-app-openclash luci-app-mosdns
	luci-app-nekobox luci-app-xray luci-app-hijpass luci-app-fchomo
	luci-app-v2raya luci-app-adblock luci-app-adblock-fast
)

# The Chinese translation for every front-end above that ships one: upstream
# publishes translations as their own package and nothing pulls them in, so the
# promise "本体 + luci + 中文翻译" has to be asserted, not assumed.  The names
# are fixed feed package names — NOT luci.mk-generated ones, which rename with
# LuCI's language suffix (easymesh ships luci-i18n-easymesh-zh_Hans), which is
# why the build treats the generated ones as warnings instead.  openclash,
# nekobox and xray carry no separate translation upstream (verified against the
# published index), so they are absent from this list on purpose.
TRANSLATIONS=(
	luci-i18n-passwall-zh-cn luci-i18n-passwall2-zh-cn
	luci-i18n-ssr-plus-zh-cn luci-i18n-homeproxy-zh-cn
	luci-i18n-nikki-rs-zh-cn luci-i18n-momo-zh-cn
	luci-i18n-mosdns-zh-cn luci-i18n-hijpass-zh-cn
	luci-i18n-fchomo-zh-cn luci-i18n-v2raya-zh-cn
	luci-i18n-adblock-zh-cn luci-i18n-adblock-fast-zh-cn
)

# Cores and daemons: a front-end without one of these installs and then cannot
# start a node.
DAEMONS=(
	xray-core mihomo sing-box mosdns nikki-rs clash-rs momo adblock adblock-fast
	dns2tcp ip-full ucode-mod-math
)

# adblock / adblock-fast hand a blocklist to a DNS server.  dnsmasq-full is the
# variant with ipset and nftset compiled in; `nftables-json` (already in KMODS'
# userspace half) supplies the `nft` tool nftset needs; `ipset` is the userspace
# tool the ipset backend probes.  The four GNU tools are adblock-fast's
# *recommended* packages — it warns when they are absent even though busybox
# provides awk/grep/sed/sort — so the repository has to carry them for the
# warning's own `apk add` suggestion to work.
DNS_BACKENDS=(dnsmasq-full ipset)
ADBLOCK_TOOLS=(gawk grep sed coreutils-sort)

# Package -> the paths adblock-fast probes for it, copied from
# `_check_recommended_packages()` in feeds/packages/net/adblock-fast/files/lib/
# adblock-fast/adblock-fast.uc.  It looks gawk up by name (either bin directory
# counts) but asks for absolute paths for the other three, and those paths exist
# only in the GNU packages.  That is why the four are in the repository at all.
declare -A ADBLOCK_TOOL_PATHS=(
	[gawk]="usr/bin/gawk usr/sbin/gawk"
	[grep]="usr/libexec/grep-gnu"
	[sed]="usr/libexec/sed-gnu"
	[coreutils-sort]="usr/libexec/sort-coreutils"
)

# Kernel modules the proxy stack redirects traffic through.  They can only come
# from a repository built against this exact kernel: the official snapshot's
# modules carry a different vermagic, and their files disappear as the snapshot
# moves on.  kmod-ipt-ipset is what the ipset userspace tool drives.
KMODS=(
	kmod-tun kmod-inet-diag kmod-dummy kmod-nft-queue kmod-nfnetlink-queue
	kmod-nft-tproxy kmod-nft-socket kmod-nft-fullcone kmod-ipt-tproxy
	kmod-ipt-conntrack-extra kmod-ipt-filter kmod-netlink-diag
	kmod-nf-nathelper kmod-macvlan kmod-sched-core kmod-sched-bpf
	kmod-ifb kmod-tcp-bbr kmod-ipt-ipset kmod-veth
)

# Package -> the core it must resolve.  The whole point: the core has to be part
# of the dependency resolution, not merely present in the repository.
declare -A REQUIRED_CORES=(
	[luci-app-ssr-plus]="xray-core mihomo"
	[luci-app-passwall]="xray-core sing-box"
	[luci-app-passwall2]="xray-core sing-box"
	[luci-app-homeproxy]="sing-box"
	[luci-app-nikki-rs]="nikki-rs clash-rs"
	[luci-app-momo]="momo"
	[luci-app-adblock-fast]="adblock-fast"
)

# This project's only version pin, and the reason it has to be in the image.
PINNED_PACKAGE=sing-box
PINNED_VERSION=1.12.25-r1

OFFICIAL_FEEDS=(
	"https://downloads.openwrt.org/snapshots/targets/mediatek/filogic/packages/packages.adb"
	"https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/base/packages.adb"
	"https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/luci/packages.adb"
	"https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/packages/packages.adb"
	"https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/routing/packages.adb"
	"https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/telephony/packages.adb"
	"https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/video/packages.adb"
)

# --------------------------------------------------------------- apk harness ---

SCRATCH="$(mktemp -d)"
# A second, separate database for the install-and-look-at-the-paths check below.
# It installs packages, and doing that in $SCRATCH would change the installed set
# that the version-pin check above reasons about.
TOOLS_SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH" "$TOOLS_SCRATCH"' EXIT
mkdir -p "$SCRATCH/cache"

# --usermode: this runs as an ordinary user, not root.
if ! "$APK" --root "$SCRATCH" --arch "$ARCH" --allow-untrusted --initdb --usermode add >/dev/null 2>&1; then
	echo "error: could not create a scratch apk database in $SCRATCH" >&2
	exit 1
fi
{
	printf '%s\n' "$TARGET"
	[ "$WITH_FEEDS" = true ] && printf '%s\n' "${OFFICIAL_FEEDS[@]}"
} >"$SCRATCH/etc/apk/repositories"

apk_() { "$APK" --root "$SCRATCH" --arch "$ARCH" --allow-untrusted --cache-dir "$SCRATCH/cache" "$@"; }

if ! apk_ update >/dev/null 2>&1; then
	echo "error: this apk cannot read ${TARGET}" >&2
	exit 1
fi

FAILED=0
ok() { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad() {
	printf '  \033[31mFAIL\033[0m  %s\n' "$1"
	FAILED=$((FAILED + 1))
}

present() {
	if [ -n "$(apk_ list "$1" 2>/dev/null)" ]; then ok "$1"; else bad "$1 is not in the repository"; fi
}

echo "repository: ${TARGET}"
echo "apk:        ${APK}"
echo "feeds:      $([ "$WITH_FEEDS" = true ] && echo "this repository + the official snapshot sources" || echo "this repository only")"
echo "packages:   $(apk_ list 2>/dev/null | wc -l)"
echo

echo "=== the version pin (apk takes the highest version across every feed) ==="
# `apk list` prints one line per version on offer, so with the official feeds
# configured this is a list, not a single value.
offered="$(apk_ list "$PINNED_PACKAGE" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
offered="${offered% }"

if [ "$WITH_FEEDS" = true ]; then
	# A firmware built by this project ships the pinned version *installed*, and
	# apk keeps an installed package unless it is asked to upgrade.  So the
	# question is not "is it the only version on offer" (the snapshot always has
	# a newer one) but "does installing a front-end replace it".
	echo "  on offer: ${offered:-none}"
	apk_ policy "$PINNED_PACKAGE" 2>/dev/null | sed 's/^/  /'
	if apk_ add --simulate "${PINNED_PACKAGE}=${PINNED_VERSION}" >/dev/null 2>&1; then
		apk_ add "${PINNED_PACKAGE}=${PINNED_VERSION}" >/dev/null 2>&1
		# Capture first, then match — same `pipefail` + `grep -q` hazard as the
		# resolve loop below.  Here the false result would be an inverted one:
		# SIGPIPE would look like "sing-box was not reinstalled" and turn a real
		# replacement into a green OK.
		sim="$(apk_ add --simulate luci-app-homeproxy 2>&1)"
		if grep -q "Installing ${PINNED_PACKAGE} " <<<"$sim"; then
			bad "apk add luci-app-homeproxy would replace the installed ${PINNED_PACKAGE} ${PINNED_VERSION}"
		else
			ok "installed ${PINNED_PACKAGE} ${PINNED_VERSION} survives apk add (as on a flashed device)"
		fi
	else
		echo "  note: cannot fetch ${PINNED_PACKAGE} ${PINNED_VERSION} here, so the"
		echo "        install-and-survive check was skipped"
	fi
elif [ "$offered" = "${PINNED_PACKAGE}-${PINNED_VERSION}" ]; then
	ok "${PINNED_PACKAGE} is pinned to ${PINNED_VERSION}"
elif [ -z "$offered" ]; then
	bad "${PINNED_PACKAGE} is not in the repository"
else
	bad "${PINNED_PACKAGE} offers '${offered}', not ${PINNED_VERSION}"
fi
echo

echo "=== front-ends ==="
for p in "${FRONTENDS[@]}"; do present "$p"; done
echo

echo "=== Chinese translations ==="
for p in "${TRANSLATIONS[@]}"; do present "$p"; done
echo

echo "=== daemons and cores ==="
for p in "${DAEMONS[@]}"; do present "$p"; done
echo

echo "=== kernel modules ==="
for p in "${KMODS[@]}"; do present "$p"; done
echo

echo "=== adblock DNS backends and recommended tools ==="
for p in "${DNS_BACKENDS[@]}"; do present "$p"; done
for p in "${ADBLOCK_TOOLS[@]}"; do present "$p"; done
echo

# Being in the repository is not the claim that clears the warning — the paths
# are.  Install the four into their own database and look at what landed.
#
# `--scripts=no` because the post-install scripts are aarch64 binaries and this
# host is not: apk reports every one of them as "exited with error 127", which is
# a property of the verifying host, not of the repository.  The question here is
# which files the packages install, and that is answered without running them.
echo "=== adblock-fast's recommended tools land where it probes ==="
mkdir -p "$TOOLS_SCRATCH/cache"
if ! "$APK" --root "$TOOLS_SCRATCH" --arch "$ARCH" --allow-untrusted --initdb --usermode add >/dev/null 2>&1; then
	bad "could not create a scratch apk database for the install check"
else
	printf '%s\n' "$TARGET" >"$TOOLS_SCRATCH/etc/apk/repositories"
	if ! "$APK" --root "$TOOLS_SCRATCH" --arch "$ARCH" --allow-untrusted \
		--cache-dir "$TOOLS_SCRATCH/cache" --scripts=no add "${ADBLOCK_TOOLS[@]}" >/dev/null 2>&1; then
		bad "apk add ${ADBLOCK_TOOLS[*]} failed against this repository"
	else
		for pkg in "${ADBLOCK_TOOLS[@]}"; do
			hit=""
			for path in ${ADBLOCK_TOOL_PATHS[$pkg]}; do
				if [ -e "${TOOLS_SCRATCH}/${path}" ]; then
					hit="$path"
					break
				fi
			done
			if [ -n "$hit" ]; then
				ok "$pkg installs ${hit}, which is where adblock-fast looks"
			else
				bad "$pkg installs nothing at ${ADBLOCK_TOOL_PATHS[$pkg]} — the panel would keep warning after following its own advice"
			fi
		done
	fi
fi
echo

# `apk list <missing>` exits 0 with no output, and `apk query --recursive` exits 0
# with its complaint on stderr, so neither the status nor stdout alone would do.
echo "=== dependency resolution, exactly as the device does it ==="
resolve() {
	local pkg="$1" err out
	err="$(apk_ query --recursive "$pkg" 2>&1 >/dev/null)"
	out="$(apk_ query --recursive "$pkg" 2>/dev/null)"
	if [ -n "$err" ]; then
		bad "$pkg does not resolve: $(printf '%s' "$err" | head -2 | tr '\n' ' ')"
		return 1
	fi
	[ -n "$out" ] || {
		bad "$pkg resolved to nothing"
		return 1
	}
	return 0
}
for p in "${!REQUIRED_CORES[@]}"; do
	resolve "$p" || continue
	# Resolve once, then match against the captured text.
	#
	# Do NOT write this as `printf ... | grep -q`: the script runs under
	# `set -o pipefail`, and `grep -q` exits at the FIRST match.  That closes the
	# pipe while printf is still writing, printf dies of SIGPIPE (141), and
	# pipefail makes the *pipeline* report failure — so a dependency that WAS
	# found is reported as missing.  It only bites on a large dependency set,
	# which is why `luci-app-nikki-rs` (58 dependencies, the biggest here)
	# reported `does not pull: clash-rs` while the package was in fact resolved.
	# A here-string is a temp file, so no writer can receive SIGPIPE.
	rec="$(apk_ query --recursive "$p" 2>/dev/null)"
	missing=""
	for core in ${REQUIRED_CORES[$p]}; do
		grep -qx "Name: ${core}" <<<"$rec" || missing="${missing} ${core}"
	done
	if [ -z "$missing" ]; then
		ok "$p pulls ${REQUIRED_CORES[$p]}"
	else
		bad "$p does not pull:${missing}"
	fi
done
echo

echo "=== what a user's first command looks like ==="
for p in luci-app-ssr-plus luci-app-passwall luci-app-homeproxy; do
	echo "  --- apk add ${p} ---"
	apk_ add --simulate "$p" 2>&1 |
		grep -E "Installing (xray-core|mihomo|sing-box|mosdns|kmod-tun|ip-full|ucode-mod-math)|ERROR" |
		sed 's/^/    /' || true
done
echo

if [ "$FAILED" -ne 0 ]; then
	echo "${FAILED} check(s) failed — this repository would not install cleanly on a device."
	exit 1
fi
echo "All checks passed: this repository satisfies the proxy stack on its own."
