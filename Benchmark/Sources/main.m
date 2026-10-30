// Host app for comparing JVM implementations on iOS.
//
// The same source builds twice:
//   BenchOpenJ9 - links the OpenJ9 SwiftPM product, so JNI_CreateJavaVM comes
//                 from jvm.framework and the Java image from its javahome.
//   BenchZero   - links a HotSpot Zero static archive set (ZERO_RUNTIME), so the
//                 VM is inside this binary and the Java image sits in <bundle>/lib.
//
// Nothing here depends on a particular VM: it only uses the JNI invocation API.
//
// Launching the app directly shows an interactive screen: choose a test, tap
// Run, and read or share the log. Benchmark/run.sh sets BENCH_AUTORUN=1 so the
// same binary still starts BENCH_MODE immediately, streams the same lines and
// exits when the run ends.
#import <UIKit/UIKit.h>
#include <TargetConditionals.h>
#include <jni.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <mach/mach.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>

static atomic_bool gSampling;
static pthread_t gSamplerThread;
static BOOL gSamplerStarted;

static float sampleProcess(void) {
    task_vm_info_data_t vm = {0};
    mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
    kern_return_t vmStatus = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &vmCount);
    task_basic_info_64_data_t basic = {0};
    mach_msg_type_number_t basicCount = TASK_BASIC_INFO_64_COUNT;
    kern_return_t basicStatus = task_info(mach_task_self(), TASK_BASIC_INFO_64, (task_info_t)&basic, &basicCount);
    task_thread_times_info_data_t threads = {0};
    mach_msg_type_number_t threadCount = TASK_THREAD_TIMES_INFO_COUNT;
    kern_return_t threadStatus = task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, (task_info_t)&threads, &threadCount);
    __block float battery = -1;
    __block UIDeviceBatteryState state = UIDeviceBatteryStateUnknown;
    dispatch_sync(dispatch_get_main_queue(), ^{
        battery = UIDevice.currentDevice.batteryLevel;
        state = UIDevice.currentDevice.batteryState;
    });
    double cpu = -1;
    if (basicStatus == KERN_SUCCESS && threadStatus == KERN_SUCCESS) {
        cpu = basic.user_time.seconds + basic.system_time.seconds +
              threads.user_time.seconds + threads.system_time.seconds +
              (basic.user_time.microseconds + basic.system_time.microseconds +
               threads.user_time.microseconds + threads.system_time.microseconds) / 1000000.0;
    }
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    printf("IDLE_SAMPLE monotonic_s=%.3f cpu_s=%.6f resident_bytes=%lld footprint_bytes=%lld battery=%.3f battery_state=%ld thermal=%ld low_power=%d\n",
           now.tv_sec + now.tv_nsec / 1e9, cpu,
           basicStatus == KERN_SUCCESS ? (long long)basic.resident_size : -1LL,
           vmStatus == KERN_SUCCESS ? (long long)vm.phys_footprint : -1LL,
           battery, (long)state, (long)NSProcessInfo.processInfo.thermalState,
           NSProcessInfo.processInfo.lowPowerModeEnabled);
    fflush(stdout);
    return battery;
}

static void *sampleThread(void *unused) {
    (void)unused;
    @autoreleasepool {
        int interval = 10;
        const char *value = getenv("BENCH_SAMPLE_INTERVAL");
        if (value) {
            int parsed = atoi(value);
            if (parsed >= 1 && parsed <= 3600) interval = parsed;
        }
        struct timespec started, ended;
        clock_gettime(CLOCK_MONOTONIC, &started);
        float initialBattery = sampleProcess();
        int elapsed = 0;
        while (atomic_load(&gSampling)) {
            sleep(1);
            if (++elapsed >= interval && atomic_load(&gSampling)) {
                sampleProcess();
                elapsed = 0;
            }
        }
        float finalBattery = sampleProcess();
        clock_gettime(CLOCK_MONOTONIC, &ended);
        double duration = ended.tv_sec - started.tv_sec + (ended.tv_nsec - started.tv_nsec) / 1e9;
        if (initialBattery >= 0 && finalBattery >= 0) {
            printf("IDLE_BATTERY duration_s=%.3f start=%.3f end=%.3f drain_percentage_points=%.3f\n",
                   duration, initialBattery, finalBattery, (initialBattery - finalBattery) * 100.0);
        } else {
            printf("IDLE_BATTERY duration_s=%.3f drain_percentage_points=unavailable\n", duration);
        }
        fflush(stdout);
    }
    return NULL;
}

static void JNICALL startSampling(JNIEnv *env, jclass cls) {
    (void)cls;
    atomic_store(&gSampling, true);
    int status = pthread_create(&gSamplerThread, NULL, sampleThread, NULL);
    if (status) {
        atomic_store(&gSampling, false);
        jclass exception = (*env)->FindClass(env, "java/lang/IllegalStateException");
        (*env)->ThrowNew(env, exception, "unable to start sampling thread");
        return;
    }
    gSamplerStarted = YES;
}

static void JNICALL stopSampling(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    atomic_store(&gSampling, false);
    if (gSamplerStarted) {
        pthread_join(gSamplerThread, NULL);
        gSamplerStarted = NO;
    }
}

