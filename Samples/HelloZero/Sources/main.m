// Minimal host for the static HotSpot Zero VM (openjdk/mobile, zero variant).
//
// The VM is linked into this binary, so HotSpot derives java.home from the
// executable's directory; the jlinked image is copied to <bundle>/lib and the
// benchmark jar to <bundle>/Bench.jar. Benchmark output goes to stdout, which
// `simctl launch --console-pty` relays.
#import <UIKit/UIKit.h>
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void report(NSString *message) {
    fprintf(stderr, "ZERO_IOS_FAIL: %s\n", message.UTF8String);
    fflush(stderr);
    exit(1);
}

static void runBenchmark(void) {
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *jar = [NSBundle.mainBundle pathForResource:@"Bench" ofType:@"jar"];
    if (!jar) report(@"Bench.jar is missing from the app bundle");
    NSString *javaHome = [bundle stringByAppendingPathComponent:@"lib"];
    NSString *temporary = NSTemporaryDirectory();

    char classPath[4096], homeOption[4096], tempOption[4096], errorFile[4096];
    snprintf(classPath, sizeof(classPath), "-Djava.class.path=%s", jar.UTF8String);
    snprintf(homeOption, sizeof(homeOption), "-Djava.home=%s", javaHome.UTF8String);
    snprintf(tempOption, sizeof(tempOption), "-Djava.io.tmpdir=%s", temporary.UTF8String);
    snprintf(errorFile, sizeof(errorFile), "-XX:ErrorFile=%s/hs_err_%%p.log", temporary.UTF8String);

    // Same runtime options the shipping moeReader app uses for this VM: Zero is
    // interpreter-only and iOS forbids writable-executable memory, so the VM
    // must never try to reserve an executable code cache. Attach and perf-data
    // are disabled because both assume a writable /tmp.
    JavaVMOption options[] = {
        {classPath, NULL},
        {homeOption, NULL},
        {tempOption, NULL},
        {errorFile, NULL},
        {(char *)"-Xint", NULL},
        {(char *)"-Xshare:off", NULL},
        {(char *)"-XX:+UseSerialGC", NULL},
        {(char *)"-Xms64m", NULL},
        {(char *)"-Xmx512m", NULL},
        {(char *)"-Xss4m", NULL},
        {(char *)"-XX:+DisableAttachMechanism", NULL},
        {(char *)"-XX:-UsePerfData", NULL},
    };
    fprintf(stderr, "ZERO_IOS_START jar=%s home=%s\n", jar.UTF8String, javaHome.UTF8String);
    fflush(stderr);

    JavaVMInitArgs arguments;
    arguments.version = JNI_VERSION_1_8;
    arguments.nOptions = (jint)(sizeof(options) / sizeof(options[0]));
    arguments.options = options;
    arguments.ignoreUnrecognized = JNI_FALSE;

    JavaVM *vm = NULL;
    JNIEnv *env = NULL;
    jint status = JNI_CreateJavaVM(&vm, (void **)&env, &arguments);
    if (status != JNI_OK || env == NULL) {
        char message[128];
        snprintf(message, sizeof(message), "JNI_CreateJavaVM failed (%d)", (int)status);
        report([NSString stringWithUTF8String:message]);
    }
    jclass bench = (*env)->FindClass(env, "Bench");
    if (bench == NULL || (*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        report(@"Bench class was not found");
    }
    jmethodID main = (*env)->GetStaticMethodID(env, bench, "main", "([Ljava/lang/String;)V");
    if (main == NULL) {
        (*env)->ExceptionDescribe(env);
        report(@"Bench.main was not found");
    }
    (*env)->CallStaticVoidMethod(env, bench, main, NULL);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        report(@"Bench.main threw");
    }
    fflush(stdout);
    // A deterministic end marker lets the caller distinguish "finished" from
    // "killed", independent of the Java-side completion marker.
    fprintf(stdout, "ZERO_IOS_BENCH_DONE\n");
    fflush(stdout);
    exit(0);
}

@interface ZeroAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ZeroAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool { runBenchmark(); }
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ZeroAppDelegate.class)); }
}
