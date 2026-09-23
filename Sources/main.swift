// AutoZ — 菜单栏「东八区时钟 + 出口 IP 时区同步」
//
// 设计要点：
//   1. 菜单栏标题永远是东八区（Asia/Shanghai）时间，格式**跟随系统菜单栏时钟**
//      （日期 + 星期 + 时间，zh_CN 下即「9月23日 周三 10:04」），12/24 小时偏好一并继承；
//      字号也用系统菜单栏的 13pt，和系统时钟并排看不出差别。
//      （曾前置过一个「◷」标识符，但它笔画太细、在菜单栏里几乎看不见，已去掉。）
//   2. 当「菜单栏显示的时间」与「系统当前时区的时间」不一致时，标题变橙 —— 一眼看出看到的不是本机时区。
//   3. 时区同步：拉取 ipinfo.io/json → 解析 IANA 时区 → 写入系统时区 + 关闭「自动设置时区」。
//   4. 关闭开关时恢复开启前的系统时区与自动时区设置（可逆）。
//   5. 菜单主次：顶部状态 3~5 行 → 两个主操作（加粗：开启同步 / 恢复开启前状态）→
//      免授权模式状态 → 其余全部收进「更多」子菜单。菜单是数据驱动的（Row 模型 → 渲染），
//      所以可以用 `AutoZ --menu` 把菜单结构打成文本审查，不必靠肉眼点。
//
// 改时区（关键约束）：
//   macOS 不存在「当前进程直接变 root」的 API —— 这是刻意的安全边界。能改系统时区的只有 root
//   进程改 /etc/localtime（systemsetup 也是干这个）。所以能优化的只是「怎么拿到 root」，三条通道：
//
//     通道 0（默认）· 免授权助手：/Library/LaunchDaemons 下的 launchd 任务（root），
//       由 Sockets 键按需拉起、空闲 20s 自动退出（**不常驻**）。装一次（输一次密码）之后，
//       改时区走本地 Unix socket，**零弹窗**，重启也有效。接口极窄：只认 set_zone/set_auto/ping，
//       校验对端 uid + 时区白名单，见 Sources/helper.swift。
//
//     通道 1 · 原生一次性授权：Security.framework 的 AuthorizationCreate 弹系统认证框，
//       再经 authshim.c 转调 AuthorizationExecuteWithPrivileges，以 argv 数组直接执行系统二进制
//       （/usr/bin/defaults、/usr/sbin/systemsetup、/bin/ln），**全程不经过 shell**。
//
//     通道 2 · AppleScript 一次性授权：osascript `do shell script ... with administrator privileges`。
//
//   通道 1/2 **每次都会弹一次系统认证窗口**。这一点是实测结论，不是保守估计：
//   日志里 09:45:56 授权成功后，09:49:24 同一次运行内又弹了一次（原生返回 -60006 = 已取消）。
//   macOS 的授权凭证不跨调用复用，所以「一次授权、永久生效」只能靠通道 0。

import Cocoa
import Security
import Network