#ifdef BENCH_ZERO
static NSString *const kRuntimeName = @"zero";
#else
static NSString *const kRuntimeName = @"openj9";
#endif

static NSString *const kDefaultMode = @"all";

static JavaVM *gVM;
static JNIEnv *gEnv;
static NSString *gBenchJar;
static NSString *gJavaHome;
static NSString *gServerJar;
static atomic_bool gJVMReady;

static BOOL gAutorun;
static BOOL gRunning;
static BOOL gCapturing;
static BOOL gWorkerStarted;
static BOOL gSuwayomiStarted;
static NSCondition *gWorkCondition;
static NSString *gPendingMode;

static int gLastRunStatus = -1;
static NSTimeInterval gLastRunSeconds;
static NSUInteger gRunCount;
static NSString *gLastRunMode;

static NSString *javaHomeForBundle(void);

static UITextView *gOutput;
static UILabel *gStatusLabel;
static UIButton *gRunButton;
static UIButton *gModeButton;
static NSString *gMode = @"all";
static NSTimeInterval gRunStarted;

static NSString *environmentValue(NSString *key, NSString *fallback) {
    NSString *value = NSProcessInfo.processInfo.environment[key];
    return value.length ? value : fallback;
}

static NSArray<NSString *> *benchModes(void) {
    return @[@"all", @"bench", @"compat", @"idle", @"suwayomi", @"suwayomi-idle"];
}

static BOOL modeIsSuwayomi(NSString *mode) {
    return [mode isEqualToString:@"suwayomi"] || [mode isEqualToString:@"suwayomi-idle"];
}

static BOOL modeIsExtended(NSString *mode) {
    return [mode isEqualToString:@"idle"] || modeIsSuwayomi(mode);
}

static int benchDurationSeconds(void) {
    NSString *value = NSProcessInfo.processInfo.environment[@"BENCH_DURATION"];
    int seconds = value.intValue;
    return seconds >= 1 && seconds <= 86400 ? seconds : 60;
}

static NSString *modeTitle(NSString *mode) {
    if ([mode isEqualToString:@"bench"]) return @"Benchmarks";
    if ([mode isEqualToString:@"compat"]) return @"Compatibility";
    if ([mode isEqualToString:@"idle"]) {
        return [NSString stringWithFormat:@"Idle JVM (%d s)", benchDurationSeconds()];
    }
    if ([mode isEqualToString:@"suwayomi"]) {
        return [NSString stringWithFormat:@"Suwayomi stress (%d s)", benchDurationSeconds()];
    }
    if ([mode isEqualToString:@"suwayomi-idle"]) {
        return [NSString stringWithFormat:@"Suwayomi idle (%d s)", benchDurationSeconds()];
    }
    return @"All";
}

static NSString *runStatusDescription(void) {
    if (gRunning) return @"running";
    if (gRunCount == 0) return @"never";
    return gLastRunStatus == 0 ? @"ok" : @"failed";
}

static NSString *thermalDescription(NSInteger state) {
    switch (state) {
        case 0: return @"nominal";
        case 1: return @"fair";
        case 2: return @"serious";
        case 3: return @"critical";
        default: return @"unknown";
    }
}

static NSString *batteryDescription(UIDeviceBatteryState state) {
    switch (state) {
        case UIDeviceBatteryStateUnplugged: return @"unplugged";
        case UIDeviceBatteryStateCharging: return @"charging";
        case UIDeviceBatteryStateFull: return @"full";
        default: return @"unknown";
    }
}

static void reportTimestamp(char *iso, size_t isoSize, char *stamp, size_t stampSize) {
    time_t now = time(NULL);
    struct tm utc;
    gmtime_r(&now, &utc);
    strftime(iso, isoSize, "%Y-%m-%dT%H:%M:%SZ", &utc);
    strftime(stamp, stampSize, "%Y%m%d-%H%M%S", &utc);
}

static unsigned long long fileBytes(NSString *path) {
    if (!path) return 0;
    FILE *file = fopen(path.fileSystemRepresentation, "rb");
    if (!file) return 0;
    unsigned long long bytes = 0;
    if (fseek(file, 0, SEEK_END) == 0) {
        long size = ftell(file);
        if (size > 0) bytes = (unsigned long long)size;
    }
    fclose(file);
    return bytes;
}

static NSString *readableText(NSString *path, NSUInteger limit) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!text) return nil;
    return text.length > limit ? [text substringToIndex:limit] : text;
}

