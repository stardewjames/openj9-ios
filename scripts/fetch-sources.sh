#!/usr/bin/env bash
# Fetch the pinned OpenJDK/OpenJ9/OMR sources and apply the iOS patches.
#
# Usage: scripts/fetch-sources.sh [<dest>]   (default: work/src/jdk)
# Layout produced: <dest> (openj9-openjdk-jdk21), <dest>/openj9, <dest>/omr
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../sources.env
source "$ROOT/sources.env"
DEST="${1:-$ROOT/work/src/jdk}"

checkout() { # <dir> <repo> <sha>
	local dir="$1" repo="$2" sha="$3"
	if [[ -d "$dir/.git" ]]; then
		if [[ "$(git -C "$dir" rev-parse HEAD)" != "$sha" ]]; then
			echo "error: $dir is not at pinned revision $sha; use a fresh destination" >&2
			exit 1
		fi
		echo "==> reusing $dir at $sha (preserving local changes)"
		return
	fi
	if [[ -e "$dir" ]]; then
		echo "error: destination already exists without a checkout: $dir" >&2
		exit 1
	fi
	mkdir -p "$dir"
	git -C "$dir" init -q
	git -C "$dir" config core.autocrlf false
	git -C "$dir" remote add origin "$repo"
	echo "==> fetching $repo @ $sha"
	git -C "$dir" fetch -q --depth 1 origin "$sha"
	git -C "$dir" checkout -q FETCH_HEAD
}

apply_patch() { # <dir> <patch>
	local dir="$1" patch="$2"
	if [[ -s "$patch" ]]; then
		if git -C "$dir" apply --reverse --check "$patch" 2>/dev/null; then
			echo "==> $(basename "$patch") already applied"
		else
			echo "==> applying $(basename "$patch") to $dir"
			git -C "$dir" apply --check "$patch"
			git -C "$dir" apply --whitespace=nowarn "$patch"
		fi
	fi
}

checkout "$DEST" "$OPENJDK_REPO" "$OPENJDK_SHA"
checkout "$DEST/openj9" "$OPENJ9_REPO" "$OPENJ9_SHA"
checkout "$DEST/omr" "$OMR_REPO" "$OMR_SHA"

apply_patch "$DEST" "$ROOT/patches/openjdk.patch"
apply_patch "$DEST/openj9" "$ROOT/patches/openj9.patch"
apply_patch "$DEST/omr" "$ROOT/patches/omr.patch"

# git apply does not restore modes for new files created without a mode line on all versions.
find "$DEST" -path '*/.git' -prune -o -name '*.sh' -type f -exec chmod +x {} +

echo "==> sources ready in $DEST"