// 由 authshim.c 提供：转调 AuthorizationExecuteWithPrivileges（Swift 无法直接导入该符号）
@_silgen_name("AutoZExecWithPrivileges")
func tzExecPriv(_ auth: UnsafeMutableRawPointer,
                _ tool: UnsafePointer<CChar>,
                _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

// MARK: - 常量

enum K {
    static let beijingID   = "Asia/Shanghai"
    static let zoneRoot    = "/var/db/timezone/zoneinfo/"
    static let autoTZPlist = "/Library/Preferences/com.apple.timezone.auto"
    /// 版本号以 Info.plist 为准（构建时由 build.sh 的 AUTOZ_VERSION 注入并写入 plist）；
    /// 直接跑裸二进制时回退到编译期默认值。
    static let version: String = {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !v.isEmpty { return v }
        return "0.8.0"
    }()
    static let logPath     = NSHomeDirectory() + "/Library/Logs/AutoZ.log"
    static let appSupport  = NSHomeDirectory() + "/Library/Application Support/AutoZ"
}

/// 实际 bundle id（直接运行二进制时为 nil，退化为编译期默认值）
let bundleID = Bundle.main.bundleIdentifier ?? "cn.y10n.autoz"

// MARK: - 对外命名
//
// 改名只动两处：这里（代码侧）与 build.sh 的 AUTOZ_DISPLAY_NAME（Info.plist 侧）。
//
// 注意区分两类名字：
//   · 显示名（appDisplayName）    —— 给人看的，可以随便改
//   · 存储标识（bundleID / "AutoZ" 日志与配置目录）—— 给系统看的，改了会让老用户
//     的日志、偏好设置、Application Support 失联，所以**不跟随显示名变化**。

/// 产品显示名：高级配置窗口、帮助文案统一用它。
/// 与 bundle id 一样以构建期写入的 Info.plist 为准，直接跑裸二进制时回退到默认值。
let appDisplayName: String =
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        .flatMap { $0.isEmpty ? nil : $0 } ?? "自适应时区"

/// 一句话定位，避免同一句话散落在多个界面里各自漂移。
let appTagline = "菜单栏北京时间 + 出口 IP 同步系统时区"

/// 菜单栏标题字体。
///
/// 字号取 13pt —— 这就是系统菜单栏时钟的字号（`NSFont.menuBarFont(ofSize: 0).pointSize`
/// 也是 13.0），两者并排渲染出来的宽度对得上（实测系统时钟那串「9月22日 周二 20:30」
/// 占 123px，13pt 渲染为 120.9px，12pt 只有 112.3px）。早先用 12pt，明显小一号。
///
/// 用等宽数字（monospacedDigit）是为了秒数跳动时标题宽度不抖 —— 系统时钟也这么做。
/// 集中在这里定义，避免设置处和每次 tick 渲染处各写一份然后漂移。
let menuBarTitleFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

// MARK: - 开机自启（用户级 LaunchAgent）

/// 开机自启用登录项实现，但**刻意不用 SMAppService** ——
/// 实测：ad-hoc 签名（无 Team ID）下 `SMAppService.mainApp.register()`
/// 直接 SIGTRAP 把进程干掉，Swift 的 do/catch 根本拦不住。本项目对外发布的
/// 就是 ad-hoc 签名包，所以改用用户级 LaunchAgent：
///
///   · 只写 `~/Library/LaunchAgents/`，**不需要管理员密码**
///   · 同样会出现在「系统设置 → 通用 → 登录项」里，用户可随时撤销
///   · 卸载只需删掉这一个文件，不留残渣
///
/// 若将来用 Developer ID 正式签名并公证，可以再换回 SMAppService。
enum LoginItem {
    /// 用 bundle id 当 launchd label，便于在登录项列表里认出
    static let label = "cn.y10n.autoz"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// 写进 plist 的可执行文件路径。用 Bundle.main 推导，
    /// App 放在哪就注册哪，不写死 /Applications。
    static var executablePath: String { Bundle.main.executablePath ?? "" }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// App 是否在「应用程序」目录里 —— 不在的话，用户移动或删除它之后自启就会失效，
    /// 所以状态文案要提醒，不能只显示「已启用」。
    static var bundleInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// 状态的人话说明，直接显示在界面上
    static var statusText: String {
        guard isEnabled else { return "未启用" }
        if executablePath.isEmpty || !FileManager.default.fileExists(atPath: executablePath) {
            return "已启用，但记录的路径已失效 —— 关掉再开一次可修正"
        }
        if !bundleInApplications {
            return "已启用（App 当前不在「应用程序」里，移动后自启会失效）"
        }
        return "已启用，下次登录自动启动"
    }

    /// 开启 / 关闭。成功返回 nil，失败返回原因（供提示与日志使用）。
    /// 写文件是即时的，但 launchd 要**下次登录**才会读取，所以界面文案不要写成「已生效」。
    static func set(_ on: Bool) -> String? {
        let fm = FileManager.default
        guard !executablePath.isEmpty else { return "取不到 App 的可执行文件路径" }

        if on {
            do {
                try fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try plistXML().write(to: plistURL, atomically: true, encoding: .utf8)
                return nil
            } catch {
                return error.localizedDescription
            }
        } else {
            do {
                if fm.fileExists(atPath: plistURL.path) { try fm.removeItem(at: plistURL) }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    /// 首次运行默认开启。
    /// 用户的诉求是「避免很多时候搞忘开启了」—— 那就别指望他记得去点，默认就开。
    ///
    /// 用 UserDefaults 记一个「已初始化」标记：用户之后手动关掉，不会被下次启动打回。
    /// 另外只在 App 已经待在「应用程序」目录时才登记 —— 从 build/ 目录直接跑起来时
    /// 若写了 plist，登录项会指向构建目录，既没用又容易留下垃圾。
    static func applyFirstRunDefault() {
        // 不在「应用程序」里就别登记，也**不要**置标记，等用户装好后下次启动再补
        guard bundleInApplications else {
            log("首次运行：App 不在「应用程序」目录（\(Bundle.main.bundlePath)），跳过默认开启开机自启")
            return
        }
        let key = "autoz.launchAtLogin.initialized"
        let d = UserDefaults.standard
        guard d.object(forKey: key) == nil else { return }   // 已经处理过，尊重用户的当前选择
        d.set(true, forKey: key)
        guard !isEnabled else { return }
        if let err = set(true) {
            log("首次运行：自动开启开机自启失败 —— \(err)")
        } else {
            log("首次运行：已默认开启开机自启（可在「高级配置 → 启动」里关掉）")
        }
    }

    /// 路径里可能有 & < > 之类字符，写进 XML 前必须转义，否则 plist 会解析失败
    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func plistXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(xmlEscape(label))</string>
            <key>ProgramArguments</key>
            <array><string>\(xmlEscape(executablePath))</string></array>
            <key>RunAtLoad</key><true/>
            <key>LimitLoadToSessionType</key><string>Aqua</string>
            <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
    }
}

// MARK: - 日志

private let logQueue = DispatchQueue(label: "autoz.log")

func log(_ msg: String) {
    let line = "[\(stamp(Date()))] \(msg)\n"
    logQueue.async {
        let fm = FileManager.default
        if !fm.fileExists(atPath: K.logPath) {
            fm.createFile(atPath: K.logPath, contents: nil)
        }
        // 超过 512KB 就轮转一次，避免无限增长
        if let attrs = try? fm.attributesOfItem(atPath: K.logPath),
           let size = attrs[.size] as? Int, size > 512 * 1024 {
            try? fm.removeItem(atPath: K.logPath + ".1")
            try? fm.moveItem(atPath: K.logPath, toPath: K.logPath + ".1")
            fm.createFile(atPath: K.logPath, contents: nil)
        }
        if let fh = FileHandle(forWritingAtPath: K.logPath) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            try? fh.close()
        }
    }
}

func stamp(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: d)
}

// MARK: - 进程执行

@discardableResult
func runProcess(_ path: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
    guard FileManager.default.isExecutableFile(atPath: path) else {
        return (-1, "", "不可执行: \(path)")
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let op = Pipe(), ep = Pipe()
    p.standardOutput = op
    p.standardError = ep
    do { try p.run() } catch { return (-1, "", "\(error)") }
    // 输出量极小（远小于管道缓冲），先读完再 wait 不会死锁
    let od = op.fileHandleForReading.readDataToEndOfFile()
    let ed = ep.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus,
            String(decoding: od, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            String(decoding: ed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func osaQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

// MARK: - 通知
//
// 一律走程序内自绘横幅（ToastCenter，见 ui.swift），不再用 osascript，也不依赖系统通知权限：
//   ・osascript display notification 会以「脚本编辑器」的身份弹出来，观感很差；
//   ・macOS 27 拒绝给 ad-hoc 签名的 App 注册 UNUserNotificationCenter（实测 UNErrorDomain Code=1）。
//   自绘横幅零权限、跟随系统外观、样式与 App 图标统一。

func notify(title: String, message: String, sound: String? = "Glass") {
    ToastCenter.shared.post(title: title, message: message, sound: sound)
}

// MARK: - 网络

private let httpQueue = DispatchQueue(label: "autoz.http")

func httpGetJSON(_ urlString: String, timeout: TimeInterval = 12) throws -> [String: Any] {
    guard let url = URL(string: urlString) else { throw TZError.network("非法 URL: \(urlString)") }
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    req.cachePolicy = .reloadIgnoringLocalCacheData
    req.setValue("AutoZ/\(K.version) (macOS menu bar utility)", forHTTPHeaderField: "User-Agent")

    var payload: Data?
    var failure: Error?
    let sem = DispatchSemaphore(value: 0)
    let cfg = URLSessionConfiguration.ephemeral
    cfg.waitsForConnectivity = false
    cfg.timeoutIntervalForRequest = timeout
    let session = URLSession(configuration: cfg)
    session.dataTask(with: req) { data, resp, err in
        if let err = err { failure = err }
        else if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            failure = TZError.network("HTTP \(http.statusCode)")
        } else { payload = data }
        sem.signal()
    }.resume()
    if sem.wait(timeout: .now() + timeout + 5) == .timedOut { throw TZError.network("请求超时") }
    session.invalidateAndCancel()
    if let e = failure { throw e }
    guard let data = payload, !data.isEmpty else { throw TZError.network("空响应") }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TZError.network("响应不是 JSON 对象")
    }
    return obj
}

enum TZError: LocalizedError {
    case network(String)
    case noTimeZone(String)
    case shell(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .network(let s):     return "网络错误：\(s)"
        case .noTimeZone(let s):  return "无法确定时区：\(s)"
        case .shell(let s):       return "命令执行失败：\(s)"
        case .cancelled:          return "已取消（未获管理员授权）"
        }
    }
}

// MARK: - 数据模型

struct Detection: Codable {
    var ip: String
    var city: String
    var region: String
    var country: String
    var org: String
    var source: String        // 数据来源
    var zoneID: String        // 解析出的 IANA 时区
    var zoneSource: String    // 时区是怎么定出来的
    var rawJSON: String
    var fetchedAt: Date

    var locationText: String {
        [city, region, country].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - 单时区国家回退表（只收录「全国统一一个时区」的国家/地区，避免给出错误答案）

private let singleZoneCountries: [String: String] = [
    "CN": "Asia/Shanghai", "HK": "Asia/Hong_Kong", "MO": "Asia/Macau", "TW": "Asia/Taipei",
    "JP": "Asia/Tokyo", "KR": "Asia/Seoul", "KP": "Asia/Pyongyang", "SG": "Asia/Singapore",
    "MY": "Asia/Kuala_Lumpur", "TH": "Asia/Bangkok", "VN": "Asia/Ho_Chi_Minh", "PH": "Asia/Manila",
    "KH": "Asia/Phnom_Penh", "LA": "Asia/Vientiane", "MM": "Asia/Yangon", "BN": "Asia/Brunei",
    "IN": "Asia/Kolkata", "PK": "Asia/Karachi", "BD": "Asia/Dhaka", "LK": "Asia/Colombo",
    "NP": "Asia/Kathmandu", "AE": "Asia/Dubai", "SA": "Asia/Riyadh", "QA": "Asia/Qatar",
    "KW": "Asia/Kuwait", "BH": "Asia/Bahrain", "OM": "Asia/Muscat", "IR": "Asia/Tehran",
    "IL": "Asia/Jerusalem", "TR": "Europe/Istanbul", "EG": "Africa/Cairo", "ZA": "Africa/Johannesburg",
    "NG": "Africa/Lagos", "KE": "Africa/Nairobi", "ET": "Africa/Addis_Ababa",
    "GB": "Europe/London", "IE": "Europe/Dublin", "FR": "Europe/Paris", "DE": "Europe/Berlin",
    "IT": "Europe/Rome", "NL": "Europe/Amsterdam", "BE": "Europe/Brussels", "CH": "Europe/Zurich",
    "AT": "Europe/Vienna", "SE": "Europe/Stockholm", "NO": "Europe/Oslo", "DK": "Europe/Copenhagen",
    "FI": "Europe/Helsinki", "PL": "Europe/Warsaw", "CZ": "Europe/Prague", "SK": "Europe/Bratislava",
    "HU": "Europe/Budapest", "RO": "Europe/Bucharest", "GR": "Europe/Athens", "BG": "Europe/Sofia",
    "HR": "Europe/Zagreb", "RS": "Europe/Belgrade",
]

let zoneIDPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_+./-]{3,64}$")

func isValidZoneID(_ id: String) -> Bool {
    guard TimeZone(identifier: id) != nil else { return false }
    let r = NSRange(id.startIndex..<id.endIndex, in: id)
    return zoneIDPattern.firstMatch(in: id, range: r) != nil
}

// MARK: - 检测器

enum Checker {

    static func run() throws -> Detection {
        var failures: [String] = []
        // 1) ipinfo.io（主源）
        if let det = try? fromIpinfo() { return det }
        else { failures.append("ipinfo.io 失败") }
        // 2) ipwho.is（备源）
        if let det = try? fromIpwho() { return det }
        else { failures.append("ipwho.is 失败") }
        throw TZError.network(failures.joined(separator: "；"))
    }

    private static func fromIpinfo() throws -> Detection {
        let j = try httpGetJSON("https://ipinfo.io/json")
        return try build(json: j,
                         ip: j["ip"] as? String ?? "",
                         city: j["city"] as? String ?? "",
                         region: j["region"] as? String ?? "",
                         country: j["country"] as? String ?? "",
                         org: j["org"] as? String ?? "",
                         zone: j["timezone"] as? String,
                         source: "ipinfo.io/json")
    }

    private static func fromIpwho() throws -> Detection {
        let j = try httpGetJSON("https://ipwho.is/")
        if let ok = j["success"] as? Bool, ok == false {
            throw TZError.network("ipwho.is 返回失败")
        }
        let tz = (j["timezone"] as? [String: Any])?["id"] as? String
        return try build(json: j,
                         ip: j["ip"] as? String ?? "",
                         city: j["city"] as? String ?? "",
                         region: j["region"] as? String ?? "",
                         country: j["country_code"] as? String ?? (j["country"] as? String ?? ""),
                         org: (j["connection"] as? [String: Any])?["isp"] as? String ?? "",
                         zone: tz,
                         source: "ipwho.is")
    }

    private static func build(json: [String: Any], ip: String, city: String, region: String,
                              country: String, org: String, zone: String?, source: String) throws -> Detection {
        var zoneID = ""
        var zoneSource = ""

        if let z = zone, isValidZoneID(z) {
            zoneID = z
            zoneSource = "\(source) · timezone 字段"
        } else if let cc = country.isEmpty ? nil : country.uppercased(), let z = singleZoneCountries[cc] {
            zoneID = z
            zoneSource = "单时区国家回退表（\(cc)）"
        }

        guard !zoneID.isEmpty, let tz = TimeZone(identifier: zoneID) else {
            throw TZError.noTimeZone("\(source) 未返回可用 timezone（原值 \(zone ?? "nil")）")
        }
        // 用 secOffset 做一次自检，确保可用
        _ = tz.secondsFromGMT(for: Date())

        let raw = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return Detection(ip: ip, city: city, region: region, country: country, org: org,
                         source: source, zoneID: zoneID, zoneSource: zoneSource,
                         rawJSON: raw, fetchedAt: Date())
    }
}

// MARK: - 系统时区读写

func systemZoneID() -> String {
    func strip(_ link: String) -> String? {
        for root in [K.zoneRoot, "/usr/share/zoneinfo/"] where link.hasPrefix(root) {
            let id = String(link.dropFirst(root.count))
            return id.isEmpty ? nil : id
        }
        return nil
    }
    if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime") {
        if let id = strip(link) { return id }
        if link.hasSuffix("/var/db/timezone/localtime") || link == "/var/db/timezone/localtime" {
            if let inner = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/timezone/localtime"),
               let id = strip(inner) { return id }
        }
    }
    // 兜底：进程启动时缓存的时区（可能滞后，仅作最后手段）
    let cached = TimeZone.current.identifier
    return cached == "GMT" ? "" : cached
}

/// 读取 /Library/Preferences/com.apple.timezone.auto 的 Active（无需提权）
func autoTimeZoneEnabled() -> Bool? {
    let r = runProcess("/usr/bin/defaults", ["read", K.autoTZPlist, "Active"])
    if r.status != 0 { return nil }
    let v = r.out.lowercased()
    if v == "1" || v == "true" || v == "yes" { return true }
    if v == "0" || v == "false" || v == "no" { return false }
    return nil
}

enum ApplyOutcome {
    case changed(String)            // 成功改成某时区
    case already(String)            // 本来就是该时区
    case cancelled
    case failed(String)
}

/// 生成「一次性提权」的 AppleScript（回退后端）；autoTZ 非 nil 时顺带写入自动时区开关。
/// 说明：zoneID 已通过 isValidZoneID 白名单校验（仅 [A-Za-z0-9_+./-]），可安全内插。
func buildOsaCommand(zoneID: String, autoTZ: Bool?) -> String {
    var parts: [String] = []
    if let a = autoTZ {
        parts.append("/usr/bin/defaults write \(K.autoTZPlist) Active -bool \(a ? "true" : "false") >/dev/null 2>&1")
    }
    parts.append("/usr/sbin/systemsetup -settimezone \(osaQuote(zoneID)) >/dev/null 2>&1")
    parts.append("if [ \"$(/usr/bin/readlink /etc/localtime)\" != \"\(K.zoneRoot)\(zoneID)\" ]; "
                 + "then /bin/ln -sfn \"\(K.zoneRoot)\(zoneID)\" /etc/localtime; "
                 + "/usr/bin/notifyutil -p com.apple.system.timezone >/dev/null 2>&1; fi")
    parts.append("/usr/bin/readlink /etc/localtime")
    return "do shell script \(osaQuote(parts.joined(separator: "; "))) with administrator privileges"
}

// MARK: - 特权助手通道（免授权）
//
// 背景（实测结论）：Security.framework 与 AppleScript 两条一次性的路**每次调用都要重新授权**，
// 凭证不会跨调用复用。实测日志：09:45 授权成功后，09:49 同一次运行里又弹了一次。
// 要真正做到「装一次、以后都不弹」，唯一正路是装一个现成的特权通道：
//
//   安装（输一次密码）→ /Library/LaunchDaemons 下的 launchd 任务（root）
//   之后改时区 → 本地 Unix socket 通信，**零弹窗**（重启也有效，launchd 会重新加载任务）

enum HelperK {
    static let label      = "cn.y10n.autoz.helper"
    static let socketPath = "/var/run/cn.y10n.autoz.sock"
    static let plistPath  = "/Library/LaunchDaemons/cn.y10n.autoz.helper.plist"
    static let binPath    = "/usr/local/libexec/autoz-helper"
    static let logPath    = "/var/log/cn.y10n.autoz.helper.log"
}

struct HelperReply {
    var ok: Bool
    var msg: String
    var zone: String?
    var auto: Bool?
    var changed: Bool
    var steps: [String]
    var raw: [String: Any]
}

enum HelperChannel {
    static var socketExists: Bool { FileManager.default.fileExists(atPath: HelperK.socketPath) }
    static var plistInstalled: Bool { FileManager.default.fileExists(atPath: HelperK.plistPath) }
    static var binaryInstalled: Bool { FileManager.default.isExecutableFile(atPath: HelperK.binPath) }

    /// 待安装的助手二进制来源：优先 app bundle 内 Resources/autoz-helper，CLI 模式取同级目录
    static var binarySource: String? {
        if let r = Bundle.main.resourcePath {
            let p = r + "/autoz-helper"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let sib = (exe as NSString).deletingLastPathComponent + "/autoz-helper"
        return FileManager.default.isExecutableFile(atPath: sib) ? sib : nil
    }

    /// 发一条指令并等一行 JSON 回复。socket 不存在/连不上/超时 → nil（调用方据此回退）
    static func request(_ payload: [String: Any], timeout: TimeInterval = 25) -> HelperReply? {
        guard FileManager.default.fileExists(atPath: HelperK.socketPath),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) {
                _ = strlcpy($0, HelperK.socketPath, cap)
            }
        }
        let len = socklen_t(MemoryLayout<sa_family_t>.size + HelperK.socketPath.utf8.count + 1)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard rc == 0 else { return nil }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var out = body
        out.append(0x0A)
        out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < out.count {
                let n = write(fd, base.advanced(by: off), out.count - off)
                if n <= 0 { break }
                off += n
            }
        }
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buf.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
        }
        guard let nl = buf.firstIndex(of: 0x0A),
              let obj = (try? JSONSerialization.jsonObject(with: buf.subdata(in: buf.startIndex..<nl))) as? [String: Any]
        else { return nil }
        return HelperReply(ok: obj["ok"] as? Bool ?? false,
                           msg: obj["msg"] as? String ?? "",
                           zone: obj["zone"] as? String,
                           auto: obj["auto"] as? Bool,
                           changed: obj["changed"] as? Bool ?? false,
                           steps: obj["steps"] as? [String] ?? [],
                           raw: obj)
    }

    static func ping() -> HelperReply? { request(["cmd": "ping"], timeout: 8) }

    static func setZone(_ zone: String, auto: Bool?) -> HelperReply? {
        var p: [String: Any] = ["cmd": "set_zone", "zone": zone]
        if let a = auto { p["auto"] = a }
        return request(p, timeout: 30)
    }

    /// 人类可读的通道状态（菜单/诊断用）
    static var statusText: String {
        if !socketExists { return plistInstalled ? "已安装但 socket 未就绪" : "未安装（每次改时区都要输密码）" }
        if let r = ping() {
            let extra = (r.raw["zone"] as? String).map { " · 助手视角 \($0)" } ?? ""
            return "已启用 · 零弹窗（重启也有效）" + extra
        }
        return socketExists ? "socket 在但无响应（可点「重新安装」修复）" : "未安装"
    }
}

