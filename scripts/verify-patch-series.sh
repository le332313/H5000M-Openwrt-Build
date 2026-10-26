#!/usr/bin/env bash
#
# Replay one package's upstream patch series against the real upstream tarball,
# with the drops in configs/upstream-patch-drops.conf applied.
#
# WHY THIS EXISTS
#
#   OpenWrt main landed two patches for the SAME lines of the SAME file twice in
#   one week -- libjson-c 002 on 2026-10-15 and its re-fix 010 on 2026-10-16,
#   with 002 never removed.  A tree carrying both cannot be built by anyone: the
#   second patch's context is gone, so its hunk fails at `prepare` and the build
#   dies after half an hour.  Our unpinned path -- the only path allowed to
#   advance the pin -- is exactly the path that has to build such a tree.
#
#   scripts/local-build.sh stops applying the redundant one (see
#   drop_superseded_upstream_patches).  This script is what proves the drop is
#   the right one, in about twenty seconds, on the real tarball, on both the
#   pinned revision and main:
#
#     * the surviving series applies cleanly          -> the drop is correct
#     * a rule whose guard has gone                  -> rule is inert, harmless
#     * a rule whose guard is present but broke      -> red here
#     * a second duplicate landing somewhere in the series -> red here too
#
#   It is deliberately NOT a comparison of patch files.  "These two patches both
#   remove line 435" is a text-level guess with false positives on any patch
#   pair that touches a blank line or a closing brace.  Whether the second patch
#   still applies is a fact about the source, and only `patch` knows it.
#
# USAGE
#
#   scripts/verify-patch-series.sh <tree dir> <label>
#
#   The tree only needs <pkg>/Makefile and <pkg>/patches/ for the packages named
#   in the config; it does not have to be a full checkout.  That is what makes
#   this testable without cloning OpenWrt.
#
set -euo pipefail

TREE=${1:-}
LABEL=${2:-tree}

if [ -z "$TREE" ] || [ ! -d "$TREE" ]; then
	echo "usage: $0 <tree dir> <label>" >&2
	exit 2
fi

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONF="$ROOT_DIR/configs/upstream-patch-drops.conf"
WORK=${PATCH_SERIES_WORK:-/tmp/patch-series}

fail() {
	echo "::error::[$LABEL] $*" >&2
	exit 1
}
note() { printf '  %s\n' "$*"; }

