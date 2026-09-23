// authshim.c — 为 Swift 提供一个可链接的入口，转调 Security.framework 的
// AuthorizationExecuteWithPrivileges。
//
// 背景：macOS 27 SDK 仍保留该函数声明，但标为 __OSX_AVAILABLE_BUT_DEPRECATED(10.1, 10.7)，
// Swift 导入器会拒绝「10.9 之前即废弃」的 API（unavailable in macOS），因此 Swift 侧无法直接调用；
// C 侧仅产生 deprecation 警告。符号在 macOS 27 运行时依然存在（dyld 共享缓存中可见）。
// 若某天该符号被真正移除，调用会返回错误码，程序会自动回退到 AppleScript 提权后端。
//
// 注意：这里以 argv 数组直接传参，不经过 shell，因此不存在字符串注入面。

#include <Security/Authorization.h>
#include <stdint.h>

int32_t AutoZExecWithPrivileges(void *auth, const char *tool, char *const *argv) {
    if (auth == NULL || tool == NULL) return -60000; /* errAuthorizationInvalidRef */
    return (int32_t)AuthorizationExecuteWithPrivileges((AuthorizationRef)auth,
                                                       tool,
                                                       (AuthorizationFlags)0,
                                                       argv,
                                                       NULL);
}
