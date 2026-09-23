# 免授权助手的安全边界

装它只是为了省掉每次输密码。既然它手上有 root，就得说清楚它到底能干什么。

## 它做了什么

安装后系统里多出三样东西：

```
/Library/LaunchDaemons/cn.y10n.autoz.helper.plist   # launchd 配置
/usr/local/libexec/autoz-helper                     # 可执行文件
/var/run/cn.y10n.autoz.sock                         # 运行时 socket
```

卸载时**只删这三个文件**，不碰别处。「高级配置…」→ 卸载免授权助手，或在终端执行 `./autoz.sh helper-uninstall`。

## 不常驻

plist 里只有 `Sockets` 键，`RunAtLoad` 为 `false` —— 开机不会拉起进程。

真正的流程是：

1. App 连接 `/var/run/cn.y10n.autoz.sock`
2. **此时** launchd 才按需拉起助手进程
3. 助手用 `launch_activate_socket("Listeners")` 取回监听 fd
4. 处理完请求后**空闲 20 秒自动退出**

也就是说，绝大多数时间里系统里根本没有这个进程在跑。你可以自己验证：

```bash
pgrep -fl autoz-helper     # 平时应该没有输出
./autoz.sh helper-status   # 连接一次，触发拉起
pgrep -fl autoz-helper     # 这次能看到
# 等 20 秒后再看，进程已自行消失，下次连接会换一个新 pid
```

## 它只认四条指令

助手不提供任何形式的「执行任意命令」入口。协议里只有：

| 指令 | 作用 |
|---|---|
| `ping` | 探活 |
| `state` | 读当前时区与自动时区开关 |
| `set_zone` | 设置指定 IANA 时区 |
| `set_auto` | 开关系统「自动设置时区」 |

未知指令一律拒绝。报文必须是 JSON，非 JSON 直接拒。

## 三道门禁

### 1. 调用方 uid 白名单

助手用 `getpeereid()` 取**对端进程的 uid**（不是让对端自报），必须等于安装时写进 plist 的 `--allow-uid`。
其他用户连上来一律拒绝。

### 2. 时区名白名单

`set_zone` 的值要同时满足：

- 匹配 `^[A-Za-z0-9_+./-]{3,64}$`
- 不含 `..`、不以 `/` 开头
- 在 `zoneinfo` 目录下**确实存在**

所以不存在路径穿越面 —— 传 `../../etc/passwd` 或 `/etc/passwd` 都会被拒。

### 3. 写完复核

和主程序一样，助手改完也会重新读 `/etc/localtime` 确认结果，不靠返回码。

## 分片写入（半包）

socket 流式读取会碰到「一次读进来半条 JSON」的情况。助手按长度累积，收满完整报文才解析，
所以不会因为分包而丢指令或误判格式。

## 自己验证

上面这些都有自测用例覆盖，dry-run，不碰系统、不需要 root：

```bash
./autoz.sh helper-selftest
```

11 项：`ping`、`state`、拒绝路径穿越、拒绝绝对路径、拒绝不存在的时区名、合法时区出计划、`set_auto`、
拒绝未知指令、拒绝非 JSON、uid 门禁、分片写入。全绿才算通过（`build.sh` 里也是这道关，不过不给构建）。

安装前想看清楚会执行哪些特权命令，可以只打印不执行：

```bash
./autoz.sh helper-plan
```

## 不装了怎么退

```bash
./autoz.sh helper-uninstall
```

之后改时区会退回通道 1（每次弹一次管理员授权）。功能不受影响，只是麻烦一点。
