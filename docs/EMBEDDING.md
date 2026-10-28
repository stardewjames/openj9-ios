# Embedding OpenJ9 Java 21 on iOS

This package embeds an interpreter-only OpenJ9 runtime in an iOS application. It targets arm64 iPhone/iPad devices and arm64 iOS simulators, iOS 15.0 or newer. It does not run on Intel simulators. Build and packaging require macOS with Xcode; the source checkout alone is not a runnable binary distribution.

## Prepare the Swift package

Build both runtime slices using the repository build instructions, then package their jmods with the **matching host macOS Semeru JDK 21**. `jlink` itself must be a host executable, not an iOS binary:

```sh
bash scripts/package-runtime.sh --sdk iphoneos \
  --jmods upstream/openjdk/build/ios-iphoneos/images/jmods \
  --jlink "$SEMERU_JDK/bin/jlink" --out Artifacts/Runtime --min-ios 15.0 --version 21.0.13
bash scripts/package-runtime.sh --sdk iphonesimulator \
  --jmods upstream/openjdk/build/ios-iphonesimulator/images/jmods \
  --jlink "$SEMERU_JDK/bin/jlink" --out Artifacts/Runtime --min-ios 15.0 --version 21.0.13
bash scripts/make-xcframeworks.sh \
  --device Artifacts/Runtime/iphoneos/Frameworks \
  --simulator Artifacts/Runtime/iphonesimulator/Frameworks --out Artifacts/XCFrameworks
bash scripts/generate-package.sh --frameworks-dir Artifacts/XCFrameworks
```

`--modules m1,m2,...` overrides the default jlink module set; missing modules are warned about and skipped. `java.base` and the real OpenJ9 `jvm` library must exist. The packager removes launcher executables, redirector JVMs, `jsig` and shared-class-cache support, and rejects unresolved load commands, wrong Mach-O platforms/architectures, or native code inside `javahome`. It rewrites libraries into sibling frameworks; `jvm.framework/javahome` contains the linked Java classes, configuration and data. Do not move that directory independently of its framework.

`Package.swift` is generated, including its initial expected framework list. CI regenerates it from actual build outputs: do not manually retain targets that the build does not emit. In Xcode, choose **File > Add Package Dependencies > Add Local**, select the repository, and add the **OpenJ9** product to the app target. Swift imports `OpenJ9Kit`; Objective-C imports `<OpenJ9Kit/OpenJ9Kit.h>`. SwiftPM carries all binary-framework dependencies. Inspect the resulting app to ensure **every** runtime framework is embedded and signed by Xcode, not merely linked. The packaging scripts neither strip nor sign the binaries. Use your normal device development/distribution signing configuration.

For a release, upload the generated individual `.xcframework.zip` archives, then generate remote binary targets:

```sh
bash scripts/generate-package.sh --frameworks-dir Artifacts/XCFrameworks \
  --remote-base-url https://example.org/releases/21.0.13 \
  --checksums Artifacts/XCFrameworks/checksums.txt
```

URLs must serve the archives without modification; checksums are archive checksums. Local manifests expect `Artifacts/XCFrameworks/<stem>.xcframework`. Do not publish a local-artifact manifest as though it were a self-contained remote package.

## Bundle Java code

Compile Java sources with a host JDK 21 (`javac --release 21`), package classes into a jar, and add the jar to the app's **Copy Bundle Resources**. Pass its absolute bundle path in `classPath`; paths are joined with `:`. Jars and native runtime resources in the signed app bundle are read-only. Put writable files in the sandbox's Documents, Library or temporary directories instead. App bundles containing downloaded or generated code need separate policy/security review; this library does not grant permission to download and execute arbitrary code.

## Swift usage

Start once, off the UI thread. Startup waits for `JNI_CreateJavaVM` on the kit's dedicated 16 MiB pthread. Main invocations and `performWithEnv` use that same thread, not a GCD queue whose underlying thread may change.

```swift
import Foundation
import OpenJ9Kit

// Keep your OpenJ9VM reference in the application/service that owns Java work.
DispatchQueue.global(qos: .userInitiated).async {
    let config = OpenJ9VMConfiguration()
    config.classPath = [Bundle.main.url(forResource: "HelloIOS", withExtension: "jar")!.path]
    config.maxHeap = "256m"
    config.outputHandler = { line, isError in
        DispatchQueue.main.async {
            // Update a text view / observable model here, without logging back to stdout.
            _ = (line, isError)
        }
    }
    do {
        let vm = try OpenJ9VM.start(configuration: config)
        vm.runMain(className: "com.example.Main", arguments: ["hello"],
                   completionQueue: .main) { status, error in
            if let error { NSLog("Java failed (%d): %@", status, error.localizedDescription) }
        }
    } catch {
        NSLog("JVM startup failed: %@", error.localizedDescription)
    }
}
```

