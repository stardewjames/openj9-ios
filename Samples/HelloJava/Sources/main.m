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
        configuration.maxHeap = @"256m";
        __weak HelloAppDelegate *weakSelf = self;
        configuration.outputHandler = ^(NSString *line, BOOL standardError) {
            (void)standardError;
            [weakSelf showLine:line];
            if ([NSProcessInfo.processInfo.environment[@"OPENJ9_SMOKE_EXIT"] isEqualToString:@"1"] &&
                ([line isEqualToString:@"OPENJ9_IOS_SMOKE_OK"] || [line hasPrefix:@"OPENJ9_IOS_SMOKE_FAIL:"])) {
                // The output capture mirrors the marker before invoking this handler.
                int status = [line isEqualToString:@"OPENJ9_IOS_SMOKE_OK"] ? 0 : 1;
                dispatch_async(dispatch_get_main_queue(), ^{ exit(status); });
            }
        };
        NSError *error;
        self.vm = [OJ9JavaVM startWithConfiguration:configuration error:&error];
        if (!self.vm) { [self fail:error.localizedDescription]; return; }
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
        [self.vm runMainClass:@"HelloIOS" arguments:@[] completionQueue:dispatch_get_main_queue()
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
