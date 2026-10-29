#!/usr/bin/env bash
# Assemble a relocatable, ready-to-add local Swift package with its XCFrameworks.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# -ne 2 ]]; then
    echo "Usage: $(basename "$0") <xcframeworks-dir> <output.zip>" >&2
    exit 2
fi
FRAMEWORKS=$(cd "$1" && pwd)
mkdir -p "$(dirname "$2")"
OUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
SDK="$STAGE/OpenJ9"
mkdir -p "$SDK/Artifacts/XCFrameworks" "$SDK/Samples/HelloJava/java"

# Include source, notices, sample and rebuild inputs, but no working-tree caches
# or generated Xcode/Java build products.
cp -R "$ROOT/Sources" "$ROOT/docs" "$ROOT/scripts" "$ROOT/patches" "$SDK/"
cp "$ROOT/README.md" "$ROOT/sources.env" "$SDK/"
cp "$ROOT/Samples/HelloJava/project.yml" "$SDK/Samples/HelloJava/"
cp -R "$ROOT/Samples/HelloJava/Sources" "$SDK/Samples/HelloJava/"
cp -R "$ROOT/Samples/HelloJava/java/src" "$SDK/Samples/HelloJava/java/"
for framework in "$FRAMEWORKS"/*.xcframework; do
    [[ -d "$framework" ]] || continue
    cp -R "$framework" "$SDK/Artifacts/XCFrameworks/"
done
"$ROOT/scripts/generate-package.sh" --frameworks-dir "$FRAMEWORKS" --output "$SDK/Package.swift"

(cd "$STAGE" && ditto -c -k --keepParent OpenJ9 "$OUT")
(cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")" >"$(basename "$OUT").sha256")
echo "SwiftPM SDK: $OUT (unzip, then add OpenJ9 as a local package)"