The `HelloIOS` smoke class in this repository declares a native method; run it through the sample app, which registers that method first, rather than substituting it for `com.example.Main` above. Synchronous `runMain(className:arguments:)` throws an NSError containing the Java exception's formatted stack trace. The asynchronous variant reports status `0` or `-1` plus that NSError. A Java `main` returning does **not** destroy the VM or wait for Java child threads; coordinate your Java tasks explicitly.

## Objective-C and JNI

```objc
#import <OpenJ9Kit/OpenJ9Kit.h>

OJ9JavaVMConfiguration *configuration = [OJ9JavaVMConfiguration new];
configuration.classPath = @[[NSBundle.mainBundle pathForResource:@"Application" ofType:@"jar"]];
configuration.maxHeap = @"256m";
NSError *error = nil;
OJ9JavaVM *vm = [OJ9JavaVM startWithConfiguration:configuration error:&error];
if (vm) {
    int status = [vm runMainClass:@"com.example.Main" arguments:@[] error:&error];
    // status == -1: inspect error.localizedDescription for the Java stack trace.
    (void)status;
}
```

The kit includes unmodified OpenJDK JNI headers (`jni.h`, Unix LP64 `jni_md.h`, suitable for Darwin arm64) with their upstream copyright/license notices. JNI is directly available to host Objective-C/C code. For a host native method, register an existing function in the app rather than generating another dylib:

```objc
static jint JNICALL Add(JNIEnv *env, jclass cls, jint a, jint b) {
    (void)env; (void)cls;
    return a + b;
}

// Java declaration: package com.example; public class Native { public static native int add(int a, int b); }
[vm performWithEnv:^(JNIEnv *env) {
    jclass cls = (*env)->FindClass(env, "com/example/Native");
    if (cls) {
        JNINativeMethod methods[] = {{"add", "(II)I", (void *)&Add}};
        if ((*env)->RegisterNatives(env, cls, methods, 1) != JNI_OK) {
            // Report registration failure to your own caller.
        }
    }
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
}];
```

`performWithEnv` is synchronous and reentrant when already on the Java thread. It scopes local references in a JNI local frame; do not save local references past the block. Use `NewGlobalRef`/`DeleteGlobalRef` for longer-lived Java objects. A pending Java exception belongs to your block: inspect and clear it or handle it in Java. Never throw Objective-C exceptions across JNI or the block boundary. If local-frame allocation fails, the block is not invoked and the VM exception is described/cleared.

For an existing native thread, `attachCurrentThread` returns a thread-local `JNIEnv *` or NULL. The kit creates **daemon** attachments and installs a pthread TLS destructor so a thread exiting cannot leave a stale attachment. `detachCurrentThread` only detaches attachments the kit created; it does not detach a pre-existing host/Java attachment or the dedicated VM thread. Pair attach/use/detach on the **same** thread. Never pass a JNIEnv between threads, return one out of `performWithEnv`, or detach while Java frames are active. GCD queues do not promise stable thread identity: use a dedicated pthread or keep all JNI work inside a single block. Native attached threads may need an explicit class loader/global class reference for application classes; `FindClass` loader behavior differs from a Java caller.

## Configuration and process lifetime

Configuration is copied at startup; later mutation has no effect. Defaults are:

| Setting | Default |
| --- | --- |
| `maxHeap` | `512m` (`-Xmx`) |
| `threadStackSize` | `2m` (`-Xss`, separate from the native startup pthread stack) |
| `javaHome` | `jvm.framework/javahome`, located from the linked `JNI_CreateJavaVM` symbol |
| `classPath`, `options` | Empty arrays |
| `java.io.tmpdir`, dump directory | `NSTemporaryDirectory()` |
| `user.home` | `NSHomeDirectory()` |
| `user.dir` | Sandbox Documents directory |
| Other automatic options | `-Xint`, `-Xshareclasses:none`, `-Dcom.ibm.tools.attach.enable=no` |

Raw `options` are appended after the defaults, allowing normal JVM `-D`/`-X` configuration; invalid options fail startup. Do not enable JIT/AOT, attach or shared classes, and do not set conflicting `java.home`/classpath properties: use their configuration properties. An override `javaHome` must point to an actual compatible linked runtime, including `lib/modules`.

**One VM per process, with one startup attempt.** Even a failed JNI creation can leave native global state, so retrying is rejected. The VM, Java thread, hooks and attachments' owner are intentionally retained for the process lifetime; there is no shutdown, `DestroyJavaVM`, unloading or restart API. Do not create another VM through the raw JNI invocation interface.

