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

        char classPath[4096], home[4096], tmp[4096], warmup[128], reps[128], errorFile[4096];
        snprintf(classPath, sizeof(classPath), "-Djava.class.path=%s", jar.UTF8String);
        snprintf(home, sizeof(home), "-Djava.home=%s", javaHome.UTF8String);
        snprintf(tmp, sizeof(tmp), "-Djava.io.tmpdir=%s", temporary.UTF8String);
        snprintf(errorFile, sizeof(errorFile), "-XX:ErrorFile=%s/hs_err_%%p.log", temporary.UTF8String);
        snprintf(warmup, sizeof(warmup), "-Dbench.warmupMs=%s",
                 environmentValue(@"BENCH_WARMUP", @"400").UTF8String);
        snprintf(reps, sizeof(reps), "-Dbench.reps=%s", environmentValue(@"BENCH_REPS", @"5").UTF8String);

        JavaVMOption options[12];
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

        jclass main = (*env)->FindClass(env, "bench/BenchMain");
        if (main == NULL) {
            (*env)->ExceptionDescribe(env);
            emit(@"BENCH_APP_FAIL class bench.BenchMain not found");
            finish(1);
            return;
        }
        jmethodID entry = (*env)->GetStaticMethodID(env, main, "main", "([Ljava/lang/String;)V");
        jclass stringClass = (*env)->FindClass(env, "java/lang/String");
        jobjectArray argv = (*env)->NewObjectArray(env, 1, stringClass, NULL);
        (*env)->SetObjectArrayElement(env, argv, 0, (*env)->NewStringUTF(env, mode.UTF8String));
        (*env)->CallStaticVoidMethod(env, main, entry, argv);
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env);
            emit(@"BENCH_APP_FAIL BenchMain threw");
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
