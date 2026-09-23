#import "DYYYCrashLogger.h"
#import "DYYYConstants.h"

#import <UIKit/UIKit.h>
#import <execinfo.h>
#import <fcntl.h>
#import <signal.h>
#import <stdatomic.h>
#import <string.h>
#import <sys/stat.h>
#import <time.h>
#import <unistd.h>

static const size_t kDYYYCrashLoggerMaxFileSize = 512 * 1024;
static const int kDYYYCrashLoggerMaxFrames = 32;

static atomic_bool gDYYYCrashLoggerInstalled = false;
static int gDYYYCrashLogFD = -1;
static char gDYYYCrashLogPath[1024];
static char gDYYYCrashStage[160];
static char gDYYYCrashVersion[32];
static NSUncaughtExceptionHandler *gDYYYPreviousExceptionHandler = NULL;
static struct sigaction gDYYYPreviousSignalActions[NSIG];

static void DYYYCrashLoggerHandleSignal(int signalNumber, siginfo_t *info, void *context);
static void DYYYCrashLoggerHandleException(NSException *exception);

static void DYYYCrashLoggerWriteRaw(const char *bytes, size_t length) {
    if (!bytes || length == 0 || gDYYYCrashLogFD < 0) {
        return;
    }
    write(gDYYYCrashLogFD, bytes, length);
}

static void DYYYCrashLoggerWriteCString(const char *string) {
    if (!string) {
        return;
    }
    DYYYCrashLoggerWriteRaw(string, strlen(string));
}

static void DYYYCrashLoggerWriteUnsigned(unsigned long long value) {
    char buffer[32];
    int length = snprintf(buffer, sizeof(buffer), "%llu", value);
    if (length > 0) {
        DYYYCrashLoggerWriteRaw(buffer, (size_t)length);
    }
}

static void DYYYCrashLoggerWriteHexPointer(const void *pointer) {
    char buffer[32];
    int length = snprintf(buffer, sizeof(buffer), "%p", pointer);
    if (length > 0) {
        DYYYCrashLoggerWriteRaw(buffer, (size_t)length);
    }
}

static void DYYYCrashLoggerFlush(void) {
    if (gDYYYCrashLogFD >= 0) {
        fsync(gDYYYCrashLogFD);
    }
}

static const char *DYYYCrashLoggerSignalName(int signalNumber) {
    switch (signalNumber) {
        case SIGABRT:
            return "SIGABRT";
        case SIGBUS:
            return "SIGBUS";
        case SIGFPE:
            return "SIGFPE";
        case SIGILL:
            return "SIGILL";
        case SIGSEGV:
            return "SIGSEGV";
        case SIGTRAP:
            return "SIGTRAP";
        default:
            return "UNKNOWN";
    }
}

static BOOL DYYYCrashLoggerResolvePath(void) {
    const char *home = getenv("HOME");
    if (!home || home[0] == '\0') {
        NSString *homePath = NSHomeDirectory();
        home = homePath.UTF8String;
    }
    if (!home || home[0] == '\0') {
        return NO;
    }

    char directory[sizeof(gDYYYCrashLogPath)];
    int directoryLength = snprintf(directory, sizeof(directory), "%s/Documents/DYYY", home);
    if (directoryLength <= 0 || (size_t)directoryLength >= sizeof(directory)) {
        return NO;
    }
    mkdir(directory, 0755);

    int pathLength = snprintf(gDYYYCrashLogPath, sizeof(gDYYYCrashLogPath), "%s/crash.log", directory);
    return pathLength > 0 && (size_t)pathLength < sizeof(gDYYYCrashLogPath);
}

static void DYYYCrashLoggerOpenFile(void) {
    if (gDYYYCrashLogFD >= 0 || gDYYYCrashLogPath[0] == '\0') {
        return;
    }

    struct stat fileInfo;
    if (stat(gDYYYCrashLogPath, &fileInfo) == 0 && (size_t)fileInfo.st_size > kDYYYCrashLoggerMaxFileSize) {
        unlink(gDYYYCrashLogPath);
    }

    gDYYYCrashLogFD = open(gDYYYCrashLogPath, O_CREAT | O_WRONLY | O_APPEND, 0644);
}

