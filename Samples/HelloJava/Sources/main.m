#import <UIKit/UIKit.h>
#import <OpenJ9Kit/OpenJ9Kit.h>
#include <stdio.h>
#include <stdlib.h>

static jint JNICALL HelloNativeAdd(JNIEnv *env, jclass type, jint left, jint right) {
    (void)env;
    (void)type;
    return left + right;
}

@interface HelloAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UITextView *output;
@property (nonatomic, strong) OJ9JavaVM *vm;
@end

@implementation HelloAppDelegate
- (void)showLine:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.output.text = [self.output.text stringByAppendingFormat:@"%@\n", line];
        [self.output scrollRangeToVisible:NSMakeRange(self.output.text.length, 0)];
    });
}
- (void)fail:(NSString *)reason {
    NSString *line = [@"OPENJ9_IOS_SMOKE_FAIL: " stringByAppendingString:reason];
    [self showLine:line];
    fprintf(stderr, "%s\n", line.UTF8String);
    fflush(stderr);
    if ([NSProcessInfo.processInfo.environment[@"OPENJ9_SMOKE_EXIT"] isEqualToString:@"1"]) {
        // Give the capture queue time to mirror startup errors to simctl's console.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(1); });
    }
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    self.output = [[UITextView alloc] initWithFrame:self.window.bounds];
    self.output.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.output.editable = NO;
    self.output.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    controller.view = self.output;
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    [self showLine:@"Starting OpenJ9 Java 21…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *jar = [NSBundle.mainBundle pathForResource:@"HelloIOS" ofType:@"jar"];
        if (!jar) { [self fail:@"HelloIOS.jar is missing from the app bundle"]; return; }
        OJ9JavaVMConfiguration *configuration = [OJ9JavaVMConfiguration new];
        configuration.classPath = @[jar];
        BOOL benchmark = [NSProcessInfo.processInfo.environment[@"OPENJ9_SMOKE_BENCH"] isEqualToString:@"1"];
        // The benchmark mirrors host runs, which use a fixed 512 MiB heap.
        configuration.maxHeap = benchmark ? @"512m" : @"256m";
        NSMutableArray<NSString *> *options = [NSMutableArray array];
        NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
        for (NSArray<NSString *> *mapping in @[@[@"-Dbench.warmupMs=", @"OPENJ9_BENCH_WARMUP"],
                                               @[@"-Dbench.reps=", @"OPENJ9_BENCH_REPS"],
                                               @[@"-Dbench.only=", @"OPENJ9_BENCH_ONLY"]]) {
            NSString *value = environment[mapping[1]];
            if (value.length) [options addObject:[mapping[0] stringByAppendingString:value]];
        }
        if ([environment[@"OPENJ9_BENCH_REVERSE"] isEqualToString:@"1"]) {
            [options addObject:@"-Dbench.reverse=true"];
        }
        configuration.options = options;
        __weak HelloAppDelegate *weakSelf = self;
        configuration.outputHandler = ^(NSString *line, BOOL standardError) {
            (void)standardError;
            [weakSelf showLine:line];
            BOOL benchDone = [line isEqualToString:@"OPENJ9_IOS_BENCH_OK"];
            if ([NSProcessInfo.processInfo.environment[@"OPENJ9_SMOKE_EXIT"] isEqualToString:@"1"] &&
                ([line isEqualToString:@"OPENJ9_IOS_SMOKE_OK"] || benchDone || [line hasPrefix:@"OPENJ9_IOS_SMOKE_FAIL:"])) {
                // The output capture mirrors the marker before invoking this handler.
                int status = ([line isEqualToString:@"OPENJ9_IOS_SMOKE_OK"] || benchDone) ? 0 : 1;
                dispatch_async(dispatch_get_main_queue(), ^{ exit(status); });
            }
        };
        NSError *error;
        self.vm = [OJ9JavaVM startWithConfiguration:configuration error:&error];
        if (!self.vm) { [self fail:error.localizedDescription]; return; }
        if (!benchmark) {
            __block BOOL registered = NO;
            [self.vm performWithEnv:^(JNIEnv *env) {
                jclass type = (*env)->FindClass(env, "HelloIOS");
                JNINativeMethod methods[] = {{"nativeAdd", "(II)I", (void *)&HelloNativeAdd}};
                if (type) registered = (*env)->RegisterNatives(env, type, methods, 1) == JNI_OK;
                if ((*env)->ExceptionCheck(env)) {
                    (*env)->ExceptionDescribe(env);
                    (*env)->ExceptionClear(env);
                }
            }];
            if (!registered) { [self fail:@"Could not RegisterNatives for HelloIOS.nativeAdd"]; return; }
        }
        if (benchmark) {
            [self.vm runMainClass:@"Bench" arguments:@[] completionQueue:dispatch_get_main_queue()
                      completion:^(int status, NSError *failure) {
                if (status) [self fail:failure.localizedDescription ?: @"benchmark failed"];
            }];
            return;
        }
        NSString *desktop = NSProcessInfo.processInfo.environment[@"OPENJ9_SMOKE_DESKTOP"] ?: @"headless";
        [self.vm runMainClass:@"HelloIOS" arguments:@[desktop] completionQueue:dispatch_get_main_queue()
                  completion:^(int status, NSError *failure) {
            if (status) [self fail:failure.localizedDescription ?: @"main failed"];
        }];
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(HelloAppDelegate.class)); }
}
