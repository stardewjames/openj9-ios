# Benchmark sample

A throwaway iOS app for comparing JVM implementations on the same device or
Simulator: **OpenJ9 for iOS** versus **HotSpot Zero for iOS**. It measures 25
workloads and runs 28 compatibility probes, then prints one line per result so
two runs can be diffed.

Everything lives in this folder. Nothing in `Sources/OpenJ9Kit`, `Package.swift`
or `scripts/` knows about it, so deleting `Benchmark/` removes it completely.

## Run it

```sh
# OpenJ9: needs the built runtime frameworks (see the repository README).
Benchmark/run.sh openj9 --mode all

# HotSpot Zero: point it at a packaged Zero runtime first.
Benchmark/make-zero-xcconfig.sh /path/to/packaged-zero-runtime
Benchmark/run.sh zero --mode all
```

`run.sh` builds the app, boots a disposable arm64 Simulator, streams the app's
console, and prints the result lines. `--mode bench` skips compatibility probes,
`--mode compat` skips timings. Logs land in `Benchmark/build/simulator-<runtime>/`.
The runner sets `BENCH_AUTORUN=1`, which makes the app start the requested mode
on launch and exit when it finishes.

Launched normally, the app is interactive. It shows a **Test** menu (all,
benchmarks, compatibility, idle, Suwayomi stress, Suwayomi idle), a **Run**
button, the live output, **Clear** and **Export / upload**. The JVM is created on
the first Run and reused by later benchmark runs; a Suwayomi server can only be
started once per app launch, so terminate and relaunch the app for a fresh
server run. Keep the app in the foreground while a run is active.

**Export / upload** writes one `ios-bench-<runtime>-<mode>-<timestamp>.txt`
report and opens the system share sheet (Files, AirDrop, Mail, any installed
upload target). The report contains the console, run metadata, device and OS
details, app build information, bundled artifact paths and sizes, the selected
`BENCH_*`/`SUWAYOMI_*` values, any JVM `hs_err_*.log` crash logs, and the names
and sizes of any javacore/Snap/core dump files in the app's temporary directory.
It does not include the full process environment. Exporting before a run still
works and captures the current debug state; review the report header before
uploading.

To run on a device, open `Benchmark/project.yml` with XcodeGen
(`xcodegen generate`), sign with your normal team, install the app, and tap Run.
Build-time knobs (`SUWAYOMI_JAR`) and launch-time knobs (`BENCH_WARMUP`,
`BENCH_REPS`, `BENCH_DURATION`, ...) are read when the app creates the JVM on the
first Run, so set them in the scheme's Run action (or with `simctl`) before
launching.

Full CI runs compile `BenchOpenJ9` for the arm64 iOS Simulator using the
headless SDK artifact produced by the packaging job, Java 21 and XcodeGen.
The resulting app is uploaded as `Benchmark-sample`. CI does not launch the
benchmark or build `BenchZero`, which requires a separately packaged Zero
runtime. Configure-only runs skip the app build.

See [Suwayomi benchmarks](SUWAYOMI.md) for the stress and idle scenarios.

## Output

```
BENCH_RUNTIME name=openj9 mode=all jar=... javaHome=...
BENCH_HOST vm=Eclipse OpenJ9 VM version=21.0.13.0.3 os=iOS arch=aarch64 cpus=3 heap=... 
COMPAT records OK ok Point[x=1, y=2]
BENCH integerMix 52.446 49.134 70.089 batch=200 ops=10000 checksum=-461833591042464543
BENCH_OK
```

- `COMPAT <name> <OK|SKIP|FAIL> <detail>` — `SKIP` means the API/module is
  absent (for example `java.desktop` in a core-only runtime), `FAIL` means the
  runtime has it but misbehaves.
- `BENCH <name> <median ns/op> <min> <max> batch ops warmupMs checksum` — lower
  is better; `checksum` proves both runtimes computed the same thing.

Harness knobs (environment, passed through `simctl` as `SIMCTL_CHILD_*`):
`BENCH_MODE` (initial or automatic mode), `BENCH_AUTORUN` (`1` starts and exits
without waiting for a tap), `BENCH_WARMUP` (ms, default 400), `BENCH_REPS`
(default 5).

## Two targets, one source tree

| Target | JVM source | Java home |
|---|---|---|
| `BenchOpenJ9` | `jvm.framework` from the OpenJ9 SwiftPM product | `Frameworks/jvm.framework/javahome` |
| `BenchZero` | static `libjvm.a` and natives linked into the app | `<bundle>/lib` |

The app itself only uses the JNI invocation API, so it stays VM-agnostic. A
binary cannot host both: Zero is linked statically and would collide with the
OpenJ9 `JNI_CreateJavaVM`, hence two targets.

`make-zero-xcconfig.sh` writes `zero.xcconfig` (the `-force_load` list and the
frameworks the archives need) and the `ZERO_RUNTIME` build setting that the
padding phase copies the jlinked image from. The committed `zero.xcconfig` is an
empty placeholder so project generation works before you have a Zero build.

## Caveats

- Both runtimes are interpreter-only on iOS, so ratios reflect interpreter
  quality, not JIT performance.
- Timings on a Simulator are noisy: compare medians from several runs, and use
  the same device type and host load for both runtimes.
- Zero support here is only as good as the Zero build you point it at. As of
  `openjdk/mobile` `c1ed06a`, the `iossimulator` slice needs at least two fixes
  to start at all: code heaps must be committed without `PROT_EXEC`, and
  `os_cpu/bsd_zero` needs real arm64 signal-context accessors.