# Trim a config field, and strip a trailing CR, without starting a process.
# `x=$(printf '%s' "$x" | tr -d '\r' | sed ...)` is three spawns for a trim:
# free on a CI runner, about a second per field in the sandbox this is developed
# in, where a spawn costs roughly 250 ms.  `printf -v` is a builtin.
trim_into() { # <variable name> <value>
	local v="$2"
	v=${v%$'\r'}
	v="${v#"${v%%[![:space:]]*}"}"
	v="${v%"${v##*[![:space:]]}"}"
	printf -v "$1" '%s' "$v"
}

[ -f "$CONF" ] || {
	echo "no $CONF -- no patch series to replay"
	exit 0
}

# The rules, parsed once into an array.  Parsing lives here rather than in a
# helper called from inside a process substitution: a helper that spawns
# `tr`/`sed` per field turns a sixty-line config into hundreds of processes and
# minutes of wall clock, and the config is all comments.
# Element format: "<pkg>|<victim>|<guard>".
RULES=()
while IFS= read -r line || [ -n "$line" ]; do
	trim_into line "$line"
	case "$line" in
		'' | '#'*) continue ;;
	esac
	rpkg=${line%%|*}
	rest=${line#*|}
	rvictim=${rest%%|*}
	rguard=${rest#*|}
	rguard=${rguard%%|*}
	[ -n "$rpkg" ] && [ -n "$rvictim" ] && [ -n "$rguard" ] ||
		fail "malformed rule (want <pkg>|<victim>|<guard>): $line"
	RULES+=("${rpkg}|${rvictim}|${rguard}")
done <"$CONF"

if [ "${#RULES[@]}" -eq 0 ]; then
	echo "no drop rules configured -- nothing to replay"
	exit 0
fi

# Packages named by the rules, in first-seen order.
PKGS=()
for r in "${RULES[@]}"; do
	pkg=${r%%|*}
	known=""
	for p in "${PKGS[@]}"; do
		[ "$p" = "$pkg" ] && known=1
	done
	[ -n "$known" ] || PKGS+=("$pkg")
done

# Download and unpack the package's own source, exactly as OpenWrt would: the
# version and the URL come from the package Makefile, so an upstream bump moves
# this with it instead of needing an edit here.
fetch_source() { # <pkg dir> -> prints the unpacked source directory
	local pkg="$1" name ver url file cache dest
	mkdir -p "$WORK"
	name=$(sed -n 's/^PKG_NAME:=//p' "$TREE/$pkg/Makefile" | head -1)
	ver=$(sed -n 's/^PKG_VERSION:=//p' "$TREE/$pkg/Makefile" | head -1)
	url=$(sed -n 's/^PKG_SOURCE_URL:=//p' "$TREE/$pkg/Makefile" | head -1)
	file=$(sed -n 's/^PKG_SOURCE:=//p' "$TREE/$pkg/Makefile" | head -1)

	[ -n "$name" ] && [ -n "$ver" ] && [ -n "$url" ] && [ -n "$file" ] ||
		fail "$pkg/Makefile does not give PKG_NAME/PKG_VERSION/PKG_SOURCE_URL/PKG_SOURCE"

	url=${url//'$(PKG_NAME)'/$name}
	url=${url//'$(PKG_VERSION)'/$ver}
	file=${file//'$(PKG_NAME)'/$name}
	file=${file//'$(PKG_VERSION)'/$ver}

	# The tarball is cached; the unpacked tree is not, and nothing is ever
	# deleted.  Replaying a series modifies the tree, so a second run that
	# reused one would apply patch 001 on top of an already-patched
	# CMakeLists.txt and report "Reversed (or previously applied) patch
	# detected" -- a false red that blames the tree for a stale cache.  CI gets
	# a fresh /tmp per run and would never have shown it; it showed up the first
	# time this was pointed at a real OpenWrt checkout.  Extracting into a new
	# mktemp directory also means the script deletes nothing at all.
	cache="${WORK}/${name}-${ver}"
	mkdir -p "$cache"
	if [ ! -f "$cache/$file" ]; then
		curl -fsSL --retry 3 --max-time 180 -o "$cache/$file" "$url/$file" ||
			fail "cannot download $url/$file"
	fi
	dest=$(mktemp -d "${WORK}/extract-XXXXXX") ||
		fail "cannot create a scratch directory under $WORK"
	# The archive is named relatively and read with the working directory set to
	# the cache: GNU tar parses an archive argument containing a colon as
	# `host:file` and tries to reach that host, so an absolute Windows path
	# fails with "Cannot connect to C: resolve failed".  Only the archive name
	# is parsed that way -- `-C` takes a plain directory -- so this is the
	# portable shape.
	(cd "$cache" && tar -xf "$file" -C "$dest" --strip-components=1) ||
		fail "cannot unpack $file"
	printf '%s\n' "$dest"
}

# Apply one patch, choosing the strip level by dry run, so that a wrong level
# cannot leave a half-applied tree behind.
apply_patch() { # <patch file> <target dir> <name>
	local f="$1" d="$2" name="$3" lvl out first=""
	for lvl in 1 0; do
		if out=$(patch -p"$lvl" --batch --dry-run -d "$d" <"$f" 2>&1); then
			out=$(patch -p"$lvl" --batch -d "$d" <"$f" 2>&1) ||
				fail "$name failed to apply at -p$lvl: $out"
			# A hunk can also be *skipped* while patch still exits 0 -- a
			# target file that is not there, a patch that is already applied.
			# Both mean the series is not the one this tree expects.
			case "$out" in
				*FAILED* | *"can't find file"* | *"Reversed"* | *"Assume -R"*)
					fail "$name did not land cleanly at -p$lvl: $out" ;;
			esac
			return 0
		fi
		# Keep -p1's message: the failure has to say which hunk and which
		# line, or the next person has to reproduce the whole thing by hand.
		if [ "$lvl" = 1 ]; then
			first="$out"
		fi
	done
	fail "$name does not apply at -p1 or -p0: $(printf '%s' "$first" | tr '\n' ' ')"
}

for pkg in "${PKGS[@]}"; do
	dir="$TREE/$pkg/patches"
	if [ ! -d "$dir" ]; then
		echo "::warning::[$LABEL] $pkg/patches is not in this tree; rule not exercised here"
		continue
	fi

	# Which patches this tree drops.  Same guard condition as
	# drop_superseded_upstream_patches: both files have to be present.
	drops=" "
	for r in "${RULES[@]}"; do
		rpkg=${r%%|*}
		rest=${r#*|}
		rvictim=${rest%%|*}
		rguard=${rest#*|}
		[ "$rpkg" = "$pkg" ] || continue
		if [ ! -f "$dir/$rvictim" ]; then
			note "$pkg: $rvictim is not in this tree -- nothing to drop"
			continue
		fi
		if [ ! -f "$dir/$rguard" ]; then
			echo "::warning::[$LABEL] $pkg: guard $rguard is missing; the drop would not fire" >&2
			continue
		fi
		drops="$drops$rvictim "
		note "$pkg: dropping $rvictim (guard $rguard present)"
	done

	src=$(fetch_source "$pkg")
	echo "[$LABEL] $pkg: replaying the series onto $(basename "$src")"

	# Upstream applies a patches/ directory in name order.  Collect the names
	# first and sort them, so the replay order is the one that will be used --
	# the order is half the reason the second patch fails.
	patches=()
	for f in "$dir"/*.patch; do
		[ -f "$f" ] || continue
		patches+=("${f##*/}")
	done
	if [ "${#patches[@]}" -gt 0 ]; then
		mapfile -t patches < <(printf '%s\n' "${patches[@]}" | LC_ALL=C sort)
	fi

	n=0
	for name in "${patches[@]}"; do
		case "$drops" in
			*" $name "*) continue ;;
		esac
		apply_patch "$dir/$name" "$src" "$name"
		n=$((n + 1))
	done

	[ "$n" -gt 0 ] || fail "$pkg: no patch was applied at all -- the series is not what this test thinks it is"
	note "$pkg: $n patch(es) applied cleanly"
done

echo "[$LABEL] upstream patch series applies cleanly"
