#!/usr/bin/env bash
# Build the local-package sample and run it on a disposable arm64 iOS simulator.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/build/smoke-simulator"
TIMEOUT=600
usage() {
    echo "Usage: $(basename "$0") [--out <log-and-build-dir>] [--timeout <seconds>]"
    echo "Requires Xcode, XcodeGen, python3 and a host JDK 21 (HOST_JAVA_HOME or JAVA_HOME)."
    echo "First populate Artifacts/XCFrameworks and regenerate the local Package.swift."
}
die() { echo "smoke-test-simulator.sh: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --out|--timeout)
            [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
            if [[ "$1" == --out ]]; then OUT=$2; else TIMEOUT=$2; fi
            shift 2 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive integer"
for tool in xcrun xcodebuild xcodegen python3; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
[[ "$(uname -m)" == arm64 ]] || die "arm64 simulator frameworks require an Apple Silicon host"
[[ -d "$ROOT/Artifacts/XCFrameworks/jvm.xcframework" ]] || die "missing local XCFrameworks; run make-xcframeworks.sh and generate-package.sh first"
export HOST_JAVA_HOME="${HOST_JAVA_HOME:-${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}}"
[[ -x "$HOST_JAVA_HOME/bin/javac" ]] || die "no host javac at $HOST_JAVA_HOME/bin/javac"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
LOG="$OUT/console.log"
BUILD_LOG="$OUT/build.log"
BUNDLE_ID=org.openj9.ios.HelloJava
UDID=""
SUCCESS=0
touch "$OUT/started"
: >"$LOG"
cleanup() {
    status=$?
    trap - EXIT
    if [[ -n "$UDID" ]]; then
        xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
        xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
    fi
    if [[ "$SUCCESS" != 1 ]]; then
        echo "=== Last 200 build/console lines ===" >&2
        [[ ! -f "$BUILD_LOG" ]] || tail -n 200 "$BUILD_LOG" >&2
        tail -n 200 "$LOG" >&2
        echo "=== HelloJava crash reports from this run ===" >&2
        if [[ -d "$HOME/Library/Logs/DiagnosticReports" ]]; then
            while IFS= read -r -d '' report; do
                echo "=== $report ===" >&2
                cat "$report" >&2
            done < <(find "$HOME/Library/Logs/DiagnosticReports" -type f -name 'HelloJava*' -newer "$OUT/started" -print0)
        fi
        [[ $status -ne 0 ]] || status=1
    fi
    exit "$status"
}
trap cleanup EXIT

xcodegen generate --spec "$ROOT/Samples/HelloJava/project.yml" --project "$ROOT/Samples/HelloJava"
xcodebuild -project "$ROOT/Samples/HelloJava/HelloJava.xcodeproj" -scheme HelloJava \
    -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$OUT/DerivedData" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES 'CODE_SIGN_IDENTITY=-' build 2>&1 | tee "$BUILD_LOG"

xcrun simctl list --json >"$OUT/simulators.json"
SELECTION=$(python3 - "$OUT/simulators.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    data = json.load(stream)
runtimes = [r for r in data['runtimes'] if r.get('isAvailable') and r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')]
if not runtimes:
    sys.exit('No available iOS simulator runtime; install one in Xcode Settings > Platforms.')
runtime = max(runtimes, key=lambda r: tuple(int(n) for n in r['version'].split('.')))
# Device types report runtime compatibility numerically, not as dotted version strings.
parts = [int(n) for n in runtime['version'].split('.')]
version = (parts[0] << 16) | ((parts[1] if len(parts) > 1 else 0) << 8) | (parts[2] if len(parts) > 2 else 0)
phones = [d for d in data['devicetypes'] if d['name'].startswith('iPhone') and d.get('minRuntimeVersion', 0) <= version <= d.get('maxRuntimeVersion', 0xffffffff)]
if not phones:
    sys.exit('No compatible iPhone simulator device type.')
print(runtime['identifier'])
print(phones[-1]['identifier'])
PY
)
RUNTIME=$(printf '%s\n' "$SELECTION" | sed -n '1p')
DEVICE_TYPE=$(printf '%s\n' "$SELECTION" | sed -n '2p')
UDID=$(xcrun simctl create "OpenJ9Smoke-$$" "$DEVICE_TYPE" "$RUNTIME")
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
APP="$OUT/DerivedData/Build/Products/Debug-iphonesimulator/HelloJava.app"
[[ -d "$APP" ]] || die "sample app not built: $APP"
xcrun simctl install "$UDID" "$APP"

# Python supplies a real deadline on stock macOS (which has no GNU timeout).
SIMCTL_CHILD_OPENJ9_SMOKE_EXIT=1 python3 - "$TIMEOUT" "$UDID" "$BUNDLE_ID" <<'PY' 2>&1 | tee "$LOG"
import os, signal, subprocess, sys
process = subprocess.Popen(['xcrun', 'simctl', 'launch', '--console-pty', '--terminate-running-process', sys.argv[2], sys.argv[3]], start_new_session=True)
try:
    sys.exit(process.wait(timeout=int(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    print('OPENJ9_IOS_SMOKE_FAIL: simulator launch timed out', flush=True)
    sys.exit(124)
PY
grep -q '^OPENJ9_IOS_SMOKE_OK' "$LOG" || die "success marker missing (see $LOG)"
if grep -q 'OPENJ9_IOS_SMOKE_FAIL:' "$LOG"; then die "failure marker found (see $LOG)"; fi
SUCCESS=1
echo "OpenJ9 iOS simulator smoke passed; logs: $OUT"
