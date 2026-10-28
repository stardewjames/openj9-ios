#!/usr/bin/env bash
#
# make-xcframeworks.sh - combine the device and simulator frameworks produced by
# package-runtime.sh into one <stem>.xcframework per framework, plus a zip of
# each (for SwiftPM remote binary targets) and checksums.txt.
#
# checksums.txt uses the shasum format "<sha256>  <stem>.xcframework.zip"
# (the SwiftPM binary target checksum is the SHA-256 of the zip), so it can be
# verified with `shasum -a 256 -c checksums.txt` from the output directory.
#
# Requires macOS with Xcode (xcodebuild, ditto, swift).

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME --device <dir>/iphoneos/Frameworks --simulator <dir>/iphonesimulator/Frameworks --out <dir>

  --device     Directory containing the iphoneos *.framework bundles.
  --simulator  Directory containing the iphonesimulator *.framework bundles.
  --out        Output directory for *.xcframework, *.xcframework.zip and checksums.txt.
               Existing outputs with the same names are replaced.
EOF
}

die() {
	echo "$SCRIPT_NAME: error: $*" >&2
	exit 1
}

usage_error() {
	echo "$SCRIPT_NAME: $*" >&2
	usage >&2
	exit 2
}

log() {
	echo "==> $*"
}

DEVICE_DIR=""
SIM_DIR=""
OUT=""

while [[ $# -gt 0 ]]; do
	opt=$1
	case "$opt" in
	-h | --help)
		usage
		exit 0
		;;
	--device | --simulator | --out)
		[[ $# -ge 2 && -n "$2" ]] || usage_error "option $opt requires a value"
		val=$2
		shift 2
		;;
	--*=*)
		val=${opt#*=}
		opt=${opt%%=*}
		shift
		;;
	*)
		usage_error "unknown argument: $opt"
		;;
	esac
	case "$opt" in
	--device) DEVICE_DIR=$val ;;
	--simulator) SIM_DIR=$val ;;
	--out) OUT=$val ;;
	*) usage_error "unknown option: $opt" ;;
	esac
done

[[ -n "$DEVICE_DIR" ]] || usage_error "--device is required"
[[ -n "$SIM_DIR" ]] || usage_error "--simulator is required"
[[ -n "$OUT" ]] || usage_error "--out is required"
[[ -d "$DEVICE_DIR" ]] || die "device frameworks directory does not exist: $DEVICE_DIR"
[[ -d "$SIM_DIR" ]] || die "simulator frameworks directory does not exist: $SIM_DIR"

for tool in xcodebuild ditto swift; do
	command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool (this script must run on macOS with Xcode)"
done

DEVICE_DIR=$(cd "$DEVICE_DIR" && pwd)
SIM_DIR=$(cd "$SIM_DIR" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

list_stems() {
	local dir=$1 fw
	for fw in "$dir"/*.framework; do
		[[ -d "$fw" ]] || continue
		basename "$fw" .framework
	done | LC_ALL=C sort
}

DEVICE_STEMS=$(list_stems "$DEVICE_DIR")
SIM_STEMS=$(list_stems "$SIM_DIR")
[[ -n "$DEVICE_STEMS" ]] || die "no *.framework found in $DEVICE_DIR"
[[ -n "$SIM_STEMS" ]] || die "no *.framework found in $SIM_DIR"

if [[ "$DEVICE_STEMS" != "$SIM_STEMS" ]]; then
	echo "$SCRIPT_NAME: error: device and simulator framework sets differ:" >&2
	diff <(echo "$DEVICE_STEMS") <(echo "$SIM_STEMS") | sed -e 's/^</  device only:   /' -e 's/^>/  simulator only:/' | grep -E '^  ' >&2 || true
	exit 1
fi

# Use SwiftPM's archive checksum operation, exactly as consumers do.
compute_checksum() {
	local sum
	sum=$(cd "$OUT" && swift package compute-checksum "$1") || die "SwiftPM checksum failed for $1"
	[[ "$sum" =~ ^[0-9a-f]{64}$ ]] || die "invalid SwiftPM checksum for $1"
	echo "$sum"
}

# This directory holds generated outputs. Remove artifacts for libraries no longer
# present, otherwise generate-package.sh could accidentally publish stale targets.
for artifact in "$OUT"/*.xcframework "$OUT"/*.xcframework.zip; do
	[[ -e "$artifact" ]] || continue
	name=$(basename "$artifact")
	stem=${name%.zip}
	stem=${stem%.xcframework}
	if ! printf '%s\n' "$DEVICE_STEMS" | grep -Fxq "$stem"; then
		rm -rf "$artifact"
	fi
done

CHECKSUMS_TMP="$OUT/.checksums.txt.tmp"
: >"$CHECKSUMS_TMP"

for stem in $DEVICE_STEMS; do
	dev_fw="$DEVICE_DIR/$stem.framework"
	sim_fw="$SIM_DIR/$stem.framework"
	[[ -f "$dev_fw/$stem" ]] || die "missing binary $dev_fw/$stem"
	[[ -f "$sim_fw/$stem" ]] || die "missing binary $sim_fw/$stem"

	xcfw="$OUT/$stem.xcframework"
	zip="$OUT/$stem.xcframework.zip"
	rm -rf "$xcfw" "$zip"

	log "$stem.xcframework"
	xcodebuild -create-xcframework \
		-framework "$dev_fw" \
		-framework "$sim_fw" \
		-output "$xcfw" >/dev/null || die "xcodebuild -create-xcframework failed for $stem"

	(cd "$OUT" && ditto -c -k --keepParent "$stem.xcframework" "$stem.xcframework.zip") ||
		die "ditto failed for $stem"

	sum=$(compute_checksum "$zip") || die "checksum generation failed for $stem"
	printf '%s  %s\n' "$sum" "$stem.xcframework.zip" >>"$CHECKSUMS_TMP"
done

mv "$CHECKSUMS_TMP" "$OUT/checksums.txt"
log "wrote $(wc -l <"$OUT/checksums.txt" | tr -d ' ') xcframeworks and $OUT/checksums.txt"
