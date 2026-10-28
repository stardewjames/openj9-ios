#!/usr/bin/env bash
# Cross-compile OpenJDK 21 + OpenJ9 for iOS on an arm64 macOS host.
#
# Usage: scripts/build-jdk.sh <iphoneos|iphonesimulator> [--disable-java-desktop] [--src <jdk dir>] [--configure-only] [-- <extra make targets>]
# Requires: Xcode (iOS SDKs), autoconf, cmake, bash, make (GNU make 3.81+), optional ccache.
# Produces: <jdk dir>/build/ios-<sdk>[-core]/images/jmods
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../sources.env
source "$ROOT/sources.env"

usage() { echo "usage: $0 <iphoneos|iphonesimulator> [--disable-java-desktop] [--src <jdk dir>] [--configure-only] [-- make targets...]" >&2; exit 2; }

SDK="${1:-}"; shift || true
case "$SDK" in iphoneos|iphonesimulator) ;; *) usage ;; esac

SRC="$ROOT/work/src/jdk"
CONFIGURE_ONLY=0
JAVA_DESKTOP=true
MAKE_TARGETS=(jdk-image)
while [[ $# -gt 0 ]]; do
	case "$1" in
		--src) SRC="$(cd "$2" && pwd)"; shift 2 ;;
		--configure-only) CONFIGURE_ONLY=1; shift ;;
		--disable-java-desktop) JAVA_DESKTOP=false; shift ;;
		--) shift; MAKE_TARGETS=("$@"); break ;;
		*) usage ;;
	esac
done

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "error: needs an arm64 macOS host" >&2; exit 1; }

# Boot/build JDK: matching Semeru release.
JDK_DIR="$ROOT/work/semeru"
SEMERU_HOME="$JDK_DIR/home"
if [[ ! -x "$SEMERU_HOME/bin/java" ]]; then
	mkdir -p "$JDK_DIR"
	archive="$JDK_DIR/semeru.tar.gz"
	echo "==> downloading $SEMERU_JDK_URL"
	curl -fsSL --retry 3 -o "$archive" "$SEMERU_JDK_URL"
	expected="$(curl -fsSL --retry 3 "$SEMERU_JDK_SHA256_URL" | awk '{print $1}')"
	actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
	[[ "$expected" == "$actual" ]] || { echo "error: sha256 mismatch for Semeru JDK" >&2; exit 1; }
	rm -rf "$JDK_DIR/extract" && mkdir -p "$JDK_DIR/extract"
	tar -xzf "$archive" -C "$JDK_DIR/extract"
	home="$(find "$JDK_DIR/extract" -maxdepth 6 -type f -path '*/bin/java' -print -quit)"
	[[ -n "$home" ]] || { echo "error: downloaded archive contains no JDK bin/java" >&2; exit 1; }
	rm -rf "$SEMERU_HOME"
	mv "$(dirname "$(dirname "$home")")" "$SEMERU_HOME"
	rm -f "$archive"
fi
"$SEMERU_HOME/bin/java" -version

CONF="ios-$SDK"
[[ "$JAVA_DESKTOP" == true ]] || CONF="$CONF-core"
CONFIGURE_ARGS=(
	--openjdk-target=aarch64-apple-ios
	--with-sdk-name="$SDK"
	--with-ios-version-min="$IOS_VERSION_MIN"
	--with-conf-name="$CONF"
	--with-boot-jdk="$SEMERU_HOME"
	--with-build-jdk="$SEMERU_HOME"
	--with-noncompressedrefs
	--disable-ddr
	--without-macosx-codesign
	--with-native-debug-symbols=none
	--disable-warnings-as-errors
	--disable-warnings-as-errors-omr
	--disable-warnings-as-errors-openj9
	--with-extra-ldflags=-Wl,-headerpad_max_install_names
	--with-vendor-name="OpenJ9 for iOS"
	--with-version-pre=
	--with-version-opt=ios
)
[[ "$JAVA_DESKTOP" == true ]] || CONFIGURE_ARGS+=(--disable-java-desktop)
if command -v ccache >/dev/null 2>&1; then
	CONFIGURE_ARGS+=(--enable-ccache)
fi

cd "$SRC"
if [[ ! -f "build/$CONF/spec.gmk" ]] || [[ "$CONFIGURE_ONLY" == 1 ]] || [[ configure -nt "build/$CONF/spec.gmk" ]]; then
	echo "==> configure ${CONFIGURE_ARGS[*]}"
	if ! bash configure "${CONFIGURE_ARGS[@]}"; then
		echo "==> configure failed; tail of config.log:" >&2
		tail -n 200 "build/$CONF/config.log" >&2 || true
		exit 1
	fi
fi
[[ "$CONFIGURE_ONLY" == 1 ]] && exit 0

JOBS="$(sysctl -n hw.ncpu)"
echo "==> make ${MAKE_TARGETS[*]} (JOBS=$JOBS)"
make CONF="$CONF" JOBS="$JOBS" LOG=warn "${MAKE_TARGETS[@]}"

echo "==> jmods: $SRC/build/$CONF/images/jmods"
ls "$SRC/build/$CONF/images/jmods"