static NSString *diagnosticReport(NSString *generated) {
    NSMutableString *report = [NSMutableString stringWithCapacity:4096];
    NSBundle *bundle = NSBundle.mainBundle;
    NSProcessInfo *process = NSProcessInfo.processInfo;
    UIDevice *device = UIDevice.currentDevice;
    UIScreen *screen = UIScreen.mainScreen;
    struct utsname host;
    NSString *machine = @"unknown";
    if (uname(&host) == 0) machine = [NSString stringWithUTF8String:host.machine] ?: @"unknown";

    [report appendString:@"OpenJ9 iOS benchmark report\n"];
    [report appendFormat:@"generated_utc=%@\n", generated];
    [report appendString:@"note=Review before uploading. This file contains device details, build paths, "
                           @"selected benchmark environment values, JVM crash logs and the benchmark console.\n\n"];

    [report appendString:@"[run]\n"];
    [report appendFormat:@"runtime=%@\n", kRuntimeName];
    [report appendFormat:@"mode_id=%@\n", gMode];
    [report appendFormat:@"mode_label=%@\n", modeTitle(gMode)];
    [report appendFormat:@"state=%@\n", gRunning ? @"running" : @"idle"];
    [report appendFormat:@"autorun=%d\n", gAutorun ? 1 : 0];
    [report appendFormat:@"jvm_created=%d\n", atomic_load(&gJVMReady) ? 1 : 0];
    [report appendFormat:@"runs_started=%lu\n", (unsigned long)gRunCount];
    [report appendFormat:@"last_run_mode=%@\n", gLastRunMode ?: @"none"];
    [report appendFormat:@"last_run_status=%@\n", runStatusDescription()];
    [report appendFormat:@"last_run_seconds=%.3f\n", gLastRunSeconds];

    [report appendString:@"\n[app]\n"];
    [report appendFormat:@"bundle_id=%@\n", bundle.bundleIdentifier ?: @"unknown"];
    [report appendFormat:@"bundle_version=%@\n", [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown"];
    [report appendFormat:@"bundle_build=%@\n", [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown"];
    [report appendFormat:@"bundle_path=%@\n", bundle.bundlePath];
    [report appendFormat:@"os=%@\n", process.operatingSystemVersionString];
    [report appendFormat:@"simulator=%d\n", TARGET_OS_SIMULATOR];
    [report appendFormat:@"device_model=%@\n", device.model];
    [report appendFormat:@"device_type=%@\n", machine];
    [report appendFormat:@"device_localized_model=%@\n", device.localizedModel];
    [report appendFormat:@"device_system=%@ %@\n", device.systemName, device.systemVersion];
    [report appendFormat:@"screen_points=%.0fx%.0f\n", screen.bounds.size.width, screen.bounds.size.height];
    [report appendFormat:@"screen_scale=%.2f\n", screen.scale];
    [report appendFormat:@"physical_memory_bytes=%llu\n", process.physicalMemory];
    [report appendFormat:@"processors=%lu\n", (unsigned long)process.processorCount];
    [report appendFormat:@"active_processors=%lu\n", (unsigned long)process.activeProcessorCount];
    [report appendFormat:@"system_uptime_s=%.3f\n", process.systemUptime];
    [report appendFormat:@"thermal=%@\n", thermalDescription((NSInteger)process.thermalState)];
    [report appendFormat:@"low_power=%d\n", process.lowPowerModeEnabled ? 1 : 0];
    [report appendFormat:@"battery_level=%.3f\n", device.batteryLevel];
    [report appendFormat:@"battery_state=%@\n", batteryDescription(device.batteryState)];

    [report appendString:@"\n[environment]\n"];
    NSArray<NSString *> *keys = @[@"BENCH_MODE", @"BENCH_AUTORUN", @"BENCH_WARMUP", @"BENCH_REPS",
                                  @"BENCH_DURATION", @"BENCH_SAMPLE_INTERVAL", @"SUWAYOMI_PORT",
                                  @"SUWAYOMI_STARTUP_TIMEOUT", @"SUWAYOMI_CONCURRENCY"];
    BOOL anyEnvironment = NO;
    for (NSString *key in keys) {
        NSString *value = process.environment[key];
        if (!value.length) continue;
        [report appendFormat:@"%@=%@\n", key, value];
        anyEnvironment = YES;
    }
    if (!anyEnvironment) [report appendString:@"(none)\n"];

    [report appendString:@"\n[bundle]\n"];
    NSString *bench = [bundle pathForResource:@"bench" ofType:@"jar"];
    NSString *server = [bundle pathForResource:@"suwayomi" ofType:@"jar"];
    NSString *javaHome = javaHomeForBundle();
    [report appendFormat:@"bench_jar=%@\n", bench ?: @"(missing)"];
    [report appendFormat:@"bench_jar_bytes=%llu\n", fileBytes(bench)];
    [report appendFormat:@"suwayomi_jar=%@\n", server ?: @"(not bundled)"];
    [report appendFormat:@"suwayomi_jar_bytes=%llu\n", fileBytes(server)];
    [report appendFormat:@"java_home=%@\n", javaHome];
    [report appendFormat:@"java_home_exists=%d\n", [[NSFileManager defaultManager] fileExistsAtPath:javaHome] ? 1 : 0];
#ifdef BENCH_ZERO
    [report appendString:@"jvm_linkage=static\n"];
#else
    NSString *framework = [bundle.bundlePath stringByAppendingPathComponent:@"Frameworks/jvm.framework"];
    [report appendFormat:@"jvm_framework=%@\n", framework];
    [report appendFormat:@"jvm_framework_exists=%d\n", [[NSFileManager defaultManager] fileExistsAtPath:framework] ? 1 : 0];
    [report appendString:@"jvm_linkage=jvm.framework\n"];
#endif

    [report appendString:@"\n[jvm diagnostics]\n"];
    NSError *listingError = nil;
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory()
                                                                                       error:&listingError];
    NSMutableArray<NSString *> *crashLogs = [NSMutableArray array];
    NSMutableArray<NSString *> *dumpFiles = [NSMutableArray array];
    if (entries) {
        for (NSString *name in entries) {
            if ([name hasPrefix:@"hs_err_"] && [name hasSuffix:@".log"]) {
                [crashLogs addObject:name];
            } else if (([name hasPrefix:@"javacore"] && [name hasSuffix:@".txt"]) ||
                       ([name hasPrefix:@"Snap"] && [name hasSuffix:@".txt"]) ||
                       [name hasPrefix:@"core."]) {
                [dumpFiles addObject:name];
            }
        }
        [report appendFormat:@"crash_logs=%lu\n", (unsigned long)crashLogs.count];
        [report appendFormat:@"jvm_dumps=%lu\n", (unsigned long)dumpFiles.count];
        for (NSString *name in dumpFiles) {
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
            [report appendFormat:@"jvm_dump=%@ bytes=%llu\n", name, fileBytes(path)];
        }
    } else {
        [report appendFormat:@"crash_logs=unavailable (%@)\n", listingError.localizedDescription ?: @"unknown"];
    }
    NSUInteger embedded = 0;
    for (NSString *name in crashLogs) {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
        if (embedded >= 4) {
            [report appendFormat:@"crash_log_skipped=%@ bytes=%llu\n", name, fileBytes(path)];
            continue;
        }
        NSString *text = readableText(path, 65536);
        unsigned long long bytes = fileBytes(path);
        [report appendFormat:@"\n--- %@ (%llu bytes) ---\n", name, bytes];
        [report appendString:text ?: @"(unreadable)\n"];
        if (bytes > 65536) [report appendString:@"\n(truncated)\n"];
        [report appendString:@"\n"];
        embedded++;
    }

    [report appendString:@"\n[console]\n"];
    NSString *console = gOutput.text ?: @"";
    if (console.length) {
        [report appendString:console];
        if (![console hasSuffix:@"\n"]) [report appendString:@"\n"];
    } else {
        [report appendString:@"(empty)\n"];
    }
    return report;
}

static void appendOutputLine(NSString *line) {
    if (!gOutput) return;
    NSString *copy = [line copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gOutput) return;
        NSString *current = gOutput.text ?: @"";
        if (current.length > 400000) current = [current substringFromIndex:current.length - 200000];
        gOutput.text = [current stringByAppendingFormat:@"%@\n", copy];
        [gOutput scrollRangeToVisible:NSMakeRange(gOutput.text.length, 0)];
    });
}

static NSString *visibleLine(NSString *line) {
    if ([line hasSuffix:@"\r"]) line = [line substringToIndex:line.length - 1];
    if ([line rangeOfString:@"\033"].location == (NSUInteger)NSNotFound) return line;
    NSMutableString *result = [NSMutableString stringWithCapacity:line.length];
    NSUInteger index = 0;
    while (index < line.length) {
        unichar character = [line characterAtIndex:index];
        if (character == 0x1b && index + 1 < line.length && [line characterAtIndex:index + 1] == '[') {
            index += 2;
            while (index < line.length) {
                unichar code = [line characterAtIndex:index++];
                if (code >= 0x40 && code <= 0x7e) break;
            }
        } else {
            [result appendFormat:@"%C", character];
            index++;
        }
    }
    return result;
}

static void writeAll(int descriptor, const void *buffer, size_t length) {
    const uint8_t *bytes = buffer;
    while (length > 0) {
        ssize_t written = write(descriptor, bytes, length);
        if (written > 0) {
            bytes += written;
            length -= (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
}

static void captureReadLoop(int savedOutput, int readDescriptor) {
    @autoreleasepool {
        NSMutableData *pending = [NSMutableData data];
        uint8_t chunk[4096];
        while (true) {
            ssize_t count = read(readDescriptor, chunk, sizeof(chunk));
            if (count > 0) {
                writeAll(savedOutput, chunk, (size_t)count);
                [pending appendBytes:chunk length:(NSUInteger)count];
                while (true) {
                    const uint8_t *bytes = pending.bytes;
                    NSUInteger length = pending.length;
                    NSUInteger newline = (NSUInteger)NSNotFound;
                    for (NSUInteger index = 0; index < length; index++) {
                        if (bytes[index] == '\n') { newline = index; break; }
                    }
                    if (newline == (NSUInteger)NSNotFound) break;
                    NSData *lineData = [pending subdataWithRange:NSMakeRange(0, newline)];
                    [pending replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
                    NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
                    if (!line) line = [[NSString alloc] initWithData:lineData encoding:NSISOLatin1StringEncoding];
                    if (line) appendOutputLine(visibleLine(line));
                }
            } else if (count < 0 && errno == EINTR) {
                continue;
            } else {
                break;
            }
        }
        if (pending.length) {
            NSString *line = [[NSString alloc] initWithData:pending encoding:NSUTF8StringEncoding];
            if (line) appendOutputLine(visibleLine(line));
        }
        close(readDescriptor);
    }
}

// Mirror stdout and stderr into the on-screen console while keeping the
// process console readable. Only used when the app is not in automation mode.
static void startOutputCapture(void) {
    if (gCapturing) return;
    int pipeDescriptors[2];
    if (pipe(pipeDescriptors) != 0) return;
    int savedOutput = dup(STDOUT_FILENO);
    int savedError = dup(STDERR_FILENO);
    if (savedOutput < 0 || savedError < 0) {
        if (savedOutput >= 0) close(savedOutput);
        if (savedError >= 0) close(savedError);
        close(pipeDescriptors[0]);
        close(pipeDescriptors[1]);
        return;
    }
    close(savedError);
    if (dup2(pipeDescriptors[1], STDOUT_FILENO) < 0 ||
        dup2(pipeDescriptors[1], STDERR_FILENO) < 0) {
        dup2(savedOutput, STDOUT_FILENO);
        close(savedOutput);
        close(pipeDescriptors[0]);
        close(pipeDescriptors[1]);
        return;
    }
    close(pipeDescriptors[1]);
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    gCapturing = YES;
    int readDescriptor = pipeDescriptors[0];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        captureReadLoop(savedOutput, readDescriptor);
    });
}

static void emit(NSString *line) {
    printf("%s\n", line.UTF8String);
    fflush(stdout);
    if (!gCapturing) appendOutputLine(line);
}

static void finish(int status) {
    emit(status == 0 ? @"BENCH_APP_DONE" : [NSString stringWithFormat:@"BENCH_APP_FAIL status=%d", status]);
    if (gAutorun) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ exit(status); });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        gRunning = NO;
        [gRunButton setEnabled:YES];
        [gModeButton setEnabled:YES];
        UIButtonConfiguration *configuration = gRunButton.configuration;
        configuration.title = @"Run";
        gRunButton.configuration = configuration;
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - gRunStarted;
        gLastRunStatus = status;
        gLastRunSeconds = elapsed;
        gStatusLabel.textColor = status == 0 ? [UIColor systemGreenColor] : [UIColor systemRedColor];
        gStatusLabel.text = status == 0
            ? [NSString stringWithFormat:@"Finished · %.1f s", elapsed]
            : [NSString stringWithFormat:@"Failed · %.1f s — see the log above", elapsed];
    });
}