static void DYYYCrashLoggerWriteHeader(const char *type) {
    DYYYCrashLoggerWriteCString("\n===== DYYY CRASH =====\n");
    DYYYCrashLoggerWriteCString("time=");
    DYYYCrashLoggerWriteUnsigned((unsigned long long)time(NULL));
    DYYYCrashLoggerWriteCString("\nversion=");
    DYYYCrashLoggerWriteCString(gDYYYCrashVersion[0] ? gDYYYCrashVersion : "unknown");
    DYYYCrashLoggerWriteCString("\nstage=");
    DYYYCrashLoggerWriteCString(gDYYYCrashStage[0] ? gDYYYCrashStage : "unknown");
    DYYYCrashLoggerWriteCString("\ntype=");
    DYYYCrashLoggerWriteCString(type ?: "unknown");
    DYYYCrashLoggerWriteCString("\n");
}

static void DYYYCrashLoggerWriteFooter(void) {
    DYYYCrashLoggerWriteCString("===== END =====\n");
    DYYYCrashLoggerFlush();
}

static void DYYYCrashLoggerWriteBacktrace(void) {
    void *frames[kDYYYCrashLoggerMaxFrames];
    int frameCount = backtrace(frames, kDYYYCrashLoggerMaxFrames);
    DYYYCrashLoggerWriteCString("frames=");
    DYYYCrashLoggerWriteUnsigned((unsigned long long)frameCount);
    DYYYCrashLoggerWriteCString("\n");
    for (int index = 0; index < frameCount; index++) {
        DYYYCrashLoggerWriteCString("  ");
        DYYYCrashLoggerWriteHexPointer(frames[index]);
        DYYYCrashLoggerWriteCString("\n");
    }
}

static void DYYYCrashLoggerHandleException(NSException *exception) {
    DYYYCrashLoggerOpenFile();
    DYYYCrashLoggerWriteHeader("NSException");
    DYYYCrashLoggerWriteCString("name=");
    DYYYCrashLoggerWriteCString(exception.name.UTF8String ?: "");
    DYYYCrashLoggerWriteCString("\nreason=");
    DYYYCrashLoggerWriteCString(exception.reason.UTF8String ?: "");
    DYYYCrashLoggerWriteCString("\n");

    NSArray<NSString *> *symbols = exception.callStackSymbols;
    DYYYCrashLoggerWriteCString("stack=\n");
    for (NSString *symbol in symbols) {
        DYYYCrashLoggerWriteCString("  ");
        DYYYCrashLoggerWriteCString(symbol.UTF8String ?: "");
        DYYYCrashLoggerWriteCString("\n");
    }
    DYYYCrashLoggerWriteFooter();

    if (gDYYYPreviousExceptionHandler) {
        gDYYYPreviousExceptionHandler(exception);
    }
}

static void DYYYCrashLoggerHandleSignal(int signalNumber, siginfo_t *info, void *context) {
    DYYYCrashLoggerOpenFile();
    DYYYCrashLoggerWriteHeader("signal");
    DYYYCrashLoggerWriteCString("signal=");
    DYYYCrashLoggerWriteUnsigned((unsigned long long)signalNumber);
    DYYYCrashLoggerWriteCString(" ");
    DYYYCrashLoggerWriteCString(DYYYCrashLoggerSignalName(signalNumber));
    DYYYCrashLoggerWriteCString("\ncode=");
    DYYYCrashLoggerWriteUnsigned((unsigned long long)(info ? info->si_code : 0));
    DYYYCrashLoggerWriteCString("\naddr=");
    DYYYCrashLoggerWriteHexPointer(info ? info->si_addr : NULL);
    DYYYCrashLoggerWriteCString("\n");
    DYYYCrashLoggerWriteBacktrace();
    DYYYCrashLoggerWriteFooter();

    struct sigaction previous = {0};
    if (signalNumber > 0 && signalNumber < NSIG) {
        previous = gDYYYPreviousSignalActions[signalNumber];
    }
    if (previous.sa_flags & SA_SIGINFO) {
        if (previous.sa_sigaction) {
            previous.sa_sigaction(signalNumber, info, context);
            return;
        }
    } else if (previous.sa_handler && previous.sa_handler != SIG_IGN && previous.sa_handler != SIG_DFL) {
        previous.sa_handler(signalNumber);
        return;
    }

    signal(signalNumber, SIG_DFL);
    raise(signalNumber);
}

