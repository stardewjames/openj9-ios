#!/usr/bin/env bash
# Export the local edits in the upstream checkouts to patches/*.patch.
#
# Usage: scripts/export-patches.sh [<openjdk dir> [<openj9 dir> [<omr dir>]]]
# Defaults match the development layout: upstream/openjdk, upstream/openj9, upstream/omr.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENJDK_DIR="${1:-$ROOT/upstream/openjdk}"
OPENJ9_DIR="${2:-$ROOT/upstream/openj9}"
OMR_DIR="${3:-$ROOT/upstream/omr}"

export_one() { # <dir> <name>
	local dir="$1" name="$2" out="$ROOT/patches/$2.patch"
	# Include new files; exclude nested openj9/omr checkouts inside the jdk tree.
	git -C "$dir" add -A -- . ':(exclude)openj9' ':(exclude)omr'
	git -C "$dir" diff --cached --binary --full-index > "$out"
	git -C "$dir" reset -q
	echo "==> $out ($(grep -c '^diff --git' "$out" || true) files)"
}

mkdir -p "$ROOT/patches"
export_one "$OPENJDK_DIR" openjdk
export_one "$OPENJ9_DIR" openj9
export_one "$OMR_DIR" omr