// MARK: - 一次性授权：统一「特权命令计划」执行器
//
// 说明：助手通道**只能**改时区（窄接口，见 helper.swift），装/卸助手本身必须走这里的一次性授权 ——
// 这是设计上的取舍：不给助手留下「执行任意计划」的能力，否则它就等于一个 root 后门。

struct PrivStep {
    var tool: String
    var args: [String]
    var note: String?
    var ignoreFailure: Bool

    init(_ tool: String, _ args: [String], note: String? = nil, ignoreFailure: Bool = false) {
        self.tool = tool
        self.args = args
        self.note = note
        self.ignoreFailure = ignoreFailure
    }

    var display: String {
        ([tool] + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }).joined(separator: " ")
    }
}

struct PrivResult {
    var ok: Bool
    var cancelled: Bool
    var backend: String
    var executed: [(step: String, status: Int32, err: String)]
    var msg: String

    var summary: String {
        let failed = executed.filter { $0.status != 0 && $0.status != -999 }
        if cancelled { return "已取消授权" }
        if ok || failed.isEmpty { return "全部 \(executed.count) 步成功" }
        return "\(failed.count)/\(executed.count) 步失败：" + failed.map { "\($0.step) → \($0.status)" }.joined(separator: "；")
    }
}

/// 用一次授权执行整串特权命令。优先原生 Security.framework，不可用时回退 AppleScript。
func runPrivilegedPlan(_ steps: [PrivStep], reason: String) -> PrivResult {
    if steps.isEmpty {
        return PrivResult(ok: true, cancelled: false, backend: "无", executed: [], msg: "无需执行")
    }
    log("提权计划（\(reason)）共 \(steps.count) 步，后端=\(Store.shared.privBackend.rawValue)")
    for s in steps { log("  · \(s.display)\(s.note.map { "   ← \($0)" } ?? "")") }

    var nativeUnusable = false

    // ---- 后端 A：原生 Security.framework（argv 直传，不经 shell）----
    if Store.shared.privBackend != .appleScript {
        var ref: AuthorizationRef?
        let st = AuthorizationCreate(nil, nil, [.interactionAllowed, .extendRights, .preAuthorize], &ref)
        if st == errAuthorizationCanceled {
            return PrivResult(ok: false, cancelled: true, backend: "native", executed: [], msg: "已取消授权")
        }
        if st == errAuthorizationSuccess, let auth = ref {
            defer { AuthorizationFree(auth, []) }
            var executed: [(String, Int32, String)] = []
            var allOK = true
            for s in steps {
                let status = execPrivileged(auth, s.tool, s.args)
                executed.append((s.display, status, ""))
                log("  原生 \(s.display) → \(status)")
                if status == errAuthorizationCanceled {
                    return PrivResult(ok: false, cancelled: true, backend: "native", executed: executed,
                                      msg: "已取消授权")
                }
                if status == -60031 {          // errAuthorizationToolExecuteFailure：符号失效
                    nativeUnusable = true
                    break
                }
                if status != 0 && !s.ignoreFailure { allOK = false; break }
            }
            if !nativeUnusable {
                Store.shared.lastBackend = "native"
                return PrivResult(ok: allOK, cancelled: false, backend: "native", executed: executed,
                                  msg: allOK ? "全部 \(executed.count) 步成功" : "有步骤失败")
            }
            log("原生提权返回 -60031 → 回退 AppleScript")
        } else {
            log("原生提权不可用：AuthorizationCreate -> \(st) → 回退 AppleScript")
        }
    }
    if Store.shared.privBackend == .native && nativeUnusable {
        log("后端被固定为 native，但该 API 在本机不可用")
    }

    // ---- 后端 B：AppleScript 一次性授权 ----
    let cmds = steps.map { ([$0.tool] + $0.args).map(osaQuote).joined(separator: " ") }
    let script = "do shell script \(osaQuote(cmds.joined(separator: "; "))) with administrator privileges"
    log("AppleScript 提权计划：\(cmds.count) 条命令")
    let r = runProcess("/usr/bin/osascript", ["-e", script])
    Store.shared.lastBackend = "appleScript"
    if r.status != 0 {
        if r.err.contains("User canceled") || r.err.contains("-128") || r.err.contains("canceled") {
            return PrivResult(ok: false, cancelled: true, backend: "appleScript", executed: [], msg: "已取消授权")
        }
        return PrivResult(ok: false, cancelled: false, backend: "appleScript", executed: [],
                          msg: r.err.isEmpty ? "osascript status=\(r.status)" : r.err)
    }
    log("AppleScript 提权返回: \(r.out)")
    return PrivResult(ok: true, cancelled: false, backend: "appleScript",
                      executed: cmds.map { ($0, 0, "") }, msg: "全部 \(cmds.count) 步成功")
}

// MARK: - 助手的安装 / 卸载（走一次性授权）

enum HelperInstaller {

