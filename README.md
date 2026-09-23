<div align="center">

# AutoZ

菜单栏上一个**永远是东八区**的时钟。打开同步后，它会按你的出口 IP 判断所在地时区，把**系统时区**改成那里 ——
此时菜单栏时间**变橙**，提醒你看到的不是本机时区。

</div>

---

## 它是干嘛的

两件事，可以只用第一件：

1. **菜单栏稳定显示北京时间**（UTC+8）。格式跟随系统自带时钟，中文环境下就是 `9月23日 周三 10:47`。
2. **让系统时区跟着出口 IP 走**。挂了代理 / 出国 / 换网络时，不用手动去「日期与时间」里翻时区。

时间颜色就是状态：**默认色 = 和系统时区一致，橙 = 不一致**。

## 安装

```bash
brew install --cask etng/taps/autoz
```

安装时会自动去掉 macOS 的隔离标记（见下方说明）。

> Homebrew 7 起，非官方 tap 的内容需要先被信任。上面这种**完整名字**安装会自动记下信任，无需额外操作；
> 如果你想用短名字（`brew install --cask autoz`），或希望 `brew outdated` / `brew upgrade` 不报信任错误，
> 先显式信任一次：`brew trust --tap etng/taps`（撤销：`brew untrust --tap etng/taps`）。

<details>
<summary>不想用 Homebrew？</summary>

从 [Releases](https://github.com/etng/autoz/releases) 下载 `AutoZ-x.y.z.tar.gz`，解压后把 `AutoZ.app` 拖进「应用程序」，
然后执行一次：

```bash
xattr -dr com.apple.quarantine /Applications/AutoZ.app
```

</details>

## 用起来

启动后菜单栏出现 `9月23日 周三 10:47`。点它，菜单里就三件事 —— 互不重叠：

| 菜单项 | 做什么 |
|---|---|
| **开启 / 关闭同步** | 开 = 持续跟随出口 IP 调系统时区；关 = **只停止跟随，当前时区保持不动** |
| **立即检查并同步（执行一次）** | 只做这一次：查出口 IP → 改系统时区。不动上面的开关 |
| **恢复到开启前的时区** | 一键回到你开启同步之前的那个时区（括号里会写明是哪个） |

再加底部两项：**高级配置…** 和 **退出**。

第一次用建议花一分钟装个「免授权助手」：macOS 不允许普通 App 改系统时区，默认方式每次都会弹管理员密码框；
装一次助手（输一次密码）之后就**一直零弹窗**，重启系统也有效。

> **高级配置…** → 改时区方式 → 安装免授权助手

「高级配置…」里还有：仅查询（不改系统）、恢复开启前状态、菜单栏是否显示秒、**登录时自动启动**、
切换改时区通道、安装 / 卸载免授权助手、打开系统「日期与时间」设置、打开运行日志、复制诊断信息、测试通知。

### 登录时自动启动

默认**开着** —— 首次运行就自动登记好，免得哪天想起来才发现一直没开。

实现上写的是用户级 LaunchAgent（`~/Library/LaunchAgents/cn.y10n.autoz.plist`），**不需要管理员密码**，
也会出现在「系统设置 → 通用 → 登录项」里，随时可在那里或「高级配置… → 启动」里关掉。
关掉之后不会在下次启动时被打回。

命令行：`AutoZ --login-status` / `--login-enable` / `--login-disable`。

## 卸载

```bash
brew uninstall --cask autoz
```

装过免授权助手的话，先「高级配置…」→ 卸载免授权助手，再卸载 App。

`brew uninstall` 只删 App 本身。想连配置文件一起清掉（含登录项），用 `--zap`：

```bash
brew uninstall --cask --zap autoz
```

或者手动删掉登录项（不移除的话，它会在下次登录时指向一个已经不存在的程序）：

```bash
rm -f ~/Library/LaunchAgents/cn.y10n.autoz.plist
```

## 须知

- ⚠️ **挂着代理运行时，解析出来的是代理所在地**，不是你的真实位置。这正是本程序的设计意图（让系统时区对上落地 IP），
  但如果你只是想看北京时间，**别开同步开关**，只留菜单栏时钟就行。
- 开启同步会**关掉系统的「自动设置时区」**；关闭同步或点「恢复到开启前的时区」时不会擅自替你打开，
  需要在系统设置里自行勾选。
- 日志：`~/Library/Logs/AutoZ.log`

## 文档

| 文档 | 内容 |
|---|---|
| [工作原理](docs/how-it-works.md) | 出口 IP 怎么查、时区怎么定、三条改时区通道的区别 |
| [免授权助手的安全边界](docs/helper-security.md) | 它为什么不需要常驻、能做什么、不能做什么 |
| [故障排查](docs/troubleshooting.md) | 时区没变 / 时间不变橙 / 打不开 / 怎么手动救急 |

## 从源码构建

```bash
./build.sh                              # 构建到 dist/AutoZ.app（本机架构）
AUTOZ_ARCHS="arm64 x86_64" ./build.sh   # 通用二进制
./build.sh --run                        # 构建并启动
./autoz.sh help                         # 命令行入口（封装 App 内二进制）
```

要求 macOS 13+ 与 Xcode Command Line Tools（`xcode-select --install`）。
构建过程包含助手自测 11 项协议与安全用例，不通过会直接终止。

## 许可

[MIT](LICENSE)
