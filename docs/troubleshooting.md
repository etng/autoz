# 故障排查

## 双击打不开，或者提示「已损坏，无法打开」

程序没有 Apple 开发者签名与公证（ad-hoc 签名），macOS 会对下载来的文件打上隔离标记。
通过 Homebrew 安装的话，安装脚本已自动清除；手动下载解压的请自己执行一次：

```bash
xattr -dr com.apple.quarantine /Applications/AutoZ.app
```

## 安装时报 `Refusing to load cask … from untrusted tap`

这是 Homebrew 7 起新增的**信任机制**：非官方 tap 的 formula / cask 必须先被信任才会加载。

用**完整名字**安装时 Homebrew 会自动记下信任，所以下面这条通常直接可用：

```bash
brew install --cask etng/taps/autoz
```

如果你是用短名字（`brew install --cask autoz`）触发的，按报错提示执行其一：

```bash
brew trust --cask etng/taps/autoz   # 只信任这一个 cask
brew trust --tap etng/taps          # 信任整个 tap（推荐，后续 brew upgrade 不再报错）
```

撤销信任：`brew untrust --tap etng/taps`；查看当前信任列表：`brew trust --json v1`。

## 安装时报 `It seems there is already an App at '/Applications/AutoZ.app'`

`/Applications/AutoZ.app` 已经存在 —— 通常是之前**手动下载**装过一次，或者上一个版本是用别的方式装的。
Homebrew 默认不会覆盖，需要显式加 `--force`：

```bash
brew install --cask --force etng/taps/autoz
```

要确认挡路的是哪个版本：

```bash
defaults read /Applications/AutoZ.app/Contents/Info.plist CFBundleShortVersionString
```

## 开机自启没生效 / 想去掉它

AutoZ 的「登录时自动启动」是一个**用户级 LaunchAgent**（`~/Library/LaunchAgents/cn.y10n.autoz.plist`），
不需要管理员密码，launchd **只在登录时读取**它，所以：

- **刚打开开关不会立刻拉起来**，下次登录才生效。想马上验证：

  ```bash
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/cn.y10n.autoz.plist
  ```

- **状态显示「已启用」但登录后没起来** —— 多半是 App 被移动或删除过，plist 里记的是旧路径。
  关掉再开一次即可修正（会重新按当前位置写）。查看记录的是哪个路径：

  ```bash
  plutil -p ~/Library/LaunchAgents/cn.y10n.autoz.plist
  AutoZ --login-status
  ```

- **想去掉**：在「高级配置… → 启动」里取消勾选，或「系统设置 → 通用 → 登录项」里关掉，或：

  ```bash
  rm -f ~/Library/LaunchAgents/cn.y10n.autoz.plist
  ```

  删完记得退出 App 重开一次，否则界面上的状态还是旧的。

> 为什么不用 `SMAppService`？在 ad-hoc 签名（无开发者 Team ID）下调用它注册会**直接让进程崩溃**，
> 而发布的正是 ad-hoc 包，所以改用 LaunchAgent。将来若做 Developer ID 正式签名，可以换回去。

## 菜单栏时间一直是黑的，不变橙

这**不是问题**。橙色表示「系统时区 ≠ 东八区」。如果你的系统时区本来就是 `Asia/Shanghai`，
颜色自然一致。挂上代理并开启同步、系统时区变成 `America/Los_Angeles` 之类之后，它就会变成橙色。

想确认当前状态，鼠标悬停在菜单栏的时间上，tooltip 里有系统时区和出口 IP。

## 开了同步，但系统时区没变

按顺序排查：

1. **看菜单里的「出口」那一行。** 如果解析出来的时区跟你想的一样，说明程序判对了，
   问题在写权限 —— 跳到第 3 步。
2. **出口 IP 是代理所在地，这本来就是设计意图。** 实测挂代理时出口 IP 会解析到落地机房所在国家
   （例如洛杉矶），系统时区就会被设成 `America/Los_Angeles` 而不是你人在的城市。
   如果你要的是「北京时间的钟」而不是「跟着落地 IP 走」，**别开同步开关**。
3. **看菜单里的「上次」那一行。** 常见的几种：
   - `授权被取消` —— 你在管理员密码框点了取消。重试一次；想彻底不弹框就装免授权助手。
   - 有报错文字 —— 按提示信息里的原因处理。
4. **翻日志**，里面有每一步的细节：

   ```bash
   tail -n 50 ~/Library/Logs/AutoZ.log
   ```

   免授权助手自己的日志在 `/var/log/cn.y10n.autoz.helper.log`。

## 每次改时区都要输密码

这是 macOS 的限制，不是程序偷懒 —— 装一次免授权助手即可。

**高级配置…** → 改时区方式 → 安装免授权助手（输一次密码，之后一直零弹窗，重启系统也有效）。

原理见[免授权助手的安全边界](helper-security.md)。

## 装了助手，但还是在弹密码

```bash
./autoz.sh helper-status     # 看状态 + ping
```

ping 不通通常是三种情况：

- **助手没装成**：重新「高级配置…」→ 安装免授权助手。
- **uid 不匹配**：助手只接受安装时登记的那个用户 uid。换过账号或系统迁移过的话，卸载再装一次。
- **socket 被清理**：`/var/run` 在部分系统清理策略下会被清空。重启后 launchd 会按 plist 重新建立，
  若仍不通，卸载重装。

实在不行先切回通道 1 顶上：**高级配置…** → 改时区方式 → 原生一次性授权。

## 时间格式跟系统时钟不一样

格式是**从系统继承**的，不自己决定。要改就去改系统：

**高级配置…** → 打开「日期与时间」设置，或：系统设置 → 通用 → 语言与地区。

## 菜单栏里找不到它

菜单栏图标太多时，macOS 会把靠右的项挤出去。关掉一些不需要的菜单栏图标，
或者按住 `⌘` 把它拖到左边。

## 手动救急（不依赖本程序）

万一程序出问题、时区被改乱了，用系统自带命令恢复：

```bash
# 设回东八区
sudo systemsetup -settimezone Asia/Shanghai

# 重新打开「自动设置时区」
sudo defaults write /Library/Preferences/com.apple.timezone.auto Active -bool true
```

反过来，如果你想彻底停掉本程序的影响：先在菜单里关掉同步，再退出 AutoZ。

## 想反馈问题

**高级配置…** → 复制诊断信息（版本、系统时区、自动时区开关、当前通道、最近几行日志），
贴到 issue 里即可。里面不含账号、IP 白名单之类的敏感信息。

> 注意：诊断信息里**会包含出口 IP**，贴到公开 issue 前可以自行删掉那一行。
