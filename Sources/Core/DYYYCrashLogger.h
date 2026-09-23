#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 尽早安装未捕获异常和致命信号记录。写入宿主沙盒 Documents/DYYY/crash.log。
void DYYYCrashLoggerInstall(void);

/// 记录启动阶段，闪退时会一起写进 crash.log，用来判断死在哪一步。
void DYYYCrashLoggerMark(const char *stage);

#ifdef __cplusplus
}
#endif