static void DYYYCrashLoggerInstallSignal(int signalNumber) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = DYYYCrashLoggerHandleSignal;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    sigaction(signalNumber, &action, &gDYYYPreviousSignalActions[signalNumber]);
}

static void DYYYCrashLoggerMarkLaunchSurvived(NSNotification *notification) {
    (void)notification;
    DYYYCrashLoggerMark("app.didFinishLaunching");
}

void DYYYCrashLoggerMark(const char *stage) {
#if !DYYY_CRASH_LOG_ENABLED
    (void)stage;
    return;
#endif
    if (!stage) {
        return;
    }

    strncpy(gDYYYCrashStage, stage, sizeof(gDYYYCrashStage) - 1);
    gDYYYCrashStage[sizeof(gDYYYCrashStage) - 1] = '\0';

    DYYYCrashLoggerOpenFile();
    DYYYCrashLoggerWriteCString("[");
    DYYYCrashLoggerWriteUnsigned((unsigned long long)time(NULL));
    DYYYCrashLoggerWriteCString("] stage=");
    DYYYCrashLoggerWriteCString(stage);
    DYYYCrashLoggerWriteCString("\n");
    DYYYCrashLoggerFlush();
}

void DYYYCrashLoggerInstall(void) {
#if !DYYY_CRASH_LOG_ENABLED
    return;
#endif
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(&gDYYYCrashLoggerInstalled,
                                                 &expected,
                                                 true,
                                                 memory_order_acq_rel,
                                                 memory_order_acquire)) {
        return;
    }

    if (!DYYYCrashLoggerResolvePath()) {
        atomic_store_explicit(&gDYYYCrashLoggerInstalled, false, memory_order_release);
        return;
    }

    DYYYCrashLoggerOpenFile();
    const char *version = [DYYY_VERSION UTF8String];
    if (version) {
        strncpy(gDYYYCrashVersion, version, sizeof(gDYYYCrashVersion) - 1);
        gDYYYCrashVersion[sizeof(gDYYYCrashVersion) - 1] = '\0';
    }
    strncpy(gDYYYCrashStage, "install", sizeof(gDYYYCrashStage) - 1);
    gDYYYCrashStage[sizeof(gDYYYCrashStage) - 1] = '\0';
    DYYYCrashLoggerWriteCString("\n===== DYYY LAUNCH =====\n");
    DYYYCrashLoggerWriteCString("time=");
    DYYYCrashLoggerWriteUnsigned((unsigned long long)time(NULL));
    DYYYCrashLoggerWriteCString("\nversion=");
    DYYYCrashLoggerWriteCString(gDYYYCrashVersion[0] ? gDYYYCrashVersion : "unknown");
    DYYYCrashLoggerWriteCString("\npath=");
    DYYYCrashLoggerWriteCString(gDYYYCrashLogPath);
    DYYYCrashLoggerWriteCString("\n");
    DYYYCrashLoggerFlush();

    gDYYYPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&DYYYCrashLoggerHandleException);

    DYYYCrashLoggerInstallSignal(SIGABRT);
    DYYYCrashLoggerInstallSignal(SIGBUS);
    DYYYCrashLoggerInstallSignal(SIGFPE);
    DYYYCrashLoggerInstallSignal(SIGILL);
    DYYYCrashLoggerInstallSignal(SIGSEGV);
    DYYYCrashLoggerInstallSignal(SIGTRAP);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *notification) {
                                                    DYYYCrashLoggerMarkLaunchSurvived(notification);
                                                  }];
}

__attribute__((constructor(101))) static void DYYYCrashLoggerConstructor(void) {
#if DYYY_CRASH_LOG_ENABLED
    DYYYCrashLoggerInstall();
    DYYYCrashLoggerMark("dylib.loaded");
#endif
}
