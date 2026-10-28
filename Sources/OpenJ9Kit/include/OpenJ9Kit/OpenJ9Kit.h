#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <jni.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const OJ9JavaVMErrorDomain;
typedef void (^OJ9OutputHandler)(NSString *line, BOOL standardError);
typedef void (^OJ9ExitHandler)(int status);

NS_SWIFT_NAME(OpenJ9VMConfiguration)
@interface OJ9JavaVMConfiguration : NSObject <NSCopying>
@property (nonatomic, copy) NSArray<NSString *> *classPath;
@property (nonatomic, copy) NSArray<NSString *> *options;
@property (nonatomic, copy) NSString *maxHeap; // Default: 512m.
@property (nonatomic, copy) NSString *threadStackSize; // Java -Xss; default: 2m.
@property (nonatomic, copy, nullable) NSString *javaHome;
// Called on arbitrary VM threads, never with the output lock held. Dispatch UI work yourself.
@property (nonatomic, copy, nullable) OJ9OutputHandler outputHandler;
// Notification before process termination, NOT an interception of System.exit.
// Must not call Java or throw. If it returns, the hook calls exit(status).
@property (nonatomic, copy, nullable) OJ9ExitHandler exitHandler;
@end

NS_SWIFT_NAME(OpenJ9VM)
@interface OJ9JavaVM : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
// One startup attempt per process, including failed attempts. No destroy/restart API.
// Creates the VM on a dedicated 16 MiB pthread; this method waits for startup.
+ (nullable instancetype)startWithConfiguration:(OJ9JavaVMConfiguration *)configuration
                                        error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(start(configuration:));
@property (nonatomic, readonly) JavaVM *javaVM;
// Synchronous on the dedicated Java thread. Returns 0, or -1 with an NSError.
- (int)runMainClass:(NSString *)className
         arguments:(NSArray<NSString *> *)arguments
             error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(runMain(className:arguments:)) __attribute__((swift_error(nonnull_error)));
- (void)runMainClass:(NSString *)className
          arguments:(NSArray<NSString *> *)arguments
    completionQueue:(dispatch_queue_t)queue
         completion:(void (^)(int status, NSError * _Nullable error))completion
    NS_SWIFT_NAME(runMain(className:arguments:completionQueue:completion:));
// JNIEnv is valid ONLY on the calling thread. Existing attachments are borrowed;
// only attachments made by this kit are detached here or by its pthread TLS destructor.
- (nullable JNIEnv *)attachCurrentThread;
- (void)detachCurrentThread;
// Synchronous, reentrant on the Java thread, with a scoped JNI local frame.
// Do not retain env/local refs, throw ObjC exceptions, or leave a pending Java exception.
- (void)performWithEnv:(void (^)(JNIEnv *env))block NS_SWIFT_NAME(performWithEnv(_:));
@end

NS_ASSUME_NONNULL_END
