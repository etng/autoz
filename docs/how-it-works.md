# 工作原理

## 1. 菜单栏上的时间

菜单栏永远显示**东八区**（`Asia/Shanghai`, UTC+8）。格式不写死，而是从系统自带时钟继承：

```swift
DateFormatter.dateFormat(fromTemplate: "MMMdEEEjmm", options: 0, locale: .current)
```

中文环境下得到 `M月d日 EEE HH:mm`，即 `9月23日 周三 10:47`；换英文系统会自动变成对应的英文格式。
24 小时制跟随系统（`AppleICUForce24HourTime`），不自行决定。

标题颜色是状态指示：

| 颜色 | 含义 |
|---|---|
| 默认色 | 系统时区与东八区一致 |
| **橙色** | 系统时区**不是**东八区 —— 你看到的菜单栏时间不是本机时间 |

标题字号用 **13pt**（系统菜单栏时钟的字号，`NSFont.menuBarFont(ofSize: 0).pointSize` 也是 13），
并启用等宽数字以免秒数跳动时标题宽度抖动。鼠标悬停有 tooltip 显示详细状态
（系统时区、出口 IP、解析结果、上次操作）。

## 2. 出口 IP 与所在地时区

按优先级依次尝试：

| 顺序 | 来源 | 取的字段 |
|---|---|---|
| 1 | `https://ipinfo.io/json` | `timezone`（城市级精度，如 `America/Los_Angeles`） |
| 2 | `https://ipwho.is/` | `timezone.id` |
| 3 | 内置回退表 | 只在**全国统一时区**的国家/地区生效，避免对美 / 俄 / 澳这类多时区国家猜错 |

拿到的时区 ID 一律先过两道校验才允许往下走：

- `TimeZone(identifier:)` 必须返回非 nil
- 必须匹配 `^[A-Za-z0-9_+./-]{3,64}$`，且拒绝 `..` 与前导 `/`

## 3. 改系统时区：三条通道

**macOS 没有公开 API 能让普通 App 把自己变成 root** —— 这是刻意的安全边界，不是可以绕过的实现细节。
真正能改系统时区的只有 root 进程改 `/etc/localtime`（`systemsetup -settimezone` 干的就是这件事）。

所以能优化的只有「怎么拿到 root」这一步。程序提供三条通道，默认走第一条：

| 通道 | 弹窗频率 | 实现 |
|---|---|---|
| **0 · 免授权助手**（默认，需先安装） | **零弹窗** | 常驻于 `/usr/local/libexec/autoz-helper`，由 launchd 按需拉起；改时区走本地 Unix socket。装一次（输一次密码），重启后依然零弹窗。细节见[助手安全边界](helper-security.md) |
| 1 · 原生一次性授权 | 每次 | `Security.framework` 的 `AuthorizationCreate` + `AuthorizationExecuteWithPrivileges`。因为 Swift 无法直接导入这个已废弃符号，用一个 C 垫片转调；以 **argv 数组**直接执行系统二进制，**不经过 shell** |
| 2 · AppleScript 一次性授权 | 每次 | `osascript ... with administrator privileges`。通道 1 不可用时回退 |

通道 1 和 2 **做不到「授权一次、以后不弹」**：macOS 的授权凭证不跨调用复用，同一次运行里也会再次弹框。
想要一次都不弹，只能用通道 0。

通道可在「高级配置…」里切换。

## 4. 写完一定复核

改完时区后，程序**不信任命令的返回码**，而是重新 `readlink /etc/localtime` 核对结果。

这条不是多余的谨慎：实测 `systemsetup -settimezone` 在**非 root** 下会返回 `0` 却什么都不做（静默 no-op）。
只看返回码会把失败报成成功。

## 5. 监听系统变化

| 通知 | 触发时机 |
|---|---|
| `NSSystemTimeZoneDidChange` | 时区被改（本程序改的，或用户在系统设置里改的） |
| `NSCurrentLocaleDidChangeNotification` | 地区/语言变化，影响时间格式 |
| `NSSystemClockDidChange` | 系统时钟被调整 |

任一触发都会重画菜单栏标题，所以颜色始终反映真实状态。

## 6. 用到的系统原生 API

| 环节 | 实现 |
|---|---|
| 网络请求 | `URLSession`（带超时，不使用缓存） |
| 读系统时区 | `FileManager.destinationOfSymbolicLink` 读 `/etc/localtime` |
| 时区校验 | `TimeZone(identifier:)` + 正则白名单 |
| 时间格式继承 | `DateFormatter.dateFormat(fromTemplate:)` |
| 菜单栏渲染 | `NSStatusItem` + `NSAttributedString`（等宽数字，避免秒数跳动导致整条菜单栏抖动） |
| 打开系统设置 | `NSWorkspace.open` |
| 助手 socket 激活 | `launch_activate_socket`（`libSystem`） |

## 7. 数据落点

| 内容 | 位置 |
|---|---|
| 日志 | `~/Library/Logs/AutoZ.log`（超 512 KB 自动轮转） |
| 助手日志 | `/var/log/cn.y10n.autoz.helper.log` |
| 配置 | `~/Library/Preferences/cn.y10n.autoz.plist` |
