#import <OpenJ9Kit/OpenJ9Kit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <os/log.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

NSErrorDomain const OJ9JavaVMErrorDomain = @"org.openj9.ios.embedding";
static OJ9JavaVM *processVM; // Deliberately retained for the process lifetime.
static BOOL startupAttempted;
static pthread_mutex_t startupLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_key_t attachmentKey;
static pthread_once_t attachmentOnce = PTHREAD_ONCE_INIT;
static void OJ9KeepRunLoopAlive(void *context) { (void)context; }

static NSError *OJ9Error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:OJ9JavaVMErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation OJ9JavaVMConfiguration
- (instancetype)init {
    if ((self = [super init])) {
        _classPath = @[];
        _options = @[];
        _maxHeap = @"512m";
        _threadStackSize = @"2m";
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone {
    OJ9JavaVMConfiguration *copy = [[[self class] allocWithZone:zone] init];
    copy.classPath = self.classPath;
    copy.options = self.options;
    copy.maxHeap = self.maxHeap;
    copy.threadStackSize = self.threadStackSize;
    copy.javaHome = self.javaHome;
    copy.outputHandler = self.outputHandler;
    copy.exitHandler = self.exitHandler;
    return copy;
}
@end

@interface OJ9JavaVM () {
    JavaVM *_javaVM;
    JNIEnv *_workerEnv;
    pthread_t _thread;
    CFRunLoopRef _runLoop;
    dispatch_semaphore_t _started;
    NSError *_startupError;
    OJ9JavaVMConfiguration *_configuration;
    NSLock *_outputLock;
    NSMutableData *_stdoutPending;
    NSMutableData *_stderrPending;
    dispatch_source_t _stdoutSource;
    dispatch_source_t _stderrSource;
}
- (instancetype)initPrivateWithConfiguration:(OJ9JavaVMConfiguration *)configuration;
- (void)javaThreadMain;
- (void)execute:(dispatch_block_t)block;
- (BOOL)installOutputCapture;
- (void)receiveBytes:(const void *)bytes length:(NSUInteger)length standardError:(BOOL)standardError;
- (int)capture:(FILE *)stream format:(const char *)format arguments:(va_list)arguments;
- (void)notifyExit:(int)status;
@end

static void OJ9DetachOwnedThread(void *value) {
    JavaVM *vm = value;
    if (vm) (*vm)->DetachCurrentThread(vm);
}
static void OJ9MakeAttachmentKey(void) {
    // Never attach a thread without a lifetime owner.
    if (pthread_key_create(&attachmentKey, OJ9DetachOwnedThread) != 0) abort();
}
static void *OJ9JavaThread(void *context) {
    @autoreleasepool {
        OJ9JavaVM *vm = (__bridge OJ9JavaVM *)context;
        [vm javaThreadMain];
    }
    return NULL;
}
static int JNICALL OJ9Vfprintf(FILE *stream, const char *format, va_list arguments) {
    @autoreleasepool { return [processVM capture:stream format:format arguments:arguments]; }
}
static void JNICALL OJ9Exit(jint status) {
    @autoreleasepool { [processVM notifyExit:status]; }
    // OpenJ9's exit hook is not a resumable exception boundary. Never return to Java.
    exit(status);
}

static NSString *OJ9String(JNIEnv *env, jstring string) {
    if (!string) return nil;
    const jchar *chars = (*env)->GetStringChars(env, string, NULL);
    if (!chars) return nil;
    NSString *result = [[NSString alloc] initWithCharacters:(const unichar *)chars
                                                   length:(NSUInteger)(*env)->GetStringLength(env, string)];
    (*env)->ReleaseStringChars(env, string, chars);
    return result;
}
static jstring OJ9NewString(JNIEnv *env, NSString *string) {
    NSUInteger length = string.length;
    if (length > INT32_MAX) return NULL;
    unichar *chars = length ? malloc(length * sizeof(unichar)) : NULL;
    if (length && !chars) return NULL;
    [string getCharacters:chars range:NSMakeRange(0, length)];
    jstring result = (*env)->NewString(env, (const jchar *)chars, (jsize)length);
    free(chars);
    return result;
}

// Called with a pending exception, inside a local frame; always clears all exceptions.
static NSError *OJ9JavaException(JNIEnv *env) {
    jthrowable exception = (*env)->ExceptionOccurred(env);
    if (!exception) return nil;
    (*env)->ExceptionClear(env);
    NSString *text = @"Java exception (stack trace unavailable)";
    jclass throwable = (*env)->FindClass(env, "java/lang/Throwable");
    jclass sw = (*env)->ExceptionCheck(env) ? NULL : (*env)->FindClass(env, "java/io/StringWriter");
    jclass pw = (*env)->ExceptionCheck(env) ? NULL : (*env)->FindClass(env, "java/io/PrintWriter");
    if (throwable && sw && pw && !(*env)->ExceptionCheck(env)) {
        jmethodID swInit = (*env)->GetMethodID(env, sw, "<init>", "()V");
        jmethodID pwInit = (*env)->ExceptionCheck(env) ? NULL : (*env)->GetMethodID(env, pw, "<init>", "(Ljava/io/Writer;)V");
        jmethodID print = (*env)->ExceptionCheck(env) ? NULL : (*env)->GetMethodID(env, throwable, "printStackTrace", "(Ljava/io/PrintWriter;)V");
        jmethodID toString = (*env)->ExceptionCheck(env) ? NULL : (*env)->GetMethodID(env, sw, "toString", "()Ljava/lang/String;");
        if (swInit && pwInit && print && toString && !(*env)->ExceptionCheck(env)) {
            jobject writer = (*env)->NewObject(env, sw, swInit);
            jobject printer = writer && !(*env)->ExceptionCheck(env) ? (*env)->NewObject(env, pw, pwInit, writer) : NULL;
            if (printer && !(*env)->ExceptionCheck(env)) {
                (*env)->CallVoidMethod(env, exception, print, printer);
                if (!(*env)->ExceptionCheck(env)) {
                    jstring trace = (*env)->CallObjectMethod(env, writer, toString);
                    if (!(*env)->ExceptionCheck(env)) text = OJ9String(env, trace) ?: text;
                }
            }
        }
    }
    (*env)->ExceptionClear(env);
    return OJ9Error(-1, text);
}

@implementation OJ9JavaVM
- (instancetype)initPrivateWithConfiguration:(OJ9JavaVMConfiguration *)configuration {
    if ((self = [super init])) {
        _configuration = [configuration copy];
        _started = dispatch_semaphore_create(0);
        _outputLock = [NSLock new];
        _stdoutPending = [NSMutableData new];
        _stderrPending = [NSMutableData new];
    }
    return self;
}
+ (instancetype)startWithConfiguration:(OJ9JavaVMConfiguration *)configuration error:(NSError **)error {
    pthread_mutex_lock(&startupLock);
    if (startupAttempted) {
        pthread_mutex_unlock(&startupLock);
        if (error) *error = OJ9Error(-1, @"Only one JVM startup attempt is supported per process.");
        return nil;
    }
    startupAttempted = YES;
    OJ9JavaVM *vm = [[self alloc] initPrivateWithConfiguration:configuration];
    processVM = vm; // Hooks may run before JNI_CreateJavaVM returns.
    pthread_mutex_unlock(&startupLock);

    pthread_attr_t attributes;
    int status = pthread_attr_init(&attributes);
    if (!status) {
        status = pthread_attr_setstacksize(&attributes, 16 * 1024 * 1024);
        if (!status) status = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        if (!status) status = pthread_create(&vm->_thread, &attributes, OJ9JavaThread, (__bridge void *)vm);
        pthread_attr_destroy(&attributes);
    }
    if (status) {
        if (error) *error = OJ9Error(status, @"Could not create the dedicated Java thread.");
        return nil;
    }
    dispatch_semaphore_wait(vm->_started, DISPATCH_TIME_FOREVER);
    if (vm->_startupError) {
        if (error) *error = vm->_startupError;
        return nil;
    }
    return vm;
}
- (JavaVM *)javaVM { return _javaVM; }
- (void)javaThreadMain {
    pthread_setname_np("OpenJ9 Java");
    NSString *home = _configuration.javaHome;
    if (!home) {
        Dl_info info = {0};
        if (dladdr((const void *)&JNI_CreateJavaVM, &info) && info.dli_fname) {
            home = [[NSString stringWithUTF8String:info.dli_fname].stringByDeletingLastPathComponent
                    stringByAppendingPathComponent:@"javahome"];
        }
    }
    if (!home || ![[NSFileManager defaultManager] fileExistsAtPath:[home stringByAppendingPathComponent:@"lib/modules"]]) {
        _startupError = OJ9Error(-1, @"javaHome must contain lib/modules (normally jvm.framework/javahome).");
        dispatch_semaphore_signal(_started);
        return;
    }
    if (![self installOutputCapture]) {
        _startupError = OJ9Error(errno, @"Cannot install stdout/stderr capture.");
        dispatch_semaphore_signal(_started);
        return;
    }
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSHomeDirectory();
    NSMutableArray<NSString *> *strings = [NSMutableArray arrayWithArray:@[
        [@"-Djava.home=" stringByAppendingString:home],
        [@"-Djava.class.path=" stringByAppendingString:[_configuration.classPath componentsJoinedByString:@":"]],
        [@"-Djava.io.tmpdir=" stringByAppendingString:NSTemporaryDirectory()],
        [@"-Duser.home=" stringByAppendingString:NSHomeDirectory()],
        [@"-Duser.dir=" stringByAppendingString:documents],
        [@"-Xdump:directory=" stringByAppendingString:NSTemporaryDirectory()],
        @"-Xshareclasses:none", @"-Dcom.ibm.tools.attach.enable=no", @"-Xint",
        [@"-Xmx" stringByAppendingString:_configuration.maxHeap],
        [@"-Xss" stringByAppendingString:_configuration.threadStackSize]
    ]];
    [strings addObjectsFromArray:_configuration.options];
    JavaVMOption *options = calloc(strings.count + 2, sizeof(JavaVMOption));
    if (!options) {
        _startupError = OJ9Error(JNI_ENOMEM, @"Cannot allocate JVM options.");
        dispatch_semaphore_signal(_started);
        return;
    }
    // NSString objects remain alive throughout JNI_CreateJavaVM.
    for (NSUInteger i = 0; i < strings.count; ++i) options[i].optionString = (char *)strings[i].UTF8String;
    options[strings.count].optionString = "vfprintf";
    options[strings.count].extraInfo = (void *)&OJ9Vfprintf;
    options[strings.count + 1].optionString = "exit";
    options[strings.count + 1].extraInfo = (void *)&OJ9Exit;
    JavaVMInitArgs args = { .version = JNI_VERSION_1_8, .nOptions = (jint)strings.count + 2,
                           .options = options, .ignoreUnrecognized = JNI_FALSE };
    jint status = JNI_CreateJavaVM(&_javaVM, (void **)&_workerEnv, &args);
    free(options);
    if (status != JNI_OK) {
        _startupError = OJ9Error(status, [NSString stringWithFormat:@"JNI_CreateJavaVM failed: %d", status]);
        dispatch_semaphore_signal(_started);
        return;
    }
    _runLoop = CFRunLoopGetCurrent();
    CFRetain(_runLoop);
    // A source keeps the run loop alive even when there are no queued jobs.
    CFRunLoopSourceContext context = { .perform = OJ9KeepRunLoopAlive };
    CFRunLoopSourceRef source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
    CFRunLoopAddSource(_runLoop, source, kCFRunLoopDefaultMode);
    CFRelease(source);
    dispatch_semaphore_signal(_started);
    for (;;) {
        @autoreleasepool { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3600, false); }
    }
}
- (void)execute:(dispatch_block_t)block {
    if (pthread_equal(pthread_self(), _thread)) { block(); return; }
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    CFRunLoopPerformBlock(_runLoop, kCFRunLoopDefaultMode, ^{
        @autoreleasepool { block(); }
        dispatch_semaphore_signal(finished);
    });
    CFRunLoopWakeUp(_runLoop);
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
}
- (JNIEnv *)attachCurrentThread {
    JNIEnv *env = NULL;
    jint status = (*_javaVM)->GetEnv(_javaVM, (void **)&env, JNI_VERSION_1_8);
    if (status == JNI_OK) return env;
    if (status != JNI_EDETACHED) return NULL;
    pthread_once(&attachmentOnce, OJ9MakeAttachmentKey);
    if ((*_javaVM)->AttachCurrentThreadAsDaemon(_javaVM, (void **)&env, NULL) != JNI_OK) return NULL;
    if (pthread_setspecific(attachmentKey, _javaVM)) {
        (*_javaVM)->DetachCurrentThread(_javaVM);
        return NULL;
    }
    return env;
}
- (void)detachCurrentThread {
    pthread_once(&attachmentOnce, OJ9MakeAttachmentKey);
    if (pthread_getspecific(attachmentKey) == _javaVM) {
        if ((*_javaVM)->DetachCurrentThread(_javaVM) == JNI_OK) pthread_setspecific(attachmentKey, NULL);
    }
}
- (void)performWithEnv:(void (^)(JNIEnv *))block {
    [self execute:^{
        if ((*self->_workerEnv)->PushLocalFrame(self->_workerEnv, 64) != JNI_OK) {
            (*self->_workerEnv)->ExceptionDescribe(self->_workerEnv);
            (*self->_workerEnv)->ExceptionClear(self->_workerEnv);
            return;
        }
        block(self->_workerEnv);
        (*self->_workerEnv)->PopLocalFrame(self->_workerEnv, NULL);
    }];
}
- (int)runMainClass:(NSString *)className arguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    __block NSError *failure;
    NSString *name = [className stringByReplacingOccurrencesOfString:@"." withString:@"/"];
    NSArray<NSString *> *copiedArguments = [arguments copy];
    [self execute:^{
        JNIEnv *env = self->_workerEnv;
        if ((*env)->PushLocalFrame(env, 64) != JNI_OK) {
            failure = OJ9JavaException(env) ?: OJ9Error(-1, @"Cannot create JNI local frame.");
            return;
        }
        jclass mainClass = (*env)->FindClass(env, name.UTF8String);
        jmethodID mainMethod = mainClass ? (*env)->GetStaticMethodID(env, mainClass, "main", "([Ljava/lang/String;)V") : NULL;
        jclass stringClass = mainMethod ? (*env)->FindClass(env, "java/lang/String") : NULL;
        jobjectArray array = stringClass ? (*env)->NewObjectArray(env, (jsize)copiedArguments.count, stringClass, NULL) : NULL;
        if (array && !(*env)->ExceptionCheck(env)) {
            for (NSUInteger i = 0; i < copiedArguments.count; ++i) {
                jstring value = OJ9NewString(env, copiedArguments[i]);
                if (!value) {
                    failure = OJ9JavaException(env) ?: OJ9Error(JNI_ENOMEM, @"Cannot allocate Java argument string.");
                    break;
                }
                (*env)->SetObjectArrayElement(env, array, (jsize)i, value);
                (*env)->DeleteLocalRef(env, value);
                if ((*env)->ExceptionCheck(env)) break;
            }
            if (!failure && !(*env)->ExceptionCheck(env)) (*env)->CallStaticVoidMethod(env, mainClass, mainMethod, array);
        }
        failure = OJ9JavaException(env) ?: failure;
        if (!failure && !array) failure = OJ9Error(-1, @"Cannot prepare Java main arguments.");
        (*env)->PopLocalFrame(env, NULL);
    }];
    if (failure && error) *error = failure;
    return failure ? -1 : 0;
}
- (void)runMainClass:(NSString *)className arguments:(NSArray<NSString *> *)arguments completionQueue:(dispatch_queue_t)queue completion:(void (^)(int, NSError *))completion {
    NSString *name = [className copy];
    NSArray<NSString *> *args = [arguments copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error;
        int status = [self runMainClass:name arguments:args error:&error];
        dispatch_async(queue, ^{ completion(status, error); });
    });
}
- (int)capture:(FILE *)stream format:(const char *)format arguments:(va_list)arguments {
    char *buffer = NULL;
    int count = vasprintf(&buffer, format, arguments);
    if (count < 0) return count;
    int descriptor = stream == stderr ? STDERR_FILENO : STDOUT_FILENO;
    const char *remaining = buffer;
    size_t left = (size_t)count;
    while (left) {
        ssize_t written = write(descriptor, remaining, left);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) break;
        remaining += written;
        left -= (size_t)written;
    }
    free(buffer);
    return count;
}
- (BOOL)installOutputCapture {
    // The JNI vfprintf hook covers VM diagnostics, not all System.out writes.
    // Redirect both process descriptors as well, and mirror to the original console.
    int pipes[2][2] = {{-1, -1}, {-1, -1}};
    int saved[2] = {dup(STDOUT_FILENO), dup(STDERR_FILENO)};
    BOOL ready = saved[0] >= 0 && saved[1] >= 0;
    for (int i = 0; ready && i < 2; ++i) {
        ready = pipe(pipes[i]) == 0;
        if (ready) ready = fcntl(pipes[i][0], F_SETFL, O_NONBLOCK) == 0;
    }
    if (ready) ready = dup2(pipes[0][1], STDOUT_FILENO) >= 0 && dup2(pipes[1][1], STDERR_FILENO) >= 0;
    if (!ready) {
        int failure = errno;
        for (int i = 0; i < 2; ++i) {
            if (saved[i] >= 0) { dup2(saved[i], i == 0 ? STDOUT_FILENO : STDERR_FILENO); close(saved[i]); }
            if (pipes[i][0] >= 0) close(pipes[i][0]);
            if (pipes[i][1] >= 0) close(pipes[i][1]);
        }
        errno = failure;
        return NO;
    }
    dispatch_queue_t outputQueue = dispatch_queue_create("org.openj9.ios.output", DISPATCH_QUEUE_SERIAL);
    for (int i = 0; i < 2; ++i) {
        close(pipes[i][1]);
        int input = pipes[i][0], console = saved[i];
        BOOL standardError = i == 1;
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)input, 0, outputQueue);
        dispatch_source_set_event_handler(source, ^{
            char bytes[4096];
            ssize_t count;
            while ((count = read(input, bytes, sizeof(bytes))) > 0) {
                size_t left = (size_t)count;
                const char *cursor = bytes;
                while (left) {
                    ssize_t written = write(console, cursor, left);
                    if (written < 0 && errno == EINTR) continue;
                    if (written <= 0) break;
                    cursor += written;
                    left -= (size_t)written;
                }
                [self receiveBytes:bytes length:(NSUInteger)count standardError:standardError];
            }
        });
        if (i == 0) _stdoutSource = source; else _stderrSource = source;
        dispatch_resume(source);
    }
    return YES;
}
- (void)receiveBytes:(const void *)bytes length:(NSUInteger)length standardError:(BOOL)standardError {
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    [_outputLock lock];
    NSMutableData *pending = standardError ? _stderrPending : _stdoutPending;
    [pending appendBytes:bytes length:length];
    const unsigned char *data = pending.bytes;
    NSUInteger consumed = 0;
    for (NSUInteger i = 0; i < pending.length; ++i) {
        if (data[i] == '\n') {
            NSData *line = [pending subdataWithRange:NSMakeRange(consumed, i - consumed)];
            NSString *text = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding]
                ?: [[NSString alloc] initWithData:line encoding:NSISOLatin1StringEncoding];
            [lines addObject:text];
            consumed = i + 1;
        }
    }
    if (consumed) [pending replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
    [_outputLock unlock];
    for (NSString *line in lines) {
        os_log_with_type(OS_LOG_DEFAULT, standardError ? OS_LOG_TYPE_ERROR : OS_LOG_TYPE_DEFAULT, "%{public}@", line);
        if (_configuration.outputHandler) _configuration.outputHandler(line, standardError);
    }
}
- (void)notifyExit:(int)status {
    if (_configuration.exitHandler) _configuration.exitHandler(status);
}
@end
