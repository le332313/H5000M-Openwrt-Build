#!/usr/bin/env bash
#
# serve-apk-repo.sh — serve artifacts/apk-repo/ over HTTP and print the exact
# build command that points a firmware at it.
#
# Why this exists: the package repository this project builds has to be reachable
# from the router for `apk add luci-app-passwall` to work.  There is no hosting
# until someone provides it, and shipping a URL that does not resolve makes
# `apk update` fail on every device — which is exactly the mistake an earlier
# revision of this project made.  Rather than guess a URL, this serves the
# directory from the build host and tells you what to build with.
#
# The device must be able to reach the host's address, so this is for a router on
# the same LAN as the build machine.  For anything permanent, host
# artifacts/apk-repo/ on any static server and pass its URL to
# H5000M_APK_REPO_URL instead — the repository is a directory per kernel ABI
# (<abi>/packages.adb plus the .apk files beside it), so any directory-serving
# host works.  The server document root is apk-repo/ itself: the ABI is part of
# the URL the firmware is built with, so serving from inside the ABI directory
# would produce links that only work for that one build.
#
# Usage:
#   scripts/serve-apk-repo.sh [port]      # default 8099
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${ROOT_DIR}/artifacts/apk-repo"
PORT="${1:-8099}"

# Which ABI's index to advertise.  Caller-supplied first, then what this build
# recorded, then the newest ABI directory present.
ABI="${H5000M_KERNEL_ABI:-}"
if [ -z "$ABI" ] && [ -f "${ROOT_DIR}/artifacts/BUILD-INFO.txt" ]; then
	ABI="$(sed -n 's/^kernel_abi=//p' "${ROOT_DIR}/artifacts/BUILD-INFO.txt" | head -n1)"
fi
if [ -z "$ABI" ]; then
	ABI="$(find "$REPO_DIR" -mindepth 1 -maxdepth 1 -type d ! -name firmware 2>/dev/null |
		while read -r d; do
			[ -f "${d}/packages.adb" ] && printf '%s\n' "$d"
		done |
		xargs -r ls -dt 2>/dev/null | head -n1 | xargs -r basename)"
fi

if [ -z "$ABI" ] || [ ! -f "${REPO_DIR}/${ABI}/packages.adb" ]; then
	if [ -f "${REPO_DIR}/packages.adb" ]; then
		ABI="" # flat legacy layout: the index sits at the root
	else
		echo "No repository under ${REPO_DIR} (looked for <abi>/packages.adb and packages.adb)" >&2
		echo "Build one first:  scripts/local-build.sh" >&2
		exit 2
	fi
fi
INDEX="${REPO_DIR}/${ABI:+${ABI}/}packages.adb"

# Prefer the address that is actually routable to the router.  A VPN or docker
# bridge address is the wrong answer, so ask the routing table which source
# address would be used to reach a public destination.
host_ip() {
	local ip
	ip="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
	[ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
	echo "${ip:-127.0.0.1}"
}

IP="$(host_ip)"
URL="http://${IP}:${PORT}"
IDX_REL="${ABI:+${ABI}/}packages.adb"
COUNT="$(find "$(dirname "$INDEX")" -maxdepth 1 -name '*.apk' | wc -l)"

cat <<EOF
Serving ${REPO_DIR}
  ${COUNT} packages + ${IDX_REL}

  Rebuild the firmware pointing at this host:

      H5000M_APK_REPO_URL=${URL} \\
      H5000M_KERNEL_ABI=${ABI:-<abi>} scripts/local-build.sh

  The ABI has to be passed as well, because the image consults it before
  anything is compiled — that is what puts ${IDX_REL} into the firmware.
  Omit it and the firmware falls back to ${URL}/packages.adb, which does not
  exist here.

  Or, on a device that is already flashed, add the line to the file OpenWrt
  reserves for extra sources and refresh:

      echo '${URL}/${IDX_REL}' >> /etc/apk/repositories.d/customfeeds.list
      apk update

  Check it is reachable before flashing:

      curl -sf ${URL}/${IDX_REL} | wc -c

Press Ctrl-C to stop.
EOF

cd "$REPO_DIR"
exec python3 -m http.server "$PORT" --bind 0.0.0.0
