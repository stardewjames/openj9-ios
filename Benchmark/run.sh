#!/usr/bin/env bash
# Build a benchmark app and run it in a disposable iOS Simulator.
#
# Usage: run.sh <openj9|zero> [--mode bench|compat|all] [--out <dir>]
#               [--timeout <seconds>] [--device-type <name>] [--keep-device]
#
#   openj9  builds BenchOpenJ9; the OpenJ9 SwiftPM package must resolve, which
#           means Artifacts/XCFrameworks must exist (see the repository README).
#   zero    builds BenchZero; run make-zero-xcconfig.sh first.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WHICH=${1:-}
case "$WHICH" in
    openj9) SCHEME=BenchOpenJ9 ;;
    zero)   SCHEME=BenchZero ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "usage: $(basename "$0") <openj9|zero> [options]" >&2; exit 2 ;;
esac
shift || true

MODE=all
OUT="$HERE/build/simulator-$WHICH"
TIMEOUT=900
DEVICE_TYPE=""
KEEP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode|--out|--timeout|--device-type)
            [[ $# -ge 2 && -n "$2" ]] || { echo "$1 requires a value" >&2; exit 2; }
            case "$1" in
                --mode) MODE=$2 ;;
                --out) OUT=$2 ;;
                --timeout) TIMEOUT=$2 ;;
                --device-type) DEVICE_TYPE=$2 ;;
            esac
            shift 2 ;;
        --keep-device) KEEP=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
export BENCH_MODE="$MODE"

for tool in xcrun xcodebuild xcodegen python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "required tool not found: $tool" >&2; exit 1; }
done
[[ "$(uname -m)" == arm64 ]] || { echo "these are arm64 binaries; an Apple Silicon host is required" >&2; exit 1; }
export HOST_JAVA_HOME="${HOST_JAVA_HOME:-${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}}"

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
LOG="$OUT/console.log"
UDID=""

cleanup() {
    status=$?
    if [[ -n "$UDID" && "$KEEP" != 1 ]]; then
        xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
        xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT

xcodegen generate --spec "$HERE/project.yml" --project "$HERE" >/dev/null
xcodebuild -project "$HERE/Benchmark.xcodeproj" -scheme "$SCHEME" \
    -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$OUT/DerivedData" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    HOST_JAVA_HOME="$HOST_JAVA_HOME" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES 'CODE_SIGN_IDENTITY=-' build \
    2>&1 | tee "$OUT/build.log" | grep -E "error:|warning: .*Benchmark|BUILD (SUCCEEDED|FAILED)" || true
APP="$OUT/DerivedData/Build/Products/Debug-iphonesimulator/$SCHEME.app"
[[ -d "$APP" ]] || { echo "app was not built: $APP" >&2; exit 1; }

xcrun simctl list --json >"$OUT/simulators.json"
SELECTION=$(python3 - "$OUT/simulators.json" "$DEVICE_TYPE" <<'PY'
import json, sys
wanted = sys.argv[2]
with open(sys.argv[1]) as stream:
    data = json.load(stream)
runtimes = [r for r in data['runtimes']
            if r.get('isAvailable') and r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')]
if not runtimes:
    sys.exit('no available iOS simulator runtime')
runtime = max(runtimes, key=lambda r: tuple(int(n) for n in r['version'].split('.')))
parts = [int(n) for n in runtime['version'].split('.')]
version = (parts[0] << 16) | ((parts[1] if len(parts) > 1 else 0) << 8) | (parts[2] if len(parts) > 2 else 0)
phones = [d for d in data['devicetypes']
          if d['name'].startswith('iPhone') and d.get('minRuntimeVersion', 0) <= version <= d.get('maxRuntimeVersion', 0xffffffff)]
if wanted:
    phones = [d for d in phones if d['name'] == wanted] or [{'identifier': wanted}]
if not phones:
    sys.exit('no compatible iPhone simulator device type')
print(runtime['identifier'])
print(phones[-1]['identifier'])
PY
)
RUNTIME_ID=$(printf '%s\n' "$SELECTION" | sed -n '1p')
DEVICE_ID=$(printf '%s\n' "$SELECTION" | sed -n '2p')
UDID=$(xcrun simctl create "Bench-$SCHEME" "$DEVICE_ID" "$RUNTIME_ID")
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")

set +e
SIMCTL_CHILD_BENCH_MODE="$MODE" python3 - "$TIMEOUT" "$UDID" "$BUNDLE_ID" <<'PY' 2>&1 | tee "$LOG"
import os, signal, subprocess, sys
process = subprocess.Popen(['xcrun', 'simctl', 'launch', '--console-pty',
                            '--terminate-running-process', sys.argv[2], sys.argv[3]],
                           start_new_session=True)
try:
    sys.exit(process.wait(timeout=int(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    print('BENCH_APP_FAIL simulator launch timed out', flush=True)
    sys.exit(124)
PY
STATUS=${PIPESTATUS[0]}
set -e

if grep -q '^BENCH_APP_FAIL' "$LOG"; then
    echo "--- failures ---" >&2
    grep '^BENCH_APP_FAIL' "$LOG" >&2
    exit 1
fi
if ! grep -q '^BENCH_OK' "$LOG"; then
    echo "benchmark did not complete (status $STATUS); see $LOG" >&2
    tail -n 40 "$LOG" >&2
    exit 1
fi
echo "=== results ($SCHEME, mode $MODE) ==="
grep -E '^(BENCH_HOST|COMPAT|BENCH) ' "$LOG"
echo "log: $LOG"
