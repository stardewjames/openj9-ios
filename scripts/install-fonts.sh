#!/usr/bin/env bash
# Install the pinned DejaVu TrueType fonts and their notices into a Java home.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/sources.env"
[[ $# == 1 && -d "$1" ]] || { echo "usage: $0 <existing-java-home>" >&2; exit 2; }
JAVA_HOME_DIR="$(cd "$1" && pwd)"
CACHE="$ROOT/work/fonts"
ARCHIVE="$CACHE/dejavu-fonts-ttf-2.37.tar.bz2"
mkdir -p "$CACHE"
if [[ ! -f "$ARCHIVE" ]]; then
    curl -fsSL -o "$ARCHIVE" "$DEJAVU_URL"
fi
actual="$(shasum -a 256 "$ARCHIVE")"
[[ "${actual%% *}" == "$DEJAVU_SHA256" ]] || { echo "DejaVu checksum mismatch: $ARCHIVE" >&2; exit 1; }
EXTRACT="$(mktemp -d "$CACHE/extract.XXXXXX")"
trap 'rm -rf "$EXTRACT"' EXIT
tar -xjf "$ARCHIVE" -C "$EXTRACT"
FONT_ROOT="$EXTRACT/dejavu-fonts-ttf-2.37"
mkdir -p "$JAVA_HOME_DIR/lib/fonts" "$JAVA_HOME_DIR/legal/java.desktop/dejavu"
for family in DejaVuSans DejaVuSerif DejaVuSansMono; do
    if [[ "$family" == DejaVuSerif ]]; then italic=Italic; else italic=Oblique; fi
    for face in "$family" "$family-Bold" "$family-$italic" "$family-Bold$italic"; do
        cp "$FONT_ROOT/ttf/$face.ttf" "$JAVA_HOME_DIR/lib/fonts/"
    done
done
cp "$FONT_ROOT/LICENSE" "$FONT_ROOT/AUTHORS" "$JAVA_HOME_DIR/legal/java.desktop/dejavu/"
echo "Installed DejaVu 2.37 fonts and license notices in $JAVA_HOME_DIR"