static NSString *javaHomeForBundle(void) {
    NSString *bundle = NSBundle.mainBundle.bundlePath;
#ifdef BENCH_ZERO
    // A statically linked HotSpot derives java.home from the executable and
    // appends /lib, where the jlinked image lives.
    return [bundle stringByAppendingPathComponent:@"lib"];
#else
    return [bundle stringByAppendingPathComponent:@"Frameworks/jvm.framework/javahome"];
#endif
}

// Create the process-wide VM on the caller's thread. JNI allows only one VM per
// process, so every later run reuses gVM/gEnv on this same worker thread.
static BOOL ensureJVM(void) {
    if (gVM && gEnv) return YES;
    NSString *jar = [NSBundle.mainBundle pathForResource:@"bench" ofType:@"jar"];
    if (!jar) {
        emit(@"BENCH_APP_FAIL missing bench.jar");
        return NO;
    }
    NSString *javaHome = javaHomeForBundle();
    if (![[NSFileManager defaultManager] fileExistsAtPath:javaHome]) {
        emit([NSString stringWithFormat:@"BENCH_APP_FAIL java home missing: %@", javaHome]);
        return NO;
    }
    gBenchJar = jar;
    gJavaHome = javaHome;
    gServerJar = [NSBundle.mainBundle pathForResource:@"suwayomi" ofType:@"jar"];
    NSString *temporary = NSTemporaryDirectory();

    static char classPath[8192], home[4096], tmp[4096], dumpDir[4096], warmup[128], reps[128], errorFile[4096];
    int written = gServerJar
        ? snprintf(classPath, sizeof(classPath), "-Djava.class.path=%s:%s", jar.UTF8String, gServerJar.UTF8String)
        : snprintf(classPath, sizeof(classPath), "-Djava.class.path=%s", jar.UTF8String);
    if (written < 0 || (size_t)written >= sizeof(classPath)) {
        emit(@"BENCH_APP_FAIL class path too long");
        return NO;
    }
    snprintf(home, sizeof(home), "-Djava.home=%s", javaHome.UTF8String);
    snprintf(tmp, sizeof(tmp), "-Djava.io.tmpdir=%s", temporary.UTF8String);
    snprintf(dumpDir, sizeof(dumpDir), "-Xdump:directory=%s", temporary.UTF8String);
    snprintf(errorFile, sizeof(errorFile), "-XX:ErrorFile=%s/hs_err_%%p.log", temporary.UTF8String);
    snprintf(warmup, sizeof(warmup), "-Dbench.warmupMs=%s", environmentValue(@"BENCH_WARMUP", @"400").UTF8String);
    snprintf(reps, sizeof(reps), "-Dbench.reps=%s", environmentValue(@"BENCH_REPS", @"5").UTF8String);

    JavaVMOption options[16];
    int count = 0;
    options[count++].optionString = classPath;
    options[count++].optionString = home;
    options[count++].optionString = tmp;
    options[count++].optionString = warmup;
    options[count++].optionString = reps;
#ifdef BENCH_ZERO
    // Zero is interpreter-only; iOS forbids executable memory and has no
    // writable /tmp or attach listener.
    options[count++].optionString = (char *)"-Xint";
    options[count++].optionString = (char *)"-Xshare:off";
    options[count++].optionString = (char *)"-XX:+UseSerialGC";
    options[count++].optionString = (char *)"-Xms64m";
    options[count++].optionString = (char *)"-Xmx512m";
    options[count++].optionString = (char *)"-XX:+DisableAttachMechanism";
    options[count++].optionString = (char *)"-XX:-UsePerfData";
    options[count++].optionString = errorFile;
#else
    options[count++].optionString = (char *)"-Xint";
    options[count++].optionString = (char *)"-Xshareclasses:none";
    options[count++].optionString = dumpDir;
    options[count++].optionString = (char *)"-Dcom.ibm.tools.attach.enable=no";
    options[count++].optionString = (char *)"-Xms64m";
    options[count++].optionString = (char *)"-Xmx512m";
#endif

    JavaVMInitArgs arguments;
    arguments.version = JNI_VERSION_1_8;
    arguments.nOptions = count;
    arguments.options = options;
    arguments.ignoreUnrecognized = JNI_FALSE;

    jint status = JNI_CreateJavaVM(&gVM, (void **)&gEnv, &arguments);
    if (status != JNI_OK || gEnv == NULL) {
        gVM = NULL;
        gEnv = NULL;
        emit([NSString stringWithFormat:@"BENCH_APP_FAIL JNI_CreateJavaVM=%d", (int)status]);
        return NO;
    }
    atomic_store(&gJVMReady, true);
    return YES;
}

