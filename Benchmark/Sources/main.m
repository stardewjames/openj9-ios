// Minimal host app for comparing JVM implementations on iOS.
//
// The same source builds twice:
//   BenchOpenJ9 - links the OpenJ9 SwiftPM product, so JNI_CreateJavaVM comes
//                 from jvm.framework and the Java image from its javahome.
//   BenchZero   - links a HotSpot Zero static archive set (ZERO_RUNTIME), so the
//                 VM is inside this binary and the Java image sits in <bundle>/lib.
//
// Nothing here depends on a particular VM: it only uses the JNI invocation API.
#import <UIKit/UIKit.h>
#include <jni.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <time.h>
#include <unistd.h>

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

static UITextView *gOutput;

static void emit(NSString *line) {
    printf("%s\n", line.UTF8String);
    fflush(stdout);
    dispatch_async(dispatch_get_main_queue(), ^{
        gOutput.text = [gOutput.text stringByAppendingFormat:@"%@\n", line];
    });
}

static void finish(int status) {
    emit(status == 0 ? @"BENCH_APP_DONE" : [NSString stringWithFormat:@"BENCH_APP_FAIL status=%d", status]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(status); });
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

static NSString *environmentValue(NSString *key, NSString *fallback) {
    NSString *value = NSProcessInfo.processInfo.environment[key];
    return value.length ? value : fallback;
}

static void runJvm(void) {
    @autoreleasepool {
        NSString *jar = [NSBundle.mainBundle pathForResource:@"bench" ofType:@"jar"];
        if (!jar) { emit(@"BENCH_APP_FAIL missing bench.jar"); finish(1); return; }
        NSString *javaHome = javaHomeForBundle();
        NSString *temporary = NSTemporaryDirectory();
        NSString *mode = environmentValue(@"BENCH_MODE", @"all");
        BOOL extended = [mode isEqualToString:@"idle"] || [mode isEqualToString:@"suwayomi"] || [mode isEqualToString:@"suwayomi-idle"];
        BOOL needsServer = [mode isEqualToString:@"suwayomi"] || [mode isEqualToString:@"suwayomi-idle"];
        NSString *serverJar = [NSBundle.mainBundle pathForResource:@"suwayomi" ofType:@"jar"];
        if (needsServer && !serverJar) {
            emit(@"BENCH_APP_FAIL missing suwayomi.jar; set SUWAYOMI_JAR at build time");
            finish(1);
            return;
        }

        char classPath[8192], home[4096], tmp[4096], warmup[128], reps[128], errorFile[4096];
        snprintf(classPath, sizeof(classPath), "-Djava.class.path=%s%s%s", jar.UTF8String,
                 needsServer ? ":" : "", needsServer ? serverJar.UTF8String : "");
        snprintf(home, sizeof(home), "-Djava.home=%s", javaHome.UTF8String);
        snprintf(tmp, sizeof(tmp), "-Djava.io.tmpdir=%s", temporary.UTF8String);
        snprintf(errorFile, sizeof(errorFile), "-XX:ErrorFile=%s/hs_err_%%p.log", temporary.UTF8String);
        snprintf(warmup, sizeof(warmup), "-Dbench.warmupMs=%s",
                 environmentValue(@"BENCH_WARMUP", @"400").UTF8String);
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
        options[count++].optionString = (char *)"-Dcom.ibm.tools.attach.enable=no";
        options[count++].optionString = (char *)"-Xms64m";
        options[count++].optionString = (char *)"-Xmx512m";
#endif

        emit([NSString stringWithFormat:@"BENCH_RUNTIME name=%@ mode=%@ jar=%@ javaHome=%@",
              kRuntimeName, mode, jar, javaHome]);
        if (![[NSFileManager defaultManager] fileExistsAtPath:javaHome]) {
            emit([NSString stringWithFormat:@"BENCH_APP_FAIL java home missing: %@", javaHome]);
            finish(1);
            return;
        }

        JavaVMInitArgs arguments;
        arguments.version = JNI_VERSION_1_8;
        arguments.nOptions = count;
        arguments.options = options;
        arguments.ignoreUnrecognized = JNI_FALSE;

        JavaVM *vm = NULL;
        JNIEnv *env = NULL;
        jint status = JNI_CreateJavaVM(&vm, (void **)&env, &arguments);
        if (status != JNI_OK || env == NULL) {
            emit([NSString stringWithFormat:@"BENCH_APP_FAIL JNI_CreateJavaVM=%d", (int)status]);
            finish(1);
            return;
        }

        jclass main = (*env)->FindClass(env, extended ? "bench/SuwayomiMain" : "bench/BenchMain");
        if (main == NULL) {
            (*env)->ExceptionDescribe(env);
            emit(@"BENCH_APP_FAIL benchmark entry class not found");
            finish(1);
            return;
        }
        if (extended) {
            JNINativeMethod methods[] = {
                {"startSampling", "()V", (void *)startSampling},
                {"stopSampling", "()V", (void *)stopSampling}
            };
            if ((*env)->RegisterNatives(env, main, methods, 2) != JNI_OK) {
                (*env)->ExceptionDescribe(env);
                emit(@"BENCH_APP_FAIL registering sampler");
                finish(1);
                return;
            }
        }
        jmethodID entry = (*env)->GetStaticMethodID(env, main, "main", "([Ljava/lang/String;)V");
        jclass stringClass = (*env)->FindClass(env, "java/lang/String");
        jobjectArray argv = (*env)->NewObjectArray(env, 1, stringClass, NULL);
        (*env)->SetObjectArrayElement(env, argv, 0, (*env)->NewStringUTF(env, mode.UTF8String));
        (*env)->CallStaticVoidMethod(env, main, entry, argv);
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env);
            emit(@"BENCH_APP_FAIL benchmark entry threw");
            finish(1);
            return;
        }
        finish(0);
    }
}

static void *startupThread(void *context) {
    (void)context;
    runJvm();
    return NULL;
}

@interface BenchAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation BenchAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    gOutput = [[UITextView alloc] initWithFrame:self.window.bounds];
    gOutput.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    gOutput.editable = NO;
    gOutput.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    controller.view = gOutput;
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    emit([NSString stringWithFormat:@"BENCH_APP_START runtime=%@", kRuntimeName]);

    // The VM takes over the thread that creates it; give it a large stack rather
    // than a GCD worker's.
    pthread_attr_t attributes;
    pthread_t thread;
    int status = pthread_attr_init(&attributes);
    if (!status) {
        status = pthread_attr_setstacksize(&attributes, 16 * 1024 * 1024);
        if (!status) status = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        if (!status) status = pthread_create(&thread, &attributes, startupThread, NULL);
        pthread_attr_destroy(&attributes);
    }
    if (status) {
        emit([NSString stringWithFormat:@"BENCH_APP_FAIL thread=%d", status]);
        finish(1);
    }
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(BenchAppDelegate.class)); }
}
