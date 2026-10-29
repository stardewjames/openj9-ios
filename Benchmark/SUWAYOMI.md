# Suwayomi and idle measurements

The existing `all`, `bench`, and `compat` modes are unchanged. Three additional
modes use the same embedded JVM:

* `idle`: leave the newly created JVM idle (no Suwayomi jar required).
* `suwayomi-idle`: start Suwayomi inside that JVM, verify its GraphQL API, then
  sample the running server without sending benchmark requests.
* `suwayomi`: start the same server and issue concurrent GraphQL category-list
  queries on loopback. This exercises Suwayomi's HTTP, GraphQL and database code,
  not a mock or a remote server. It does not install extensions or download manga.

## Prerequisites and simulator

Use the normal benchmark prerequisites in the adjacent README: macOS on Apple
Silicon, Xcode with an iOS simulator runtime, XcodeGen, JDK 21, Python 3, and the
packaged OpenJ9 iOS frameworks (or a configured Zero runtime). For the server
modes, download the **jar**, not an operating-system bundle, from the
[Suwayomi releases](https://github.com/Suwayomi/Suwayomi-Server/releases).
The driver targets the v2.4.2366 GraphQL schema and its `MainKt` entry point;
other versions may change these interfaces. Upstream documents Java 21 or newer.
Provide a trusted, locally downloaded release jar; it is copied into the app at
build time. Example (use the actual downloaded filename):

```sh
export SUWAYOMI_JAR="$HOME/Downloads/Suwayomi-Server-v2.4.2366.jar"
BENCH_DURATION=60 BENCH_SAMPLE_INTERVAL=5 Benchmark/run.sh openj9 --mode idle
BENCH_DURATION=60 BENCH_SAMPLE_INTERVAL=5 Benchmark/run.sh openj9 --mode suwayomi-idle --timeout 600
BENCH_DURATION=60 SUWAYOMI_CONCURRENCY=4 Benchmark/run.sh openj9 --mode suwayomi --timeout 600
# For a configured Zero runtime, replace openj9 with zero.
```

Set `BENCH_DURATION` in seconds (1–86400, default 60),
`BENCH_SAMPLE_INTERVAL` in seconds (1–3600, default 10),
`SUWAYOMI_CONCURRENCY` (1–64, default 4), `SUWAYOMI_PORT` (1–65535,
default 4567), and `SUWAYOMI_STARTUP_TIMEOUT` in seconds (1–3600, default
180). Choose a runner `--timeout` longer than startup plus measurement plus
request shutdown; defaults to 900 seconds. Invalid interval values fall back to
10; other invalid settings fail. A port already in use must be freed or changed.
The server stores its database and files under the app's temporary directory;
the disposable simulator created by the runner is deleted afterwards unless
`--keep-device` is supplied. Repeated device runs can retain that directory;
use a clean install to compare fresh databases.

For a signed physical device build, generate `Benchmark.xcodeproj` with
`xcodegen generate --spec Benchmark/project.yml --project Benchmark`, set
`SUWAYOMI_JAR` to the absolute jar path as a build setting, and select a signed
device. Set `BENCH_MODE` and the desired knobs as environment variables in the
scheme's Run action before launching from Xcode. Keep the app foregrounded and
the device unlocked throughout; iOS can suspend background work. No server is
exposed beyond loopback by the benchmark's server configuration.

## Results and interpretation

`SUWAYOMI_READY` reports startup including GraphQL readiness. The stress result
reports successful request count, elapsed wall time, throughput and p50/p95
latency in milliseconds; latency percentiles use a uniform reservoir of up to
100,000 completed requests. Any startup, timeout, HTTP or GraphQL error fails the
run instead of reporting a successful benchmark. Server logs may also be useful.

`IDLE_SAMPLE` records monotonic time, cumulative process CPU seconds, resident
bytes, physical footprint bytes, battery level (0–1), battery state, thermal
state and Low Power Mode. CPU deltas divided by wall-time deltas approximate
process CPU utilization (one fully used core is 1.0). RAM includes the whole app,
not just the Java heap. `IDLE_BATTERY` gives start/end levels and the decrease
in percentage points; negative values indicate an increase. Battery state values
are Apple's `UIDeviceBatteryState` (0 unknown, 1 unplugged, 2 charging, 3 full).
A value of -1 or `unavailable` means the OS did not provide a reading. Samples
are collected during stress too; they include client load.

Battery readings are coarse, system-wide, affected by charging and unrelated
processes, and typically unavailable in Simulator. Use long, repeated physical
device runs at matched brightness, charge, temperature and network conditions.
iOS public APIs do not provide per-process watts or energy in joules; CPU,
thermal/low-power state and battery change are proxies, **not** direct power
measurements. Use Xcode Instruments Energy Log or external power equipment for
energy/power measurements. Simulator results do not represent device power.

## Compatibility limitations

The jar is a desktop server distribution, not an iOS distribution. The server
requires Java modules and may rely on desktop APIs, native libraries, writable
paths, networking or unsupported platform detection. The iOS runtime is
interpreter-only and cannot load arbitrary desktop native binaries or run a
desktop browser/CEF; extensions and desktop UI are not supported by this test.
The bundle's runtime must include the Java modules the chosen jar needs. A
missing module, native dependency, port conflict, or unsupported API is reported
as a failure; successful startup on a particular runtime/device has not been
established by this documentation. Inspect the console and packaged runtime when
it fails. Upstream's [build dependencies](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.4.2366/server/build.gradle.kts)
and [server configuration](https://github.com/Suwayomi/Suwayomi-Server/wiki/Configuring-Suwayomi%E2%80%90Server)
describe the upstream distribution and settings.