static void runJvm(NSString *mode) {
    @autoreleasepool {
        if (!ensureJVM()) { finish(1); return; }
        BOOL extended = modeIsExtended(mode);
        BOOL needsServer = modeIsSuwayomi(mode);
        emit([NSString stringWithFormat:@"BENCH_RUNTIME name=%@ mode=%@ jar=%@ javaHome=%@",
              kRuntimeName, mode, gBenchJar, gJavaHome]);
        if (needsServer && !gServerJar) {
            emit(@"BENCH_APP_FAIL missing suwayomi.jar; set SUWAYOMI_JAR at build time");
            finish(1);
            return;
        }

        jclass main = (*gEnv)->FindClass(gEnv, extended ? "bench/SuwayomiMain" : "bench/BenchMain");
        if (main == NULL) {
            (*gEnv)->ExceptionDescribe(gEnv);
            (*gEnv)->ExceptionClear(gEnv);
            emit(@"BENCH_APP_FAIL benchmark entry class not found");
            finish(1);
            return;
        }
        if (extended) {
            JNINativeMethod methods[] = {
                {"startSampling", "()V", (void *)startSampling},
                {"stopSampling", "()V", (void *)stopSampling}
            };
            if ((*gEnv)->RegisterNatives(gEnv, main, methods, 2) != JNI_OK ||
                (*gEnv)->ExceptionCheck(gEnv)) {
                (*gEnv)->ExceptionDescribe(gEnv);
                (*gEnv)->ExceptionClear(gEnv);
                (*gEnv)->DeleteLocalRef(gEnv, main);
                emit(@"BENCH_APP_FAIL registering sampler");
                finish(1);
                return;
            }
        }
        jmethodID entry = (*gEnv)->GetStaticMethodID(gEnv, main, "main", "([Ljava/lang/String;)V");
        if (entry == NULL) {
            (*gEnv)->ExceptionDescribe(gEnv);
            (*gEnv)->ExceptionClear(gEnv);
            (*gEnv)->DeleteLocalRef(gEnv, main);
            emit(@"BENCH_APP_FAIL benchmark entry point missing");
            finish(1);
            return;
        }
        jclass stringClass = (*gEnv)->FindClass(gEnv, "java/lang/String");
        jobjectArray argv = NULL;
        jstring modeString = NULL;
        if (stringClass) {
            argv = (*gEnv)->NewObjectArray(gEnv, 1, stringClass, NULL);
            if (argv) modeString = (*gEnv)->NewStringUTF(gEnv, mode.UTF8String);
        }
        if (stringClass == NULL || argv == NULL || modeString == NULL) {
            (*gEnv)->ExceptionDescribe(gEnv);
            (*gEnv)->ExceptionClear(gEnv);
            if (modeString) (*gEnv)->DeleteLocalRef(gEnv, modeString);
            if (argv) (*gEnv)->DeleteLocalRef(gEnv, argv);
            if (stringClass) (*gEnv)->DeleteLocalRef(gEnv, stringClass);
            (*gEnv)->DeleteLocalRef(gEnv, main);
            emit(@"BENCH_APP_FAIL unable to build arguments");
            finish(1);
            return;
        }
        (*gEnv)->SetObjectArrayElement(gEnv, argv, 0, modeString);
        (*gEnv)->DeleteLocalRef(gEnv, modeString);
        (*gEnv)->CallStaticVoidMethod(gEnv, main, entry, argv);
        BOOL threw = (*gEnv)->ExceptionCheck(gEnv) != JNI_FALSE;
        if (threw) {
            (*gEnv)->ExceptionDescribe(gEnv);
            (*gEnv)->ExceptionClear(gEnv);
        }
        (*gEnv)->DeleteLocalRef(gEnv, argv);
        (*gEnv)->DeleteLocalRef(gEnv, stringClass);
        (*gEnv)->DeleteLocalRef(gEnv, main);
        if (threw) {
            emit(@"BENCH_APP_FAIL benchmark entry threw");
            finish(1);
            return;
        }
        finish(0);
    }
}