**`System.exit(n)` terminates the whole iOS app process.** The optional `exitHandler` is a notification hook, not a way to make Java continue. It runs on the exiting VM thread; it must not call Java, throw, or block awaiting UI work. If it returns, the kit calls C `exit(n)`. Without a handler it also calls `exit(n)`. Runtime.halt, native abort/crashes and OS kills need not run this handler. Do not use System.exit as an embedded application's normal return path, and do not use programmatic process exit as production iOS navigation. The smoke app exits deliberately only under `OPENJ9_SMOKE_EXIT=1` for automation.

**Output capture is process-wide.** The JNI `vfprintf` hook captures VM diagnostics; it alone does not capture arbitrary Java stdout. The kit also redirects the process stdout/stderr descriptors through pipes, mirrors raw bytes to the original console, reconstructs UTF-8 lines, forwards them to `os_log` (public text) and invokes `outputHandler` on its serial output queue. Both native and Java writes to these descriptors are therefore visible. Handlers must return quickly, dispatch UI work asynchronously, and must not write back to stdout/stderr (feedback loop) or synchronously call Java (possible pipe deadlock). Newline-free partial lines remain buffered. Console output can contain sensitive application data; redact before logging or avoid printing secrets. A crash/exit can lose queued trailing output; the handler is not a durable audit log.

## Runtime and distribution limits

- Interpreter only: no JIT or AOT compilation and no executable-memory workaround. CPU-heavy Java can be much slower than on desktop OpenJ9.
- No `java.desktop`, AWT, Swing, Java2D or sound. Modules depending on those are excluded.
- No process spawning (`ProcessBuilder`, `Runtime.exec`, fork/exec, shell commands), attach tooling, shared class cache or desktop serviceability executables. Do not assume desktop agents, native libraries or filesystem layouts work unchanged.
- All native libraries must be built for the exact iOS device/simulator platform and packaged/signed as frameworks. Do not copy desktop dylibs into the app. The simulator is not evidence of device API compatibility.
- Heap size is not total footprint. Java/native stacks, class metadata, buffers and the runtime itself add memory; iOS jetsam can kill the app without a Java OutOfMemoryError. Start below the default heap (the sample uses 256 MiB), measure on your oldest supported devices, limit thread counts, and respond to memory/background lifecycle constraints.
- The bundled `PrivacyInfo.xcprivacy` declares no tracking/collected data and required-reason API categories FileTimestamp (`C617.1`), SystemBootTime (`35F9.1`), DiskSpace (`E174.1`) and UserDefaults (`CA92.1`). The app publisher must verify that the reasons match actual use and supply additional app/SDK privacy disclosures as necessary; the template is not a compliance certification.
- **Disabling JIT does not guarantee App Store approval.** Public API usage, signing, framework layout, downloaded/interpreted-code restrictions, privacy declarations and current App Review rules are separate requirements. Audit all native APIs and Java workloads, test archive validation on real Xcode/device builds, and obtain appropriate policy/legal review. This port makes no approval guarantee.

## Sample and simulator smoke

`Samples/HelloJava` is a UIKit app described by XcodeGen. Its build scripts use `HOST_JAVA_HOME` (then `JAVA_HOME`, then `/usr/libexec/java_home -v 21`), compile with `javac --release 21`, and bundle the generated jar before signing. The app registers `HelloIOS.nativeAdd` from Objective-C, displays captured output, and runs the Java smoke suite: properties, indy string concatenation, lambdas/streams, records/switch patterns, reflection, threads/executors, numeric types, regex, time zones/locales, sandbox file IO, ZIP/GZIP, SHA-256, SecureRandom, UTF-8, stack traces and logging.

```sh
xcodegen generate --spec Samples/HelloJava/project.yml --project Samples/HelloJava
# Open Samples/HelloJava/HelloJava.xcodeproj and run HelloJava normally, or:
bash scripts/smoke-test-simulator.sh --out build/smoke-simulator --timeout 600
```

The smoke script builds for `generic/platform=iOS Simulator` with local ad-hoc signing, selects the latest available iOS runtime and a compatible iPhone type, creates/boots a disposable simulator, installs the app, and launches it with `SIMCTL_CHILD_OPENJ9_SMOKE_EXIT=1`. It imposes a launch deadline, saves console/build logs, requires `OPENJ9_IOS_SMOKE_OK` and no failure marker, prints the last 200 log lines and new HelloJava crash reports on failure, and deletes its simulator on exit. Install an iOS simulator runtime in Xcode first. Device signing and device testing remain separate steps.

Scripts are intended to be executable in Git on macOS; `bash scripts/<name>.sh` also works if a checkout loses executable bits. Generated Xcode projects, jars, build logs and binary artifacts are build outputs, not sources.