    static func plistXML(allowUID: uid_t) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(HelperK.label)</string>
            <key>Sockets</key>
            <dict>
                <key>Listeners</key>
                <dict>
                    <key>SockPathName</key>
                    <string>\(HelperK.socketPath)</string>
                    <key>SockPathMode</key>
                    <integer>438</integer>
                    <key>SockType</key>
                    <string>stream</string>
                </dict>
            </dict>
            <key>ProgramArguments</key>
            <array>
                <string>\(HelperK.binPath)</string>
                <string>--allow-uid</string>
                <string>\(allowUID)</string>
            </array>
            <key>RunAtLoad</key>
            <false/>
            <key>KeepAlive</key>
            <false/>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>\(HelperK.logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(HelperK.logPath)</string>
        </dict>
        </plist>
        """
    }

    /// 把待安装的两个文件落到用户目录（非特权即可），后续由特权步骤搬进系统目录
    static func stage() throws -> (helper: String, plist: String) {
        guard let src = HelperChannel.binarySource else {
            throw TZError.shell("找不到 autoz-helper（app bundle 里没有？请重新 build）")
        }
        let dir = K.appSupport + "/install"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let h = dir + "/autoz-helper"
        let p = dir + "/\(HelperK.label).plist"
        try? FileManager.default.removeItem(atPath: h)
        try FileManager.default.copyItem(atPath: src, toPath: h)
        try plistXML(allowUID: getuid()).write(toFile: p, atomically: true, encoding: .utf8)
        log("已暂存安装文件：\(h) / \(p)")
        return (h, p)
    }

    static func installSteps(staged: (helper: String, plist: String)) -> [PrivStep] {
        [
            PrivStep("/bin/mkdir", ["-p", "/usr/local/libexec"]),
            PrivStep("/bin/cp", [staged.helper, HelperK.binPath]),
            PrivStep("/usr/sbin/chown", ["root:wheel", HelperK.binPath]),
            PrivStep("/bin/chmod", ["755", HelperK.binPath]),
            PrivStep("/bin/cp", [staged.plist, HelperK.plistPath]),
            PrivStep("/usr/sbin/chown", ["root:wheel", HelperK.plistPath]),
            PrivStep("/bin/chmod", ["644", HelperK.plistPath]),
            PrivStep("/bin/launchctl", ["bootout", "system/\(HelperK.label)"],
                     note: "未加载时会失败，忽略", ignoreFailure: true),
            // 必须在 bootstrap 之前清旧 socket —— 放在后面会把 launchd 刚建好的 socket 删掉
            PrivStep("/bin/rm", ["-f", HelperK.socketPath],
                     note: "清掉上次遗留的 socket，让 launchd 重建", ignoreFailure: true),
            PrivStep("/bin/launchctl", ["bootstrap", "system", HelperK.plistPath]),
        ]
    }

    /// 卸载只允许动这三个白名单路径
    static let removablePaths = [HelperK.plistPath, HelperK.binPath, HelperK.socketPath]

    static func uninstallSteps() -> [PrivStep] {
        [
            PrivStep("/bin/launchctl", ["bootout", "system/\(HelperK.label)"],
                     note: "未加载时会失败，忽略", ignoreFailure: true),
            PrivStep("/bin/rm", ["-f", HelperK.plistPath]),
            PrivStep("/bin/rm", ["-f", HelperK.binPath]),
            PrivStep("/bin/rm", ["-f", HelperK.socketPath], ignoreFailure: true),
        ]
    }

    /// 安装后等 socket 就绪并 ping 通（launchd 建 socket 需要一点时间）
    static func waitUntilReady(seconds: Double = 8) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if HelperChannel.ping() != nil { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    static func install() -> (ok: Bool, text: String) {
        guard HelperChannel.binarySource != nil else {
            return (false, "找不到 autoz-helper，请先重新 build（./build.sh）")
        }
        if HelperChannel.ping() != nil {
            return (true, "免授权助手已经在运行，无需重复安装。")
        }
        let staged: (helper: String, plist: String)
        do { staged = try stage() } catch { return (false, error.localizedDescription) }

        let r = runPrivilegedPlan(installSteps(staged: staged), reason: "安装免授权助手")
        if r.cancelled { return (false, "已取消授权，未安装（改时区仍会每次弹框）。") }
        if !r.ok { return (false, "安装失败：\(r.summary)") }

        if waitUntilReady() {
            return (true, "免授权助手已装好：以后改时区不再弹授权框，重启系统也有效。")
        }
        return (false, "文件已就位，但助手没有响应。可看日志 \(HelperK.logPath)，或重启一次系统让它被 launchd 加载。")
    }

    static func uninstall() -> (ok: Bool, text: String) {
        let r = runPrivilegedPlan(uninstallSteps(), reason: "卸载免授权助手")
        if r.cancelled { return (false, "已取消授权，未卸载。") }
        if !r.ok { return (false, "卸载失败：\(r.summary)") }
        let leftovers = removablePaths.filter { FileManager.default.fileExists(atPath: $0) }
        if leftovers.isEmpty {
            return (true, "免授权助手已卸载，改时区会恢复成每次弹授权框。")
        }
        return (false, "部分文件仍在：\(leftovers.joined(separator: "、"))")
    }
}

// MARK: - 提权后端

enum PrivBackend: String {
    case helper      = "helper"       // 免授权助手（默认）：装过就零弹窗
    case native      = "native"       // 一次性授权：Security.framework
    case appleScript = "appleScript"  // 一次性授权：osascript
    var label: String {
        switch self {
        case .helper:      return "免授权助手（推荐）"
        case .native:      return "一次性授权 · 原生"
        case .appleScript: return "一次性授权 · AppleScript"
        }
    }
    var short: String {
        switch self {
        case .helper:      return "免授权"
        case .native:      return "原生"
        case .appleScript: return "AppleScript"
        }
    }
}

/// 以 argv 数组直接执行系统二进制（不经过 shell，因此没有任何字符串注入面）
func execPrivileged(_ auth: AuthorizationRef, _ tool: String, _ args: [String]) -> Int32 {
    var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
    cargs.append(nil)
    defer { for p in cargs where p != nil { free(p) } }
    return tool.withCString { t in
        cargs.withUnsafeMutableBufferPointer { buf in
            tzExecPriv(UnsafeMutableRawPointer(auth), t, buf.baseAddress)
        }
    }
}

/// 一次性授权路径会执行的特权命令（纯描述，供 --plan 审查；argv 直传、不经 shell）
func zoneSteps(zoneID: String, autoTZ: Bool?) -> [PrivStep] {
    var steps: [PrivStep] = []
    if let a = autoTZ {
        steps.append(PrivStep("/usr/bin/defaults",
                              ["write", K.autoTZPlist, "Active", "-bool", a ? "true" : "false"]))
    }
    steps.append(PrivStep("/usr/sbin/systemsetup", ["-settimezone", zoneID]))
    steps.append(PrivStep("/bin/ln", ["-sfn", K.zoneRoot + zoneID, "/etc/localtime"],
                          note: "systemsetup 未生效时的兜底"))
    steps.append(PrivStep("/usr/bin/notifyutil", ["-p", "com.apple.system.timezone"]))
    return steps
}

/// 统一校验：不信任何通道的自报，直接读 /etc/localtime 复核
func verifyZone(_ zoneID: String) -> ApplyOutcome {
    let now = systemZoneID()
    if now == zoneID { return .changed(zoneID) }
    if let a = TimeZone(identifier: now), let b = TimeZone(identifier: zoneID),
       a.secondsFromGMT(for: Date()) == b.secondsFromGMT(for: Date()) {
        return .changed(zoneID)
    }
    return .failed("写入后校验不一致（当前 /etc/localtime → \(now.isEmpty ? "未知" : now)）")
}

/// 设置系统时区（可选同时设自动时区开关）。
/// 通道优先级：免授权助手（零弹窗） → 一次性授权（原生 Security.framework → AppleScript）
func applySystemZone(_ zoneID: String, autoTZ: Bool? = nil) -> ApplyOutcome {
    guard isValidZoneID(zoneID) else {
        return .failed("时区标识非法：\(zoneID)")
    }
    let needZone = systemZoneID() != zoneID
    let needAuto = autoTZ.map { autoTimeZoneEnabled() != $0 } ?? false
    if !needZone && !needAuto {
        return .already(zoneID)
    }

    // ---------- 通道 0：免授权助手（装过就不弹框）----------
    if Store.shared.privBackend == .helper {
        if HelperChannel.socketExists {
            if let r = HelperChannel.setZone(zoneID, auto: needAuto ? autoTZ : nil) {
                if r.ok {
                    Store.shared.lastBackend = "helper（免授权）"
                    log("助手通道成功: \(r.msg) → zone=\(r.zone ?? "?") auto=\(r.auto.map(String.init) ?? "-")")
                    return verifyZone(zoneID)
                }
                // 助手明确拒绝或执行失败 → 直接报错。不再弹授权框：明知失败还打扰用户没有意义
                Store.shared.lastBackend = "helper（失败）"
                log("助手通道失败: \(r.msg)")
                return .failed(r.msg.isEmpty ? "助手拒绝执行（可能时区不在白名单）" : r.msg)
            }
            log("助手 socket 存在但无响应 → 回退一次性授权")
        } else {
            log("未安装免授权助手 → 走一次性授权（本次会弹授权框）")
        }
    }

    // ---------- 通道 1/2：一次性授权 ----------
    let r = runPrivilegedPlan(zoneSteps(zoneID: zoneID, autoTZ: needAuto ? autoTZ : nil),
                             reason: "设置系统时区 → \(zoneID)")
    if r.cancelled { return .cancelled }
    if !r.ok { return .failed(r.summary) }
    return verifyZone(zoneID)
}

// MARK: - 时间格式

func beijingZone() -> TimeZone {
    TimeZone(identifier: K.beijingID) ?? TimeZone(secondsFromGMT: 8 * 3600)!
}

/// 把系统「24 小时制」强制偏好的覆盖逻辑套到模板上
private func applyHourOverride(_ pattern: String) -> String {
    var p = pattern
    let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
    if let forced = global?["AppleICUForce24HourTime"] as? Bool {
        if forced {
            p = p.replacingOccurrences(of: "a", with: "")
                 .replacingOccurrences(of: "h", with: "H")
        } else if !p.contains("a") {
            p = p.replacingOccurrences(of: "H", with: "h") + " a"
        }
        p = p.trimmingCharacters(in: .whitespaces)
    }
    return p
}

/// 菜单栏标题格式：**跟随系统菜单栏时钟**（日期 + 星期 + 时间）
/// 实测 zh_CN 下模板 "MMMdEEEjmm" → "M月d日 EEE HH:mm" → 渲染「9月23日 周三 10:04」，
/// 与系统自带时钟「9月23日 周三 09:53」完全同款。
func titlePattern(showSeconds: Bool) -> String {
    let raw = DateFormatter.dateFormat(fromTemplate: "MMMdEEEjmm" + (showSeconds ? "ss" : ""),
                                       options: 0, locale: Locale.current)
        ?? (showSeconds ? "M月d日 EEE HH:mm:ss" : "M月d日 EEE HH:mm")
    return applyHourOverride(raw)
}

/// 仅时间的格式（菜单里用 —— 标题已经带日期了，不必重复）
func clockPattern(showSeconds: Bool) -> String {
    let raw = DateFormatter.dateFormat(fromTemplate: "jmm" + (showSeconds ? "ss" : ""),
                                       options: 0, locale: Locale.current)
        ?? (showSeconds ? "HH:mm:ss" : "HH:mm")
    return applyHourOverride(raw)
}

func formatter(pattern: String, zone: TimeZone) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale.current
    f.timeZone = zone
    f.dateFormat = pattern
    return f
}

/// 菜单栏标题文本（东八区）：日期 + 星期 + 时间
func beijingTimeText(showSeconds: Bool) -> String {
    formatter(pattern: titlePattern(showSeconds: showSeconds), zone: beijingZone()).string(from: Date())
}

/// 仅时间（东八区），菜单里用
func beijingClockText(showSeconds: Bool) -> String {
    formatter(pattern: clockPattern(showSeconds: showSeconds), zone: beijingZone()).string(from: Date())
}

func beijingDateText() -> String {
    let raw = DateFormatter.dateFormat(fromTemplate: "yMMMdEEE", options: 0, locale: Locale.current)
        ?? "yyyy年M月d日 EEE"
    let f = DateFormatter()
    f.locale = Locale.current
    f.timeZone = beijingZone()
    f.dateFormat = raw
    return f.string(from: Date())
}

/// 显示的东八区时间是否与系统当前时区「不是同一时刻的表盘」
func isOffSystemZone() -> Bool {
    let sys = TimeZone.current
    return sys.secondsFromGMT(for: Date()) != beijingZone().secondsFromGMT(for: Date())
}

// MARK: - 状态存档

final class Store {
    static let shared = Store()
    private let d = UserDefaults.standard

    var syncEnabled: Bool {
        get { d.bool(forKey: "syncEnabled") }
        set { d.set(newValue, forKey: "syncEnabled") }
    }
    /// 菜单栏是否显示秒。默认 false —— 跟随系统时钟的样子（系统时钟不带秒）
    var showSeconds: Bool {
        get { d.object(forKey: "showSeconds") == nil ? false : d.bool(forKey: "showSeconds") }
        set { d.set(newValue, forKey: "showSeconds") }
    }
    var originalZone: String? {
        get { d.string(forKey: "originalZone") }
        set { d.set(newValue, forKey: "originalZone") }
    }
    var originalAutoTZ: Bool? {
        get { d.object(forKey: "originalAutoTZ") == nil ? nil : d.bool(forKey: "originalAutoTZ") }
        set {
            if let v = newValue { d.set(v, forKey: "originalAutoTZ") }
            else { d.removeObject(forKey: "originalAutoTZ") }
        }
    }
    var lastDetection: Detection? {
        get { d.data(forKey: "lastDetection").flatMap { try? JSONDecoder().decode(Detection.self, from: $0) } }
        set { d.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastDetection") }
    }
    var lastSyncAt: Date? {
        get { d.object(forKey: "lastSyncAt") as? Date }
        set { d.set(newValue, forKey: "lastSyncAt") }
    }
    var lastAction: String {
        get { d.string(forKey: "lastAction") ?? "—" }
        set { d.set(newValue, forKey: "lastAction") }
    }
    /// 提权通道：默认「免授权助手」（装过就一直零弹窗），也可固定成一次性授权路线
    var privBackend: PrivBackend {
        get { d.string(forKey: "privBackend").flatMap { PrivBackend(rawValue: $0) } ?? .helper }
        set { d.set(newValue.rawValue, forKey: "privBackend") }
    }
    /// 配置版本，用于一次性迁移（v2：提权默认值由 native 改为 helper）
    var configVersion: Int {
        get { d.integer(forKey: "configVersion") }
        set { d.set(newValue, forKey: "configVersion") }
    }
    /// 上一次实际生效的后端（诊断用）
    var lastBackend: String {
        get { d.string(forKey: "lastBackend") ?? "—" }
        set { d.set(newValue, forKey: "lastBackend") }
    }

    /// 配置迁移：v2 把改时区通道默认值从「原生一次性授权」改成「免授权助手」。
    /// GUI 与 CLI 入口都会调用，避免两个入口看到不同的配置。
    func migrateIfNeeded() {
        if configVersion < 2 {
            log("配置迁移 → v2：改时区通道默认改为「免授权助手」（原值 \(privBackend.rawValue)）")
            privBackend = .helper
            configVersion = 2
        }
        if configVersion < 3 {
            log("配置迁移 → v3：标题格式改为跟随系统时钟（日期+星期+时间，默认不带秒）")
            showSeconds = false
            configVersion = 3
        }
    }
}

// MARK: - 菜单栏 App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var lastTitle = ""
    private var busy = false
    private let store = Store.shared

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.imagePosition = .noImage
            b.font = menuBarTitleFont
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        for name in [NSNotification.Name.NSSystemTimeZoneDidChange,
                     NSLocale.currentLocaleDidChangeNotification,
                     NSNotification.Name.NSSystemClockDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(externalChange),
                                                   name: name, object: nil)
        }

        // 配置迁移 v2：改时区通道默认值由「原生一次性授权」改为「免授权助手」
        store.migrateIfNeeded()

        // 首次运行把开机自启默认打开，省得用户哪天想起来才发现一直没开
        LoginItem.applyFirstRunDefault()

        // 高级配置窗口的动作交回本类实现（界面层不碰业务）
        AdvancedWindowController.shared.actions = self

        // 上次退出时同步是开着的 → 继续跟随
        if store.syncEnabled { startFollowing() }

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        // 用自绘图标替换 bundle 图标（构建时已写 AppIcon.icns，运行期再兜一层，保证 Dock/关于窗口一致）
        NSApp.applicationIconImage = Artwork.iconImage(size: 256)
        log("AutoZ \(K.version) 启动；系统时区=\(systemZoneID()) 自动时区=\(String(describing: autoTimeZoneEnabled())) 通道=\(store.privBackend.rawValue)")
        // 助手探测放到主线程异步做，避免阻塞启动首帧
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let ok = self.helperReady
            log("助手状态：plist=\(HelperChannel.plistInstalled) bin=\(HelperChannel.binaryInstalled) socket=\(HelperChannel.socketExists) 就绪=\(ok)")
        }
        // 视觉自检开关：--show-menu 时自动把菜单弹出，便于截图核对版式（不必手点）
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, let m = self.statusItem.menu else { return }
                // 用屏幕坐标（in: nil）弹出，比 in: button 更可靠；
                // Cocoa 原点在左下角，菜单栏项窗口底边就是菜单应该出现的位置
                let wf = self.statusItem.button?.window?.frame
                let at = NSPoint(x: wf?.minX ?? 2600, y: (wf?.minY ?? 1410) - 6)
                log("自检：自动弹出菜单以便截图，位置=\(NSStringFromPoint(at))")
                m.popUp(positioning: nil, at: at, in: nil)
            }
        }

        // 视觉自检开关：--show-console / --show-toast 分别自动打开高级配置窗口、弹一条通知，便于截图核对
        if CommandLine.arguments.contains("--show-console") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                log("自检：自动打开高级配置窗口以便截图")
                AdvancedWindowController.shared.show()
            }
        }
        if CommandLine.arguments.contains("--show-toast") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                log("自检：自动弹出通知横幅以便截图")
                notify(title: "AutoZ 同步完成",
                       message: "出口 IP 192.0.2.1 · Los Angeles, California, US → America/Los_Angeles")
            }
        }

        // 回归自检：从后台队列发通知（曾经这里会崩 —— 在非主线程创建 NSPanel）
        if CommandLine.arguments.contains("--show-toast-offthread") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                DispatchQueue.global(qos: .userInitiated).async {
                    log("自检：从后台队列发通知（验证主线程派发）")
                    notify(title: "AutoZ 后台通知测试",
                           message: "这条是从后台队列发出的；能正常显示说明跨线程通知没问题。")
                }
            }
        }

        // 用户双击 .app 启动时（app 被激活到前台）给个反馈：本程序没有 Dock 图标，
        // 不打开点东西会显得"点了没反应"。由登录项/launchd 启动时不会被激活，不打扰。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if NSApp.isActive, !CommandLine.arguments.contains("--show-console") {
                log("检测到用户主动启动 → 自动打开高级配置")
                AdvancedWindowController.shared.show()
            }
        }

        // 状态栏项自检：用程序内部数据确认它真的挂在菜单栏上（外部截图不可靠）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, let b = self.statusItem.button else {
                log("状态栏项自检: button 不存在")
                return
            }
            log("状态栏项自检: isVisible=\(self.statusItem.isVisible) length=\(String(format: "%.1f", self.statusItem.length)) "
                + "buttonFrame=\(NSStringFromRect(b.frame)) 屏幕坐标=\(b.window.map { NSStringFromRect($0.frame) } ?? "无窗口") "
                + "标题=\"\(b.attributedTitle.string)\" 颜色=\(b.attributedTitle.length > 0 ? "\(b.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) ?? "无")" : "无")")
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        log("AutoZ 退出")
    }

    // ---- 标题渲染 ----

    private func tick() {
        let showSec = store.showSeconds
        // 标题就是纯时间。早先前置过一个「◷」标识符，但它笔画极细、在菜单栏里几乎看不见，
        // 起不到辨识作用反而显脏，已去掉。
        let text = beijingTimeText(showSeconds: showSec)
        let off = isOffSystemZone()
        // 不一致时标橙色而不是纯红：红色在彩色壁纸和深色菜单栏上容易过冲发闷，
        // 橙色同样一眼看得出「这不是本机时间」，又没那么刺眼。
        let color: NSColor = off ? .systemOrange : .labelColor

        let attrs: [NSAttributedString.Key: Any] = [
            .font: menuBarTitleFont,
            .foregroundColor: color,
        ]
        if text != lastTitle || statusItem.button?.attributedTitle.string.isEmpty == true {
            statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
            lastTitle = text
        } else {
            // 颜色可能因系统时区变化而需刷新
            statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        }
        statusItem.button?.toolTip = tooltipText()
    }

    private func tooltipText() -> String {
        let sys = systemZoneID()
        var lines = ["东八区（\(K.beijingID)）\(beijingTimeText(showSeconds: true))",
                     "系统时区：\(sys.isEmpty ? "未知" : sys)"]
        if isOffSystemZone() {
            lines.append("⚠️ 显示的不是本机时区时间")
        }
        if let det = store.lastDetection {
            lines.append("出口：\(det.ip) \(det.locationText)")
            lines.append("解析时区：\(det.zoneID)")
        }
        return lines.joined(separator: "\n")
    }

    @objc private func externalChange() {
        log("系统时区/区域变化 → 系统时区=\(systemZoneID())")
        DispatchQueue.main.async {
            self.lastTitle = ""
            self.tick()
            self.rebuildMenu()
        }
    }

    // ---- 菜单 ----

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    // ---- 菜单（数据驱动：先建行模型 → 再渲染；同一模型可打印成文本供审查）----
    //
    // 主次约定：顶部 3 行状态 → 两个主操作（加粗，同步 / 恢复）→ 免授权模式状态 →
    //          其余全部收进「更多」子菜单 → 退出。菜单整体控制在 10 行以内（不含子菜单）。

    enum RowStyle { case strong, info, primary, normal }

    enum MRow {
        case info(String, RowStyle)
        case action(title: String, sel: Selector?, enabled: Bool, checked: Bool, style: RowStyle, tip: String?)
        case submenu(title: String, rows: [MRow])
        case sep
    }

    /// 助手是否就绪（带 5s 缓存，避免每次开菜单都等一次 ping）
    private var helperReadyCache: (at: Date, ok: Bool)?
    private var helperReady: Bool {
        if let c = helperReadyCache, Date().timeIntervalSince(c.at) < 5 { return c.ok }
        let ok = HelperChannel.ping() != nil
        helperReadyCache = (Date(), ok)
        return ok
    }

    func menuModel() -> [MRow] {
        let sys = systemZoneID()
        let off = isOffSystemZone()
        var rows: [MRow] = []

        // ── 1. 状态：只留三行，够判断就行（其余细节都在高级配置窗口里）
        rows.append(.info("东八区  \(beijingClockText(showSeconds: true))   \(beijingDateText())", .strong))
        rows.append(.info("系统时区  \(sys.isEmpty ? "未知" : sys)\(off ? "   ⚠️ 非东八区，标题已变橙" : "   ✓ 与显示一致")", .info))
        if let det = store.lastDetection {
            rows.append(.info("出口  \(det.ip) · \(det.locationText)  →  \(det.zoneID)", .info))
        } else {
            rows.append(.info("出口  尚未检测", .info))
        }

        rows.append(.sep)

        // ── 2. 主操作：把「同步开关 / 立即执行一次 / 退回原时区」三件事分开，别再互相混
        let orig = store.originalZone
        if store.syncEnabled {
            rows.append(.action(title: "关闭同步（保持当前时区）", sel: #selector(toggleSync(_:)),
                                enabled: !busy, checked: true, style: .primary,
                                tip: "只是不再自动跟随出口 IP；想变回原来的时区，用下面的「恢复到开启前的时区」"))
        } else {
            rows.append(.action(title: "开启同步（跟随出口 IP）", sel: #selector(toggleSync(_:)),
                                enabled: !busy, checked: false, style: .primary,
                                tip: "打开后按出口 IP 把系统时区设成对应时区；装了免授权助手则不弹授权框"))
        }
        rows.append(.action(title: "立即检查并同步（执行一次）", sel: #selector(checkAndSync(_:)),
                            enabled: !busy, checked: false, style: .normal,
                            tip: "不管开关状态，现在就查一次出口 IP 并应用（未装助手时会弹授权框）"))
        rows.append(.action(title: orig.map { "恢复到开启前的时区（\($0)）" } ?? "恢复到开启前的时区（无可恢复记录）",
                            sel: #selector(restoreOriginal(_:)), enabled: !busy && orig != nil,
                            checked: false, style: .primary,
                            tip: "把系统时区改回开启同步之前的值，还原「自动设置时区」开关，并关闭同步"))

        rows.append(.sep)

        // ── 3. 其余一切（关于、显示、通道、助手、诊断…）都在高级配置窗口里，菜单不再堆子菜单
        rows.append(.action(title: "高级配置…", sel: #selector(showConsole(_:)),
                            enabled: true, checked: false, style: .normal,
                            tip: "关于、菜单栏显示、改时区通道、助手安装卸载、诊断都在这里"))

        rows.append(.sep)
        rows.append(.action(title: "退出 AutoZ", sel: #selector(quitApp(_:)),
                            enabled: true, checked: false, style: .normal, tip: nil))

        if busy {
            rows.append(.sep)
            rows.append(.info("⏳ 正在检测 / 等待系统授权…", .info))
        }
        return rows
    }

    private func attrs(style: RowStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case .strong:
            // 菜单项字号跟随系统（NSFont.menuFont(ofSize: 0) 也是 13）。早先写 12pt，
            // 和下面 13pt 的正常行并排时明显矮一截。
            return [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.labelColor]
        case .info:
            return [.font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor]
        case .primary:
            return [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.labelColor]
        case .normal:
            return [.font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor]
        }
    }

    private func render(_ rows: [MRow], into menu: NSMenu) {
        for row in rows {
            switch row {
            case .sep:
                menu.addItem(.separator())

            case .info(let text, let style):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.attributedTitle = NSAttributedString(string: text, attributes: attrs(style: style))
                menu.addItem(item)

            case .action(let title, let sel, let enabled, let checked, let style, let tip):
                let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                item.target = self
                item.isEnabled = enabled
                item.state = checked ? .on : .off
                item.toolTip = tip
                item.attributedTitle = NSAttributedString(string: title, attributes: attrs(style: style))
                menu.addItem(item)

            case .submenu(let title, let sub):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(string: title, attributes: attrs(style: .normal))
                let m = NSMenu()
                render(sub, into: m)
                item.submenu = m
                menu.addItem(item)
            }
        }
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        render(menuModel(), into: menu)
    }

    /// 把菜单渲染成文本（供 CLI --menu 审查，不用肉眼点菜单）
    func menuPreviewText() -> String {
        var out: [String] = []
        func walk(_ rows: [MRow], _ depth: Int) {
            let pad = String(repeating: "    ", count: depth)
            for r in rows {
                switch r {
                case .sep:
                    out.append(pad + "──────────────────────────")
                case .info(let t, let s):
                    out.append(pad + (s == .strong ? "【\(t)】" : "   \(t)"))
                case .action(let t, _, let en, let ck, let st, let tip):
                    let mark = ck ? "[✓] " : (en ? "" : "[禁用] ")
                    let body = st == .primary ? "** \(t) **" : t
                    out.append(pad + mark + body + (tip != nil ? "   ⟨有提示⟩" : ""))
                case .submenu(let t, let sub):
                    out.append(pad + "\(t) ▸")
                    walk(sub, depth + 1)
                }
            }
        }
        walk(menuModel(), 0)
        return out.joined(separator: "\n")
    }

    // ---- 自动跟随（同步开关打开时的后台行为）----
    //
    // 「开启同步」不能只是记一个状态：这里真的去跟随 ——
    //   · 网络变化（切 WiFi / 开 VPN）后延时 15 秒检测一次出口 IP
    //   · 另有 10 分钟兜底轮询，防止漏检
    // 装了免授权助手就静默应用；没装则只发通知提醒（后台自动动作不该突然冒出一个密码框）。

    private var followTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var followInFlight = false

    private func startFollowing() {
        guard followTimer == nil else { return }
        if pathMonitor == nil {
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                    self?.followCheck(reason: "网络变化")
                }
            }
            m.start(queue: DispatchQueue(label: "autoz.path"))
            pathMonitor = m
        }
        followTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.followCheck(reason: "定时")
        }
        log("自动跟随已启动（网络变化 + 每 10 分钟兜底）")
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        log("自动跟随已停止")
    }

    /// 检测出口 IP 对应时区；与当前系统时区不同才动手
    private func followCheck(reason: String) {
        guard store.syncEnabled, !busy, !followInFlight else { return }
        followInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let det = try? Checker.run()
            DispatchQueue.main.async {
                self.followInFlight = false
                guard let det = det else {
                    log("自动跟随（\(reason)）检测失败")
                    return
                }
                self.store.lastDetection = det
                let cur = systemZoneID()
                guard det.zoneID != cur else {
                    log("自动跟随（\(reason)）：仍是 \(cur)，无需改动")
                    return
                }
                if HelperChannel.socketExists {
                    log("自动跟随（\(reason)）：\(cur) → \(det.zoneID)")
                    let out = applySystemZone(det.zoneID, autoTZ: false)
                    switch out {
                    case .changed(let z):
                        self.store.lastAction = "自动跟随 → \(z)"
                        notify(title: "AutoZ 已自动跟随出口 IP", message: "\(det.locationText) → 系统时区已设为 \(z)")
                    case .failed(let e):
                        notify(title: "AutoZ 自动跟随失败", message: e)
                    default:
                        break
                    }
                } else {
                    self.store.lastAction = "出口变化：\(det.zoneID)（未跟随）"
                    notify(title: "AutoZ 检测到出口时区变化",
                           message: "\(det.locationText) → \(det.zoneID)。点菜单「立即检查并同步」应用（装免授权助手后可自动跟随）")
                }
                self.refresh()
            }
        }
    }

    // ---- 动作 ----

    @objc private func toggleSync(_ sender: NSMenuItem) {
        if store.syncEnabled {
            // 只关开关，不动系统时区 —— 「退回原时区」是另一件事（菜单里单独一项），
            // 这样两个动作的语义不会再互相混。
            store.syncEnabled = false
            store.lastAction = "已关闭同步（时区保持 \(systemZoneID())）"
            stopFollowing()
            log("关闭同步开关（不修改系统时区）")
            let tip = store.originalZone.map { "，当前仍为 \(systemZoneID())；想回到 \($0) 用「恢复到开启前的时区」" } ?? ""
            notify(title: "AutoZ 已关闭同步", message: "不再跟随出口 IP\(tip)。")
            refresh()
        } else {
            store.syncEnabled = true
            if store.originalZone == nil {
                let cur = systemZoneID()
                store.originalZone = cur
                store.originalAutoTZ = autoTimeZoneEnabled()
                log("记录原始状态：时区=\(cur) 自动时区=\(String(describing: autoTimeZoneEnabled()))")
            }
            store.lastAction = "已打开同步"
            startFollowing()
            notify(title: "AutoZ 已开启同步", message: "正在按出口 IP 检测并设置系统时区…")
            perform(apply: true)
        }
        rebuildMenu()
    }

    @objc private func checkAndSync(_ sender: NSMenuItem) {
        if store.originalZone == nil {
            store.originalZone = systemZoneID()
            store.originalAutoTZ = autoTimeZoneEnabled()
        }
        store.lastAction = "立即检查并同步"
        perform(apply: true)
    }

    @objc private func checkOnly(_ sender: NSMenuItem) {
        store.lastAction = "仅查询"
        perform(apply: false)
    }

    @objc private func restoreOriginal(_ sender: NSMenuItem) {
        guard let orig = store.originalZone else { return }
        store.lastAction = "手动恢复 \(orig)"
        after { [weak self] in
            guard let self = self else { return }
            let out = applySystemZone(orig, autoTZ: self.store.originalAutoTZ)
            switch out {
            case .changed, .already:
                notify(title: "AutoZ 已恢复", message: "系统时区 = \(orig)，并还原自动设置时区开关。")
                self.store.originalZone = nil
                self.store.originalAutoTZ = nil
                self.store.syncEnabled = false
                self.stopFollowing()
            case .cancelled:
                notify(title: "AutoZ", message: "已取消，未修改系统时区")
            case .failed(let e):
                notify(title: "AutoZ 恢复失败", message: e)
            }
            self.refresh()
        }
    }

    @objc private func toggleSeconds(_ sender: NSMenuItem) {
        store.showSeconds.toggle()
        lastTitle = ""
        refresh()
    }

    @objc private func useHelperBackend(_ sender: NSMenuItem) {
        store.privBackend = .helper
        log("改时区通道 → \(store.privBackend.rawValue)")
        refresh()
    }

    @objc private func useNativeBackend(_ sender: NSMenuItem) {
        store.privBackend = .native
        log("改时区通道 → \(store.privBackend.rawValue)（每次都弹授权框）")
        refresh()
    }

    @objc private func useAppleScriptBackend(_ sender: NSMenuItem) {
        store.privBackend = .appleScript
        log("改时区通道 → \(store.privBackend.rawValue)（每次都弹授权框）")
        refresh()
    }

    /// 安装免授权助手：这是唯一还需要输一次密码的地方，之后改时区零弹窗
    @objc private func installHelper(_ sender: NSMenuItem) {
        log("开始安装免授权助手")
        after { [weak self] in
            guard let self = self else { return }
            let r = HelperInstaller.install()
            self.helperReadyCache = nil
            self.store.lastAction = r.ok ? "免授权助手已安装" : "免授权助手安装未完成"
            notify(title: r.ok ? "AutoZ 免授权模式已启用" : "AutoZ 安装未完成", message: r.text)
            self.refresh()
        }
    }

    @objc private func uninstallHelper(_ sender: NSMenuItem) {
        let a = NSAlert()
        a.messageText = "卸载免授权助手？"
        a.informativeText = """
        会移除这三个文件：
        ・\(HelperK.plistPath)
        ・\(HelperK.binPath)
        ・\(HelperK.socketPath)

        卸载后改时区会恢复成「每次弹一次授权框」。需要一次管理员授权。
        """
        a.addButton(withTitle: "取消")
        a.addButton(withTitle: "卸载")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertSecondButtonReturn else { return }

        after { [weak self] in
            guard let self = self else { return }
            let r = HelperInstaller.uninstall()
            self.helperReadyCache = nil
            self.store.lastAction = r.ok ? "免授权助手已卸载" : "免授权助手卸载未完成"
            notify(title: r.ok ? "AutoZ 已退出免授权模式" : "AutoZ 卸载未完成", message: r.text)
            self.refresh()
        }
    }

    @objc private func openDateSettings(_ sender: NSMenuItem) {
        // 原生 API：NSWorkspace 打开系统设置深链（macOS 13+ 用 Settings 扩展 URL，旧系统回退到 preference pane）
        if !openDateAndTimeSettings() {
            log("打开「日期与时间」设置失败")
            notify(title: "AutoZ", message: "无法打开系统「日期与时间」设置面板", sound: nil)
        }
    }

    @objc private func copyDiagnostics(_ sender: NSMenuItem) {
        let text = diagnosticsText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notify(title: "AutoZ", message: "诊断信息已复制到剪贴板", sound: nil)
    }

    @objc private func testNotification(_ sender: NSMenuItem) {
        notify(title: "AutoZ 通知测试",
               message: "这就是同步完成时右上角横幅的样子（程序内自绘，不经过系统通知）")
    }

    private func diagnosticsText() -> String {
        var out: [String] = []
        out.append("AutoZ \(K.version) 诊断信息  \(stamp(Date()))")
        out.append("系统版本: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("显示时间(东八区): \(beijingTimeText(showSeconds: store.showSeconds))")
        out.append("标题模板: \(titlePattern(showSeconds: store.showSeconds))  （跟随系统菜单栏时钟）")
        out.append("时间模板: \(clockPattern(showSeconds: store.showSeconds))  显示秒=\(store.showSeconds)")
        out.append("系统时区: \(systemZoneID())")
        out.append("自动设置时区: \(String(describing: autoTimeZoneEnabled()))")
        out.append("同步开关: \(store.syncEnabled ? "开" : "关")  原始时区记录: \(store.originalZone ?? "无")")
        out.append("最近动作: \(store.lastAction)")
        out.append("改时区通道: \(store.privBackend.rawValue)（上次实际用: \(store.lastBackend)）")
        out.append("免授权助手: \(HelperChannel.statusText)")
        out.append("开机自启: \(LoginItem.statusText)")
        out.append("  \(LoginItem.plistURL.path)")
        out.append("  plist 存在=\(HelperChannel.plistInstalled)  二进制存在=\(HelperChannel.binaryInstalled)  socket 存在=\(HelperChannel.socketExists)")
        out.append("通知通道: 程序内自绘横幅（零系统权限，样式见 ui.swift）")
        if let d = store.lastDetection {
            out.append("检测来源: \(d.source)  \(stamp(d.fetchedAt))")
            out.append("出口 IP: \(d.ip)  \(d.locationText)  \(d.org)")
            out.append("解析时区: \(d.zoneID)  ← \(d.zoneSource)")
            out.append("原始响应:\n\(d.rawJSON)")
        } else {
            out.append("检测来源: 无")
        }
        return out.joined(separator: "\n")
    }

    @objc private func showConsole(_ sender: Any?) {
        // 高级配置窗口（见 ui.swift）：关于 + 全部次级操作，实底高对比
        AdvancedWindowController.shared.show()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // ---- 检测流程 ----

    private func after(_ work: @escaping () -> Void) {
        busy = true
        rebuildMenu()
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async { self.busy = false; self.refresh() }
        }
    }

    private func perform(apply: Bool) {
        busy = true
        rebuildMenu()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let outcome: ApplyOutcome?
            var detection: Detection?
            var errorText: String?
            do {
                let det = try Checker.run()
                detection = det
                log("检测成功: \(det.ip) \(det.locationText) → \(det.zoneID) (\(det.zoneSource))")
                if apply {
                    // 同步时一并关闭「自动设置时区」，否则系统会用定位把时区改回去
                    outcome = applySystemZone(det.zoneID, autoTZ: false)
                } else {
                    outcome = nil
                }
            } catch {
                errorText = error.localizedDescription
                outcome = nil
                log("检测失败: \(errorText ?? "?")")
            }

            DispatchQueue.main.async {
                self.busy = false
                if let det = detection { self.store.lastDetection = det }

                if let err = errorText {
                    self.store.lastAction = "检测失败"
                    notify(title: "AutoZ 检测失败", message: err)
                    self.refresh()
                    return
                }
                guard let det = detection else { self.refresh(); return }

                if !apply {
                    self.store.lastAction = "仅查询：\(det.zoneID)"
                    notify(title: "AutoZ 检测结果",
                           message: "\(det.ip) · \(det.locationText) → \(det.zoneID)（未修改系统时区）")
                    self.refresh()
                    return
                }

                switch outcome! {
                case .changed(let z):
                    self.store.lastSyncAt = Date()
                    self.store.lastAction = "已设为 \(z)"
                    notify(title: "AutoZ 时区已更新",
                           message: "\(det.ip) · \(det.locationText) → \(z)；已关闭「自动设置时区」，避免被定位改回。")
                    self.rebuildMenu()
                    self.refresh()
                case .already(let z):
                    self.store.lastSyncAt = Date()
                    self.store.lastAction = "已是 \(z)"
                    notify(title: "AutoZ", message: "系统时区已经是 \(z)，无需修改。")
                    self.refresh()
                case .cancelled:
                    self.store.lastAction = "授权被取消"
                    notify(title: "AutoZ", message: "已取消授权，系统时区未修改（目标：\(det.zoneID)）")
                    self.refresh()
                case .failed(let e):
                    self.store.lastAction = "设置失败"
                    notify(title: "AutoZ 设置失败", message: e)
                    self.refresh()
                }
            }
        }
    }

    private func refresh() {
        // 有些调用点在工作队列上（例如 after{} 里的收尾），而菜单/窗口都是 UI，必须回主线程
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        lastTitle = ""
        tick()
        rebuildMenu()
        // 高级配置窗口开着就一起刷新（界面层不反向调用业务，所以由这里统一推）
        if AdvancedWindowController.shared.window?.isVisible == true {
            AdvancedWindowController.shared.refresh()
        }
    }
}

// MARK: - 命令行模式（便于脚本/测试）

func runCLI(_ args: [String]) -> Int32 {
    func pr(_ s: String) { print(s) }
    Store.shared.migrateIfNeeded()

    switch args[0] {
    case "--check", "--query":
        do {
            let d = try Checker.run()
            pr("ip:        \(d.ip)")
            pr("location:  \(d.locationText)")
            pr("org:       \(d.org)")
            pr("source:    \(d.source)")
            pr("timezone:  \(d.zoneID)")
            pr("how:       \(d.zoneSource)")
            return 0
        } catch { pr("ERROR: \(error.localizedDescription)"); return 2 }

    case "--apply":
        do {
            let d = try Checker.run()
            pr("检测: \(d.ip) \(d.locationText) → \(d.zoneID) (\(d.zoneSource))")
            switch applySystemZone(d.zoneID) {
            case .changed(let z): pr("OK: 系统时区已设为 \(z)"); return 0
            case .already(let z): pr("OK: 系统时区已经是 \(z)"); return 0
            case .cancelled:      pr("CANCELLED: 未获授权"); return 3
            case .failed(let e):  pr("FAILED: \(e)"); return 4
            }
        } catch { pr("ERROR: \(error.localizedDescription)"); return 2 }

    case "--set":
        guard args.count > 1, isValidZoneID(args[1]) else { pr("用法: AutoZ --set <IANA 时区，如 Asia/Tokyo>"); return 1 }
        switch applySystemZone(args[1]) {
        case .changed(let z): pr("OK: 系统时区已设为 \(z)"); return 0
        case .already(let z): pr("OK: 系统时区已经是 \(z)"); return 0
        case .cancelled:      pr("CANCELLED"); return 3
        case .failed(let e):  pr("FAILED: \(e)"); return 4
        }

    case "--system":
        pr("系统时区:   \(systemZoneID())")
        pr("自动设时区: \(String(describing: autoTimeZoneEnabled()))")
        pr("进程缓存:   \(TimeZone.current.identifier)")
        return 0

    case "--format":
        pr("locale:        \(Locale.current.identifier)")
        pr("显示秒:        \(Store.shared.showSeconds)")
        pr("标题模板:      \(titlePattern(showSeconds: Store.shared.showSeconds))   ← 跟随系统菜单栏时钟")
        pr("时间模板:      \(clockPattern(showSeconds: Store.shared.showSeconds))")
        pr("标题文本:      \(beijingTimeText(showSeconds: Store.shared.showSeconds))")
        pr("仅时间(秒):    \(beijingClockText(showSeconds: true))")
        pr("东八区日期:    \(beijingDateText())")
        pr("与系统不一致:  \(isOffSystemZone() ? "是（标题显示为橙色）" : "否（标题为默认色）")")
        return 0

    case "--icon-preview":
        guard args.count > 2, let size = Double(args[2]) else {
            pr("用法: AutoZ --icon-preview <输出.png> <尺寸>"); return 1
        }
        guard let data = Artwork.pngData(size: CGFloat(size)) else { pr("绘制失败"); return 1 }
        do {
            try data.write(to: URL(fileURLWithPath: args[1]))
            pr("已导出 \(args[1])（\(Int(size))px）")
            return 0
        } catch { pr("写入失败: \(error)"); return 1 }

    case "--notify-test":
        pr("通知横幅是程序内自绘的，只有 GUI 在跑才看得见。")
        pr("  · GUI 已运行：菜单「更多 ▸ 测试通知」")
        pr("  · 从头验证：/usr/bin/open /Applications/AutoZ.app --args --notify-test")
        notify(title: "AutoZ 通知测试", message: "CLI 触发的通知（GUI 在跑时才会显示横幅）")
        pr("已记一条日志到 \(K.logPath)。")
        return 0

    case "--print-osa", "--plan":
        let zone = args.count > 1 ? args[1] : (try? Checker.run().zoneID) ?? K.beijingID
        guard isValidZoneID(zone) else { pr("非法时区: \(zone)"); return 1 }
        pr("目标时区:      \(zone)")
        pr("当前系统时区:  \(systemZoneID())")
        pr("自动时区开关:  \(String(describing: autoTimeZoneEnabled()))")
        pr("软链应指向:    \(K.zoneRoot)\(zone)")
        pr("")
        pr("=== 通道 0：免授权助手（装了就零弹窗）===")
        pr("socket: \(HelperK.socketPath)  存在=\(HelperChannel.socketExists)")
        pr("plist:  \(HelperK.plistPath)  存在=\(HelperChannel.plistInstalled)")
        pr("二进制: \(HelperK.binPath)  存在=\(HelperChannel.binaryInstalled)")
        if let r = HelperChannel.ping() {
            pr("ping:   ✓ \(r.msg)  助手视角时区=\(r.raw["zone"] as? String ?? "?")")
            pr("将发送: {\"cmd\":\"set_zone\",\"zone\":\"\(zone)\",\"auto\":false}")
        } else {
            pr("ping:   ✗ 无响应 → 会回退到下面的通道 1/2（每次都会弹授权框）")
        }
        pr("")
        pr("=== 通道 1：原生 Security.framework（argv 直传，不经过 shell）===")
        pr("AuthorizationCreate(nil, nil, [.interactionAllowed, .extendRights, .preAuthorize])")
        for c in zoneSteps(zoneID: zone, autoTZ: false) {
            pr("  \(c.display)\(c.note.map { "   ← \($0)" } ?? "")")
        }
        pr("")
        pr("=== 通道 2：AppleScript 回退 ===")
        pr(buildOsaCommand(zoneID: zone, autoTZ: false))
        pr("")
        pr("（以上仅为打印，未执行任何提权操作）")
        return 0

    case "--menu":
        pr(AppDelegate().menuPreviewText())
        return 0

    case "--helper-status":
        pr("免授权助手状态")
        pr("  标签:     \(HelperK.label)")
        pr("  socket:   \(HelperK.socketPath)  存在=\(HelperChannel.socketExists)")
        pr("  plist:    \(HelperK.plistPath)  存在=\(HelperChannel.plistInstalled)")
        pr("  二进制:   \(HelperK.binPath)  存在=\(HelperChannel.binaryInstalled)")
        pr("  待装来源: \(HelperChannel.binarySource ?? "（找不到，需要重新 build）")")
        pr("  allow uid: \(getuid())")
        pr("  日志:     \(HelperK.logPath)")
        if let r = HelperChannel.ping() {
            pr("  ping:     ✓ \(r.msg)  版本=\(r.raw["version"] as? String ?? "?")  助手 pid=\(r.raw["pid"] as? Int ?? -1)")
            pr("            助手视角时区=\(r.raw["zone"] as? String ?? "?")  自动时区=\(r.raw["auto"].map { "\($0)" } ?? "-")")
            pr("  结论:     已启用 —— 改时区不再弹授权框")
        } else {
            pr("  ping:     ✗ 无响应")
            pr("  结论:     未启用 —— 改时区会每次弹授权框（可点菜单里的「免授权模式 未安装 · 点此安装」）")
        }
        return 0

    case "--helper-plan":
        pr("=== 安装免授权助手：将执行的特权命令（仅打印）===")
        if let src = HelperChannel.binarySource {
            let staged = (helper: K.appSupport + "/install/autoz-helper",
                          plist: K.appSupport + "/install/\(HelperK.label).plist")
            pr("① 非特权步骤（落到用户目录）")
            pr("  cp \(src) → \(staged.helper)")
            pr("  写 \(staged.plist)（allow-uid=\(getuid())）")
            pr("② 特权步骤（一次授权）")
            for (i, s) in HelperInstaller.installSteps(staged: staged).enumerated() {
                pr("  \(i + 1). \(s.display)\(s.note.map { "   ← \($0)" } ?? "")")
            }
        } else {
            pr("找不到 autoz-helper，请先 ./build.sh")
        }
        pr("")
        pr("=== 卸载：将执行的特权命令（仅打印）===")
        for (i, s) in HelperInstaller.uninstallSteps().enumerated() {
            pr("  \(i + 1). \(s.display)\(s.note.map { "   ← \($0)" } ?? "")")
        }
        pr("")
        pr("卸载只会动这三个白名单路径：")
        for p in HelperInstaller.removablePaths { pr("  \(p)") }
        return 0

    case "--helper-install":
        let r = HelperInstaller.install()
        pr(r.ok ? "OK: \(r.text)" : "未完成: \(r.text)")
        return r.ok ? 0 : 4

    case "--helper-uninstall":
        let r = HelperInstaller.uninstall()
        pr(r.ok ? "OK: \(r.text)" : "未完成: \(r.text)")
        return r.ok ? 0 : 4

    case "--login-status":
        pr("开机自启: \(LoginItem.statusText)")
        pr("  配置文件: \(LoginItem.plistURL.path)\(LoginItem.isEnabled ? "" : "（不存在）")")
        pr("  当前 App: \(Bundle.main.bundlePath)")
        pr("  生效时机: 下次登录（launchd 只在登录时读取 LaunchAgents）")
        pr("  撤销方式: AutoZ --login-disable，或「系统设置 → 通用 → 登录项」")
        return 0

    // 注意：args 是去掉程序名之后的参数，单参数的开关里**不能**写 args[1]，会越界崩溃。
    // 所以这里拆成两个 case，而不是合并后用 args[1] 判断。
    case "--login-enable":
        if let err = LoginItem.set(true) {
            pr("开启开机自启失败: \(err)")
            return 4
        }
        pr("OK: 开机自启 → \(LoginItem.statusText)")
        return 0

    case "--login-disable":
        if let err = LoginItem.set(false) {
            pr("关闭开机自启失败: \(err)")
            return 4
        }
        pr("OK: 开机自启 → \(LoginItem.statusText)")
        return 0

    case "--notify-status":
        pr("bundle id: \(bundleID)")
        pr("通知通道: 程序内自绘横幅（ToastCenter，见 Sources/ui.swift）")
        pr("  · 不使用 osascript，也不依赖系统通知权限")
        pr("  · 触发时机：同步成功/失败、恢复、助手安装/卸载")
        pr("  · 想看实际效果：GUI 里用「更多 ▸ 测试通知」，或直接跑 --notify-test")
        pr("  · 历史记录：~/Library/Logs/AutoZ.log（无论有没有 GUI 都会记录）")
        return 0

    case "--backend":
        guard args.count > 1, let b = PrivBackend(rawValue: args[1]) else {
            pr("用法: AutoZ --backend helper|native|appleScript"); return 1
        }
        Store.shared.privBackend = b
        pr("改时区通道已设为: \(b.label)")
        return 0

    case "--version":
        pr("AutoZ \(K.version)"); return 0

    default:
        pr("""
        AutoZ \(K.version) — \(appDisplayName)（\(appTagline)）

        用法:
          AutoZ                  启动菜单栏程序（无参数）
          AutoZ --check          仅查询出口 IP 与对应时区，不修改系统
          AutoZ --apply          查询 + 设置系统时区（优先免授权助手）
          AutoZ --set <zone>     直接设置指定 IANA 时区
          AutoZ --system         打印当前系统时区与自动时区开关
          AutoZ --format         打印继承到的时间格式与东八区渲染结果
          AutoZ --menu           打印菜单结构（数据驱动模型渲染成文本，便于审查）
          AutoZ --plan [zone]    打印三条通道将执行的命令（不执行，供审查）
          AutoZ --backend <b>    切换改时区通道：helper | native | appleScript
          AutoZ --notify-status  查看通知通道说明
          AutoZ --notify-test    测试通知横幅（自绘，需 GUI 在运行）
          AutoZ --login-status   查看开机自启状态
          AutoZ --login-enable   开启开机自启（App 需已在 /Applications）
          AutoZ --login-disable  关闭开机自启
          AutoZ --icon-preview <png> <size>  导出程序图标预览（调试外观用）

        免授权助手（装一次，以后改时区零弹窗）:
          AutoZ --helper-status     查看助手状态与 ping 结果
          AutoZ --helper-plan       打印安装/卸载将执行的特权命令（不执行）
          AutoZ --helper-install    安装（弹一次管理员授权）
          AutoZ --helper-uninstall  卸载（弹一次管理员授权）
          autoz-helper --selftest    助手自测（11 项协议与安全用例，全部 dry-run，无需 root）
        """)
        return 0
    }
}

// MARK: - 入口

// --show-* 是 GUI 自检开关，不能当成 CLI 参数（否则会被 CLI 分支吃掉直接退出）
let guiSwitches: Set<String> = ["--show-menu", "--show-console", "--show-toast", "--show-toast-offthread"]
let argv = Array(CommandLine.arguments.dropFirst()).filter { !guiSwitches.contains($0) }
if let first = argv.first, first.hasPrefix("-") {
    exit(runCLI(argv))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// MARK: - 高级配置窗口的动作实现
//
// 界面层（ui.swift）只负责转发，业务逻辑仍然全在 AppDelegate 里 —— 不为了好看把逻辑搬散。

extension AppDelegate: AutoZActions {

    func azToggleSync()      { toggleSync(NSMenuItem()) }
    func azCheckAndSync()    { store.lastAction = "立即检查并同步"; perform(apply: true) }
    func azCheckOnly()       { store.lastAction = "仅查询"; perform(apply: false) }
    func azRestore()         { restoreOriginal(NSMenuItem()) }

    func azSetShowSeconds(_ on: Bool) {
        guard store.showSeconds != on else { return }
        store.showSeconds = on
        lastTitle = ""
        refresh()
    }

    /// 开关开机自启。状态以系统登录项为准，不额外在 UserDefaults 存一份 ——
    /// 否则用户在「系统设置」里手动改掉之后就对不上了。
    func azSetLaunchAtLogin(_ on: Bool) {
        if let err = LoginItem.set(on) {
            log("开机自启\(on ? "开启" : "关闭")失败：\(err)")
            notify(title: "开机自启设置失败", message: err, sound: "Basso")
        } else {
            log("开机自启 → \(LoginItem.statusText)")
            notify(title: on ? "已开启开机自启" : "已关闭开机自启", message: LoginItem.statusText)
        }
        refresh()
    }

    func azInstallHelper()   { installHelper(NSMenuItem()) }
    func azUninstallHelper() { uninstallHelper(NSMenuItem()) }

    func azSetBackend(_ backend: PrivBackend) {
        store.privBackend = backend
        log("改时区通道 → \(backend.rawValue)")
        refresh()
    }

    func azOpenDateSettings() { _ = openDateAndTimeSettings() }
    func azCopyDiagnostics()  { copyDiagnostics(NSMenuItem()) }
    func azTestNotification() { testNotification(NSMenuItem()) }

    func azOpenLog() {
        let url = URL(fileURLWithPath: K.logPath)
        if FileManager.default.fileExists(atPath: K.logPath) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