static void *workerMain(void *context) {
    (void)context;
    @autoreleasepool {
        while (true) {
            [gWorkCondition lock];
            while (!gPendingMode) [gWorkCondition wait];
            NSString *mode = gPendingMode;
            gPendingMode = nil;
            [gWorkCondition unlock];
            @autoreleasepool { runJvm(mode); }
        }
    }
    return NULL;
}

static BOOL enqueueRun(NSString *mode) {
    if (!gWorkCondition) gWorkCondition = [NSCondition new];
    if (gWorkerStarted) {
        [gWorkCondition lock];
        gPendingMode = mode;
        [gWorkCondition signal];
        [gWorkCondition unlock];
        return YES;
    }
    // pthread_create establishes the happens-before edge for the first mode.
    gPendingMode = mode;
    pthread_attr_t attributes;
    pthread_t thread;
    int status = pthread_attr_init(&attributes);
    if (!status) {
        status = pthread_attr_setstacksize(&attributes, 16 * 1024 * 1024);
        if (!status) status = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        if (!status) status = pthread_create(&thread, &attributes, workerMain, NULL);
        pthread_attr_destroy(&attributes);
    }
    if (status) {
        gPendingMode = nil;
        emit([NSString stringWithFormat:@"BENCH_APP_FAIL thread=%d", status]);
        return NO;
    }
    gWorkerStarted = YES;
    return YES;
}

@interface BenchViewController : UIViewController
@end

@interface BenchViewController ()
- (void)buildInterface;
- (void)refreshModeMenu;
- (void)runTapped:(UIButton *)sender;
- (void)startRun;
- (void)clearOutput:(UIButton *)sender;
- (void)exportResults:(UIButton *)sender;
- (void)presentMessage:(NSString *)title body:(NSString *)body;
@end

@implementation BenchViewController {
    BOOL _autoStarted;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self buildInterface];
    if (!gAutorun) startOutputCapture();
    emit([NSString stringWithFormat:@"BENCH_APP_START runtime=%@", kRuntimeName]);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (gAutorun && !_autoStarted) {
        _autoStarted = YES;
        [self startRun];
    }
}

- (void)buildInterface {
    UILabel *title = [[UILabel alloc] init];
    title.text = @"iOS benchmark";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;

    UILabel *runtime = [[UILabel alloc] init];
    runtime.text = kRuntimeName;
    runtime.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    runtime.textColor = [UIColor secondaryLabelColor];
    [runtime setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [runtime setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, runtime]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 8;

    gModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    gModeButton.showsMenuAsPrimaryAction = YES;
    gModeButton.accessibilityIdentifier = @"benchmark-mode";
    gModeButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    UIButtonConfiguration *modeConfiguration = [UIButtonConfiguration grayButtonConfiguration];
    modeConfiguration.image = [UIImage systemImageNamed:@"chevron.down"];
    modeConfiguration.imagePlacement = NSDirectionalRectEdgeTrailing;
    modeConfiguration.imagePadding = 6;
    gModeButton.configuration = modeConfiguration;
    [gModeButton setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [gModeButton setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self refreshModeMenu];

    gRunButton = [UIButton buttonWithType:UIButtonTypeSystem];
    gRunButton.accessibilityIdentifier = @"benchmark-run";
    UIButtonConfiguration *runConfiguration = [UIButtonConfiguration filledButtonConfiguration];
    runConfiguration.title = @"Run";
    runConfiguration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    runConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(8, 18, 8, 18);
    gRunButton.configuration = runConfiguration;
    [gRunButton addTarget:self action:@selector(runTapped:) forControlEvents:UIControlEventTouchUpInside];
    [gRunButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [gRunButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[gModeButton, gRunButton]];
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.alignment = UIStackViewAlignmentFill;
    controls.spacing = 8;

    gStatusLabel = [[UILabel alloc] init];
    gStatusLabel.text = @"Ready. Choose a test, then tap Run.";
    gStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    gStatusLabel.textColor = [UIColor secondaryLabelColor];
    gStatusLabel.numberOfLines = 2;
    gStatusLabel.adjustsFontForContentSizeCategory = YES;

    gOutput = [[UITextView alloc] init];
    gOutput.editable = NO;
    gOutput.selectable = YES;
    gOutput.alwaysBounceVertical = YES;
    gOutput.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    gOutput.backgroundColor = [UIColor secondarySystemBackgroundColor];
    gOutput.textColor = [UIColor labelColor];
    gOutput.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    gOutput.layer.cornerRadius = 10;
    gOutput.clipsToBounds = YES;
    gOutput.text = @"";
    gOutput.accessibilityIdentifier = @"benchmark-output";
    [gOutput.heightAnchor constraintGreaterThanOrEqualToConstant:160].active = YES;
    [gOutput setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [gOutput setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *clearConfiguration = [UIButtonConfiguration grayButtonConfiguration];
    clearConfiguration.title = @"Clear";
    clear.configuration = clearConfiguration;
    [clear addTarget:self action:@selector(clearOutput:) forControlEvents:UIControlEventTouchUpInside];

    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *shareConfiguration = [UIButtonConfiguration grayButtonConfiguration];
    shareConfiguration.title = @"Export / upload";
    share.configuration = shareConfiguration;
    share.accessibilityIdentifier = @"benchmark-export";
    [share addTarget:self action:@selector(exportResults:) forControlEvents:UIControlEventTouchUpInside];

    UIView *spacer = [[UIView alloc] init];
    [spacer setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *footer = [[UIStackView alloc] initWithArrangedSubviews:@[clear, spacer, share]];
    footer.axis = UILayoutConstraintAxisHorizontal;
    footer.alignment = UIStackViewAlignmentCenter;
    footer.spacing = 8;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[header, controls, gStatusLabel, gOutput, footer]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12]
    ]];
}

- (void)refreshModeMenu {
    __weak BenchViewController *weakSelf = self;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    BOOL hasServer = [NSBundle.mainBundle pathForResource:@"suwayomi" ofType:@"jar"] != nil;
    for (NSString *mode in benchModes()) {
        UIAction *action = [UIAction actionWithTitle:modeTitle(mode) image:nil identifier:mode
                                             handler:^(UIAction *selected) {
            (void)selected;
            BenchViewController *strongSelf = weakSelf;
            if (!strongSelf || gRunning) return;
            gMode = mode;
            [strongSelf refreshModeMenu];
        }];
        action.state = [mode isEqualToString:gMode] ? UIMenuElementStateOn : UIMenuElementStateOff;
        if (modeIsSuwayomi(mode) && !hasServer) action.attributes = UIMenuElementAttributesDisabled;
        [actions addObject:action];
    }
    gModeButton.menu = [UIMenu menuWithTitle:@"" children:actions];
    UIButtonConfiguration *configuration = gModeButton.configuration;
    configuration.title = [NSString stringWithFormat:@"Test: %@", modeTitle(gMode)];
    gModeButton.configuration = configuration;
}

- (void)runTapped:(UIButton *)sender {
    (void)sender;
    [self startRun];
}

- (void)startRun {
    if (gRunning) return;
    BOOL serverMode = modeIsSuwayomi(gMode);
    if (serverMode) {
        if (![NSBundle.mainBundle pathForResource:@"suwayomi" ofType:@"jar"]) {
            [self presentMessage:@"Suwayomi not bundled"
                            body:@"Rebuild the app with SUWAYOMI_JAR set to the Suwayomi Server jar."];
            return;
        }
        if (gSuwayomiStarted) {
            [self presentMessage:@"Suwayomi already started"
                            body:@"The server starts once per app launch. Relaunch the app to measure a fresh start."];
            return;
        }
    }
    gRunning = YES;
    gRunStarted = [[NSDate date] timeIntervalSince1970];
    gStatusLabel.textColor = [UIColor secondaryLabelColor];
    gStatusLabel.text = [NSString stringWithFormat:@"Running %@. Keep this screen open.", modeTitle(gMode)];
    [gRunButton setEnabled:NO];
    [gModeButton setEnabled:NO];
    UIButtonConfiguration *configuration = gRunButton.configuration;
    configuration.title = @"Running…";
    gRunButton.configuration = configuration;
    emit([NSString stringWithFormat:@"BENCH_RUN mode=%@ label=%@", gMode, modeTitle(gMode)]);
    if (!enqueueRun(gMode)) {
        gRunning = NO;
        [gRunButton setEnabled:YES];
        [gModeButton setEnabled:YES];
        configuration = gRunButton.configuration;
        configuration.title = @"Run";
        gRunButton.configuration = configuration;
        gStatusLabel.textColor = [UIColor systemRedColor];
        gStatusLabel.text = @"Could not start the JVM thread.";
        return;
    }
    gRunCount += 1;
    gLastRunMode = gMode;
    gLastRunStatus = -1;
    gLastRunSeconds = 0;
    if (serverMode) gSuwayomiStarted = YES;
}

- (void)clearOutput:(UIButton *)sender {
    (void)sender;
    gOutput.text = @"";
}

- (void)exportResults:(UIButton *)sender {
    char iso[32], stamp[32];
    reportTimestamp(iso, sizeof(iso), stamp, sizeof(stamp));
    NSString *report = diagnosticReport([NSString stringWithUTF8String:iso]);
    NSString *reportMode = gLastRunMode ?: gMode;
    NSString *name = [NSString stringWithFormat:@"ios-bench-%@-%@-%s.txt", kRuntimeName, reportMode, stamp];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    NSError *error = nil;
    if (![report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        [self presentMessage:@"Export failed" body:error.localizedDescription ?: @"Could not write the report."];
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                           applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) {
        popover.sourceView = sender;
        popover.sourceRect = sender.bounds;
    }
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)presentMessage:(NSString *)title body:(NSString *)body {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:body
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

@interface BenchAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation BenchAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    gAutorun = [environmentValue(@"BENCH_AUTORUN", @"0") isEqualToString:@"1"];
    NSString *requested = environmentValue(@"BENCH_MODE", kDefaultMode);
    gMode = [benchModes() containsObject:requested] ? requested : kDefaultMode;
    gWorkCondition = [NSCondition new];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [BenchViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(BenchAppDelegate.class)); }
}
