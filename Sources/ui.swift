// ui.swift — 程序自绘的界面层
//
//   1. AdvancedWindowController：高级配置窗口（关于 + 全部次级操作）。
//      版式**严格对齐 docs/ui-design.html** —— 那是和用户逐条敲定的设计稿，
//      改界面先改设计稿，再照抄到这儿，避免"一版一版试"。
//      三句话概括：左侧导航 + 右侧内容 + 滚动；头部只讲「这是什么」，
//      版本号与助手状态收在脚部；卡片靠 1px 描边界定边界。
//   2. ToastCenter / ToastPanel：程序内通知横幅（自绘，不用系统通知权限，也不用 osascript）。
//   3. 图标与矢量图形见 artwork.swift。

import Cocoa

// MARK: - 打开系统自带 App

/// 菜单与高级配置窗口共用；全程 NSWorkspace，不经过 shell
@discardableResult
func openDateAndTimeSettings() -> Bool {
    let urls = ["x-apple.systempreferences:com.apple.Date-Time-Settings.extension",
                "x-apple.systempreferences:com.apple.preference.datetime"]
    for u in urls {
        if let url = URL(string: u), NSWorkspace.shared.open(url) {
            log("已打开「日期与时间」设置：\(u)")
            return true
        }
    }
    if NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/DateAndTime.prefPane")) {
        return true
    }
    return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
}

/// 打开系统「日历」。先试固定路径，再退回 bundle id —— 只拼路径在换 macOS 版本时会失效。
@discardableResult
func openCalendarApp() -> Bool {
    let path = "/System/Applications/Calendar.app"
    if FileManager.default.fileExists(atPath: path),
       NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
        log("已打开系统日历：\(path)")
        return true
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            if let err { log("打开日历失败：\(err.localizedDescription)") }
        }
        log("已打开系统日历（按 bundle id）：com.apple.iCal")
        return true
    }
    log("没找到系统日历")
    return false
}

// MARK: - 高级配置窗口要执行的动作（由 AppDelegate 实现，避免界面层反向依赖业务）

protocol AutoZActions: AnyObject {
    func azToggleSync()
    func azCheckAndSync()
    func azCheckOnly()
    func azRestoreHome()
    func azSetHomeZone(_ id: String)
    func azSetAutoHome(_ on: Bool)
    func azSetShowSeconds(_ on: Bool)
    func azSetLaunchAtLogin(_ on: Bool)
    func azInstallHelper()
    func azUninstallHelper()
    func azSetBackend(_ backend: PrivBackend)
    func azOpenDateSettings()
    func azOpenCalendar()
    func azOpenLog()
    func azCopyDiagnostics()
    func azTestNotification()
}

// MARK: - 视觉基元（与 docs/ui-design.html 的 CSS 变量一一对应）

/// 动态色：浅色/深色各给一支。
///
/// 注意**不要**把这套颜色塞进 `layer.backgroundColor` —— CGColor 在赋值那一刻就解析死了，
/// 用户切浅/深色时画面不会跟着变。要么在 draw 里现取（下面这些视图都是这么做的），
/// 要么重写 viewDidChangeEffectiveAppearance。
enum Theme {

    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    /// 窗口 + 内容区底色（设计稿 --card）
    static let surface = dyn(.white, rgb(0x2c, 0x2c, 0x2e))
    /// 头部 / 导航 / 脚部底色（--sidebar）
    static let sidebar = dyn(rgb(0xf0, 0xf0, 0xf2), rgb(0x25, 0x25, 0x27))
    /// 卡片描边、表格线（--line）
    static let line = dyn(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.11))
    /// 徽章底色（--sel）
    static let chip = dyn(NSColor(white: 0, alpha: 0.055), NSColor(white: 1, alpha: 0.075))
    /// 强调色（橙）—— 与菜单栏标题同一个色号
    static let accent   = dyn(rgb(0xd9, 0x7a, 0x06), rgb(0xff, 0xa5, 0x3a))
    static let accentBG = dyn(rgb(0xd9, 0x7a, 0x06, 0.13), rgb(0xff, 0xa5, 0x3a, 0.16))
    /// 一致 / 无差别（绿）
    static let green    = dyn(rgb(0x1a, 0x8f, 0x3c), rgb(0x30, 0xd1, 0x58))
    static let greenBG  = dyn(rgb(0x1a, 0x8f, 0x3c, 0.12), rgb(0x30, 0xd1, 0x58, 0.16))

    static let mono11 = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let mono14 = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
}

/// 纯色面板（头部 / 导航 / 脚部）：在 draw 里现取动态色。
final class AZPane: NSView {
    var fill: NSColor = .clear
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { fill.setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// 1px 细线。视图本身就是那 1px（高度/宽度由调用方钉死）。
final class AZHairline: NSView {
    override func draw(_ dirtyRect: NSRect) { Theme.line.setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// 小徽章（设计稿 .pill）：圆角 6、11pt 文本、左右各 6 内边距。
final class AZPill: NSView {

    enum Kind { case plain, accent, ok }

    private let label = NSTextField(labelWithString: "")
    private let kind: Kind

    init(_ text: String, _ kind: Kind = .plain) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = text
        label.font = .systemFont(ofSize: 11)
        label.textColor = kind == .accent ? Theme.accent : (kind == .ok ? Theme.green : .secondaryLabelColor)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持归档") }

    override var intrinsicContentSize: NSSize {
        let s = label.intrinsicContentSize
        return NSSize(width: ceil(s.width) + 12, height: ceil(s.height) + 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg: NSColor
        switch kind {
        case .plain:  bg = Theme.chip
        case .accent: bg = Theme.accentBG
        case .ok:     bg = Theme.greenBG
        }
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    func setText(_ s: String) {
        guard label.stringValue != s else { return }
        label.stringValue = s
        invalidateIntrinsicContentSize()
    }
}

/// 绿底对勾（设计稿 .tick）：代表「无差别」。
final class AZTick: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
    override func draw(_ dirtyRect: NSRect) {
        Theme.greenBG.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 4.4, y: 8.3))
        p.line(to: NSPoint(x: 6.9, y: 5.7))
        p.line(to: NSPoint(x: 11.6, y: 10.7))
        Theme.green.setStroke()
        p.lineWidth = 1.9
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// 卡片：圆角 10 + 1px 描边。
///
/// 内容区底色与卡片同色，卡片的边界完全靠这圈线定义 —— 这是设计稿的画法。
/// 早先给卡片填了比背景更暗的灰（labelColor 叠加），浅色下看着是「凹」进去的，
/// 和右侧圆角卡片并排就是「一格方块一格圆角」，用户 2026-10-02 明确否掉。
final class AZCard: NSView {

    let stack = NSStackView()

    init(_ rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 13, left: 16, bottom: 15, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews(rows, in: .top)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持归档") }

    /// 让某个子行横向撑满卡片内容宽（表格、分隔线、按钮行需要）。
    /// 约束只涉及 stack 与其子视图 —— 都在同一棵子树里，可以安全地在 init 之后激活。
    @discardableResult
    func stretch(_ v: NSView) -> NSView {
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        return v
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        Theme.surface.setFill()
        p.fill()
        Theme.line.setStroke()
        p.lineWidth = 1
        p.stroke()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// 时间列：日期（12pt 灰）在上、时刻（14pt 等宽）在下，右对齐。
/// 两行都是**该时区的当地时间** —— 只写时区名，用户还得自己换算，等于没给参考。
final class AZTimeCell: NSView {

    private let dateField  = NSTextField(labelWithString: "")
    private let clockField = NSTextField(labelWithString: "")
    private let zone: TimeZone

    init(zone: TimeZone) {
        self.zone = zone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        dateField.font = .systemFont(ofSize: 12)
        dateField.textColor = .tertiaryLabelColor
        dateField.alignment = .right
        clockField.font = Theme.mono14
        clockField.textColor = .labelColor
        clockField.alignment = .right

        let s = NSStackView(views: [dateField, clockField])
        s.orientation = .vertical
        s.alignment = .trailing
        s.spacing = 2
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: topAnchor),
            s.leadingAnchor.constraint(equalTo: leadingAnchor),
            s.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 112),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("不支持归档") }

    /// 按秒调用：只改字符串，**不重建视图树**（否则滚动位置和开关状态会被重置）。
    func refresh() {
        let now = Date()
        let d = zonedDateText(zone, at: now)
        let c = zonedClockText(zone, at: now)
        if dateField.stringValue != d { dateField.stringValue = d }
        if clockField.stringValue != c { clockField.stringValue = c }
    }
}

/// 键值表（设计稿 table.kv）：三列「键 / 值 / 时间」，行间 1px 线，外圈圆角描边。
/// 值列内部通常再叠一行小字（IANA 名 / IP），降级成 11pt 等宽灰字。
final class AZKVTable: NSView {

    struct Row {
        let key: String
        let value: NSView
        let time: NSView?
        init(_ key: String, _ value: NSView, time: NSView? = nil) {
            self.key = key
            self.value = value
            self.time = time
        }
    }

    init(_ rows: [Row]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        var previousBottom = topAnchor
        for (i, r) in rows.enumerated() {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false

            let k = NSTextField(labelWithString: r.key)
            k.font = .systemFont(ofSize: 12)
            k.textColor = .tertiaryLabelColor
            k.translatesAutoresizingMaskIntoConstraints = false
            k.setContentHuggingPriority(.required, for: .horizontal)
            k.setContentCompressionResistancePriority(.required, for: .horizontal)

            r.value.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(k)
            row.addSubview(r.value)
            addSubview(row)

            var cs: [NSLayoutConstraint] = [
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: previousBottom),

                k.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                k.widthAnchor.constraint(equalToConstant: 86),
                k.centerYAnchor.constraint(equalTo: row.centerYAnchor),

                r.value.leadingAnchor.constraint(equalTo: k.trailingAnchor, constant: 11),
                r.value.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
                r.value.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            ]
            if let t = r.time {
                t.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(t)
                cs += [
                    t.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                    t.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    r.value.trailingAnchor.constraint(lessThanOrEqualTo: t.leadingAnchor, constant: -10),
                ]
            } else {
                cs.append(r.value.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -12))
            }
            NSLayoutConstraint.activate(cs)

            if i < rows.count - 1 {
                let sep = AZHairline()
                sep.translatesAutoresizingMaskIntoConstraints = false
                addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: leadingAnchor),
                    sep.trailingAnchor.constraint(equalTo: trailingAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 1),
                    sep.topAnchor.constraint(equalTo: row.bottomAnchor),
                ])
                previousBottom = sep.bottomAnchor
            } else {
                previousBottom = row.bottomAnchor
            }
        }
        previousBottom.constraint(equalTo: bottomAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("不支持归档") }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        Theme.line.setStroke()
        p.lineWidth = 1
        p.stroke()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// 导航行：选中态是**圆角白片 + 一圈细描边**（设计稿 sourceList 的观感）。
/// AppKit 默认把整行铺成强调色通栏（蓝底白字），跟右侧圆角卡片放一起就是
/// 「一格方块一格圆角」的冲突感 —— 用户 2026-10-02 明确否掉。
///
/// 白片做成 cell 的**背景子视图**、文字是它上面的兄弟视图：绘制顺序天然是
/// 「先白片、后文字」。**不要**改回在 NSTableRowView.drawSelection 里画 ——
/// AppKit 是在子视图之后才调它的，文字会被白片整片盖掉（2026-10-02 实测：
/// 首行只剩一块空白白片，找了一阵才反应过来）。
final class AZNavCell: NSTableCellView {

    private let pill = AZNavPillBg()
    private let title = NSTextField(labelWithString: "")

    var rowSelected = false {
        didSet {
            pill.isHidden = !rowSelected
            title.font = .systemFont(ofSize: 13, weight: rowSelected ? .medium : .regular)
            title.textColor = rowSelected ? .labelColor : .secondaryLabelColor
        }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.isHidden = true
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        addSubview(pill)
        addSubview(title)
        textField = title
        NSLayoutConstraint.activate([
            // 白片：左右各留 8pt、上下各留 2pt（设计稿 .nav 的 padding + 选中片外边距）
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pill.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            // 文字缩进 17 = 导航区 8pt 内边距 + 白片 9pt 内边距
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持归档") }

    func setTitle(_ s: String) { title.stringValue = s }
}

/// 导航选中片：圆角白片 + 1px 描边（纯背景，文字由 AZNavCell 叠在上面）
private final class AZNavPillBg: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        Theme.surface.setFill()
        p.fill()
        Theme.line.setStroke()
        p.lineWidth = 1
        p.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

// MARK: - 高级配置窗口

final class AdvancedWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    static let shared = AdvancedWindowController()
    weak var actions: AutoZActions?

    /// 左侧导航的分区。设置类界面一律「左导航 + 右内容 + 滚动」——
    /// 把所有卡片堆成一根长滚动条，屏幕一矮就有内容被推出可视区，
    /// 而且视觉上分不清主次（2026-10-02 用户明确要求，全局约定）。
    private static let sections = ["时区同步", "菜单栏", "启动", "改时区方式", "维护", "关于"]

    private let headerBar   = AZPane()
    private let headerIcon  = NSImageView()
    private let headerTitle = NSTextField(labelWithString: appDisplayName)
    private let headerSub   = NSTextField(labelWithString: "")
    private let navPane     = AZPane()
    private let navScroll   = NSScrollView()
    private let navTable    = NSTableView()
    private let content     = NSStackView()
    private let scroll      = NSScrollView()
    private let footDot     = NSView()
    private let footText    = NSTextField(labelWithString: "")

    /// 卡片宽度约束（跟随内容区）。**必须等卡片进了视图层级才能激活** ——
    /// 在 card 构造里直接引用 content 会因为两者还没有共同祖先而抛异常崩溃
    /// （2026-10-02 实测：SIGABRT / -[NSLayoutConstraint setActive:]）。
    private var cardWidthConstraints: [NSLayoutConstraint] = []
    /// 按秒刷新的回调（只改字符串）。切分区时整批换掉。
    private var statusRefreshers: [() -> Void] = []
    private var statusTicker: Timer?
    private var currentSection = 0
    /// 程序自己改导航选中态时置位，避免被 selectionDidChange 当成「用户切页」
    private var isProgrammaticSelection = false
    /// 助手状态缓存：refresh() 时算一次，切分区重建内容时复用，不必每次重算
    private var lastHelperOK = false
    private var lastHelperInstalled = false

    private init() {
        // 固定尺寸：分区后每页内容都不高，不需要再按内容伸缩（那套在矮屏上本来也不可靠）
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = appDisplayName
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        // 实底：不透明窗口背景，浅/深色各自解析，保证对比度
        w.isOpaque = true
        w.backgroundColor = Theme.surface
        // 宽度锁死：内容一长，Auto Layout 会推着窗口一起变宽（实测 880 被撑成 917，
        // 而且随文案长短变化）。两端都钉住，内容超出就走滚动 —— 窗口尺寸不该由内容决定。
        w.contentMinSize = NSSize(width: 880, height: 560)
        w.contentMaxSize = NSSize(width: 880, height: 900)
        super.init(window: w)
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(b)?.isHidden = true
        }
        buildShell()
    }

    required init?(coder: NSCoder) { fatalError("不支持归档") }

    // MARK: 外壳（一次建好：头部 / 导航 / 内容 / 脚部）

    private func buildShell() {
        guard let w = window, let root = w.contentView else { return }

        // ── 头部：图标 + 应用名 + 一句话定位。只回答「这是什么」——
        //    版本号与助手状态统一收到脚部，头脚不重样（2026-10-02 用户要求）。
        headerBar.fill = Theme.sidebar
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerBar)

        headerIcon.image = Artwork.iconImage(size: 128)
        headerIcon.imageScaling = .scaleProportionallyUpOrDown
        headerIcon.translatesAutoresizingMaskIntoConstraints = false

        headerTitle.font = .systemFont(ofSize: 19, weight: .semibold)
        headerTitle.textColor = .labelColor
        headerTitle.translatesAutoresizingMaskIntoConstraints = false

        headerSub.font = .systemFont(ofSize: 12)
        headerSub.textColor = .secondaryLabelColor
        headerSub.translatesAutoresizingMaskIntoConstraints = false

        headerBar.addSubview(headerIcon)
        headerBar.addSubview(headerTitle)
        headerBar.addSubview(headerSub)

        let headRule = AZHairline()
        headRule.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headRule)

        // ── 左侧导航。分区之后每页只放自己那几项，再也不用把 6 张卡片叠成一根长条。
        navPane.fill = Theme.sidebar
        navPane.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(navPane)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("nav"))
        col.width = 175
        col.resizingMask = .autoresizingMask
        navTable.addTableColumn(col)
        navTable.headerView = nil
        navTable.rowHeight = 32
        navTable.style = .plain
        // 选中态全部交给 AZNavCell 自绘（圆角白片）。这里必须 .none ——
        // .sourceList / .regular 都会让 AppKit 先铺一层强调色，与自绘的白片打架。
        navTable.selectionHighlightStyle = .none
        navTable.backgroundColor = .clear
        navTable.allowsEmptySelection = false
        navTable.focusRingType = .none
        navTable.intercellSpacing = NSSize(width: 0, height: 0)
        navTable.dataSource = self
        navTable.delegate = self
        navTable.target = self
        navTable.action = #selector(navClicked(_:))

        navScroll.drawsBackground = false
        navScroll.borderType = .noBorder
        navScroll.hasVerticalScroller = true
        navScroll.autohidesScrollers = true
        navScroll.documentView = navTable
        navScroll.translatesAutoresizingMaskIntoConstraints = false
        navPane.addSubview(navScroll)

        let navRule = AZHairline()
        navRule.translatesAutoresizingMaskIntoConstraints = false
        navPane.addSubview(navRule)

        // ── 右侧内容区
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        // 兜底滚动：内容真放不下时滚动条得**看得见**（overlay + autohide 是默认值，
        // 滚动条平时不画，用户既看不到下半部分也不知道还能滚）。别改回 autohide。
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        root.addSubview(scroll)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 24, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        let clip = NSClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        clip.addSubview(content)

        // ── 脚部 = 常驻状态条：左「助手状态」，右「关闭」
        let footer = AZPane()
        footer.fill = Theme.sidebar
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)

        footDot.wantsLayer = true
        footDot.layer?.cornerRadius = 4
        footDot.translatesAutoresizingMaskIntoConstraints = false

        footText.font = .systemFont(ofSize: 11)
        footText.textColor = .secondaryLabelColor
        footText.lineBreakMode = .byTruncatingTail
        footText.translatesAutoresizingMaskIntoConstraints = false

        footer.addSubview(footDot)
        footer.addSubview(footText)

        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(closeConsole(_:)))
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\r"
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(closeBtn)

        let footRule = AZHairline()
        footRule.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footRule)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: root.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 104),

            headerIcon.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 22),
            headerIcon.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            headerIcon.widthAnchor.constraint(equalToConstant: 60),
            headerIcon.heightAnchor.constraint(equalToConstant: 60),

            headerTitle.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 15),
            headerTitle.topAnchor.constraint(equalTo: headerIcon.topAnchor, constant: 8),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: headerBar.trailingAnchor, constant: -22),

            headerSub.leadingAnchor.constraint(equalTo: headerTitle.leadingAnchor),
            headerSub.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 5),
            headerSub.trailingAnchor.constraint(lessThanOrEqualTo: headerBar.trailingAnchor, constant: -22),

            headRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headRule.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            headRule.heightAnchor.constraint(equalToConstant: 1),

            navPane.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            navPane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navPane.bottomAnchor.constraint(equalTo: footer.topAnchor),
            navPane.widthAnchor.constraint(equalToConstant: 176),

            navScroll.topAnchor.constraint(equalTo: navPane.topAnchor, constant: 9),
            navScroll.leadingAnchor.constraint(equalTo: navPane.leadingAnchor),
            navScroll.trailingAnchor.constraint(equalTo: navPane.trailingAnchor, constant: -1),
            navScroll.bottomAnchor.constraint(equalTo: navPane.bottomAnchor, constant: -9),

            navRule.trailingAnchor.constraint(equalTo: navPane.trailingAnchor),
            navRule.topAnchor.constraint(equalTo: navPane.topAnchor),
            navRule.bottomAnchor.constraint(equalTo: navPane.bottomAnchor),
            navRule.widthAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: navPane.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footRule.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footRule.heightAnchor.constraint(equalToConstant: 1),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 54),

            footDot.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 22),
            footDot.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footDot.widthAnchor.constraint(equalToConstant: 8),
            footDot.heightAnchor.constraint(equalToConstant: 8),

            footText.leadingAnchor.constraint(equalTo: footDot.trailingAnchor, constant: 7),
            footText.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footText.trailingAnchor.constraint(lessThanOrEqualTo: closeBtn.leadingAnchor, constant: -12),

            closeBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -22),
            closeBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
    }

    // MARK: 展示与刷新

    func show() {
        // 先把导航选中态对齐当前分区，再刷内容 —— 顺序反了会先渲染一遍错的页。
        // 期间屏蔽 selectionDidChange：程序自己改选中不该被当成「用户切页」。
        if navTable.selectedRow != currentSection {
            isProgrammaticSelection = true
            navTable.selectRowIndexes(IndexSet(integer: currentSection), byExtendingSelection: false)
            isProgrammaticSelection = false
        }
        refresh()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        startStatusTicker()
        NSApp.activate(ignoringOtherApps: true)
        // 显式钉住尺寸：内容需求一旦超过它，AppKit 会悄悄把窗口撑宽，
        // 界面就会「自己长大」（2026-10-02 踩过：一行三个按钮把 880 撑成 917）
        window?.setContentSize(NSSize(width: 880, height: 620))
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        if let w = window {
            log("高级配置窗口已显示：frame=\(NSStringFromRect(w.frame)) 最小=\(NSStringFromSize(w.contentMinSize)) "
                + "内容需求=\(NSStringFromSize(content.fittingSize))")
        }
    }

    /// 自检用：切到指定分区。走的是和点导航**同一条路**（选中态 + 重建内容），
    /// 配合 `--snapshot-all` 可以把六个分区一次性截图核对，不必手动一个个点。
    func selectSectionForProbe(_ index: Int) {
        guard index >= 0, index < Self.sections.count else { return }
        currentSection = index
        isProgrammaticSelection = true
        navTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        isProgrammaticSelection = false
        syncNavRows()
        rebuildContent(scrollToTop: true)
    }

    /// 重建右侧内容区：只装当前分区的那几项。
    private func rebuildContent(scrollToTop: Bool = false) {
        statusRefreshers = []          // 表格会被重建，旧的按秒回调立刻失效
        NSLayoutConstraint.deactivate(cardWidthConstraints)
        cardWidthConstraints = []
        let views = sectionViews(currentSection)
        content.setViews(views, in: .top)
        // 卡片宽度跟随内容区（**入树之后**才激活，见 cardWidthConstraints 的说明）。
        // 早先写死 724：内容区只有 ~668，卡片被挤到贴边（右边距 7px），
        // 而且 AppKit 会顺手把窗口顶宽 —— 实测 880 → 917（2026-10-02）。
        for v in views where v is AZCard {
            let c = v.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40)
            c.isActive = true
            cardWidthConstraints.append(c)
        }
        if scrollToTop {
            // 切分区时把滚动位置回零，免得停在上一页的位置上
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func refresh() {
        headerSub.stringValue = appTagline

        // 用文件判断代替 ping：刷新可能发生在主线程上，不能因为助手卡住就把界面顶住
        let helperOK = HelperChannel.socketExists && HelperChannel.binaryInstalled && HelperChannel.plistInstalled
        let helperInstalled = HelperChannel.plistInstalled
        let (dot, text): (NSColor, String) = helperOK
            ? (.systemGreen, "免授权模式已启用 · 改时区零弹窗")
            : (helperInstalled ? .systemOrange : .systemGray,
               helperInstalled ? "助手已就位但没响应 · 可在「改时区方式」里重装" : "免授权模式未安装 · 每次改时区会弹授权框")
        footDot.layer?.backgroundColor = dot.cgColor
        footText.stringValue = text

        lastHelperOK = helperOK
        lastHelperInstalled = helperInstalled
        rebuildContent()
        log("高级配置已刷新（助手就绪=\(helperOK)，分区=\(Self.sections[currentSection])）")
    }

    /// 时间停在打开那一刻会误导（这窗口本来就有人拿来看时间），所以让它按秒跟着走。
    /// 只改各时间列的字符串，**不重建卡片/表格** —— 否则会重置滚动位置和用户刚勾的开关。
    private func startStatusTicker() {
        statusTicker?.invalidate()
        statusTicker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true, !self.statusRefreshers.isEmpty else { return }
            for r in self.statusRefreshers { r() }
        }
    }

    // MARK: 时区同步的状态表

    /// 状态表四行，口径与菜单顶部状态区**共用同一批纯函数**（zoneCNName / zoneChipText /
    /// zonedDateText / zonedClockText / beijingDeltaShort），免得两处各写一份而漂移。
    private func makeStatusTable() -> AZKVTable {
        let store = Store.shared
        let now = Date()
        let bj = beijingZone()
        let sys = systemTimeZone()
        let differs = sys.secondsFromGMT(for: now) != bj.secondsFromGMT(for: now)

        // 1. 期望时区：菜单栏上常显的东八区
        let t1 = AZTimeCell(zone: bj)
        let r1 = AZKVTable.Row("期望时区",
                               zoneCell(name: zoneCNName(bj), chip: zoneChipText(bj, at: now),
                                        kind: .accent, sub: K.beijingID),
                               time: t1)

        // 2. 实际时区：系统当前时区
        let t2 = AZTimeCell(zone: sys)
        let r2 = AZKVTable.Row("实际时区",
                               zoneCell(name: zoneCNName(sys), chip: zoneChipText(sys, at: now),
                                        kind: .plain, sub: systemZoneID()),
                               time: t2)

        // 3. 出口时区：最近一次检测的结果（与系统时区一致时标绿）
        var t3: AZTimeCell?
        let r3: AZKVTable.Row
        if let det = store.lastDetection {
            let exit = TimeZone(identifier: det.zoneID)
            let cell = AZTimeCell(zone: exit ?? sys)
            t3 = cell
            let same = (exit?.secondsFromGMT(for: now) ?? Int.min) == sys.secondsFromGMT(for: now)
            r3 = AZKVTable.Row("出口时区",
                               zoneCell(name: exit.map { zoneCNName($0) } ?? det.zoneID,
                                        chip: same ? "与系统一致" : "与系统不同",
                                        kind: same ? .ok : .plain,
                                        sub: "\(det.ip) · \(det.zoneID)"),
                               time: cell)
        } else {
            r3 = AZKVTable.Row("出口时区",
                               zoneCell(name: "尚未检测", chip: "—", kind: .plain, sub: "点下面的按钮查一次"),
                               time: nil)
        }

        // 4. 是否有差别：有 → 橙徽章 + 紧凑时差 + 恢复按钮；无 → 绿勾 + 一句话
        let r4 = AZKVTable.Row("是否有差别", diffCell(differs: differs, system: sys, at: now), time: nil)

        let table = AZKVTable([r1, r2, r3, r4])
        statusRefreshers = [t1.refresh, t2.refresh]
        if let t3 { statusRefreshers.append(t3.refresh) }
        return table
    }

    /// 时区单元格：主名 + 徽章（一行），下面一行 11pt 等宽小字（IANA 名 / IP）
    private func zoneCell(name: String, chip: String, kind: AZPill.Kind, sub: String) -> NSView {
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail

        let top = NSStackView(views: [title, AZPill(chip, kind)])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false

        let subLabel = NSTextField(labelWithString: sub)
        subLabel.font = Theme.mono11
        subLabel.textColor = .tertiaryLabelColor
        subLabel.lineBreakMode = .byTruncatingMiddle

        let s = NSStackView(views: [top, subLabel])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 3
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    /// 「是否有差别」这一格。
    /// 只留**一个**动作按钮：哪一行看出差别，按钮就在哪一行（早先三个按钮挤一行，把窗口撑宽了）。
    private func diffCell(differs: Bool, system: TimeZone, at now: Date) -> NSView {
        let s = NSStackView()
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 9
        s.translatesAutoresizingMaskIntoConstraints = false
        if differs {
            let delta = NSTextField(labelWithString: beijingDeltaShort(system, at: now))
            delta.font = Theme.mono11
            delta.textColor = .secondaryLabelColor
            var views: [NSView] = [AZPill("有", .accent), delta]
            // 归位目标固定取「归位时区」，不再取决于有没有快照记录 ——
            // 快照可能被跟随功能自己写脏，拿它当恢复目标会把人送回代理时区。
            let home = Store.shared.homeZone
            let b = button("回到归位时区", #selector(restore(_:)))
            b.toolTip = "把系统时区写回归位时区 \(home)，并关闭同步"
            views.append(b)
            s.setViews(views, in: .leading)
        } else {
            s.setViews([AZTick(), AZPill("无", .ok),
                        caption("已与系统时区一致，无需处理", maxWidth: 320)], in: .leading)
        }
        return s
    }

    // MARK: 左侧导航

    func numberOfRows(in tableView: NSTableView) -> Int { Self.sections.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("navCell")
        let cell: AZNavCell
        if let reused = tv.makeView(withIdentifier: id, owner: self) as? AZNavCell {
            cell = reused
        } else {
            cell = AZNavCell(identifier: id)
        }
        cell.setTitle(Self.sections[row])
        cell.rowSelected = (tv.selectedRow == row)
        return cell
    }

    /// 选中态一变，把**已可见**的行重新上色（不可见的行下次 viewFor 时会自己对齐）。
    private func syncNavRows() {
        for r in 0..<navTable.numberOfRows {
            guard let cell = navTable.view(atColumn: 0, row: r, makeIfNecessary: false) as? AZNavCell
            else { continue }
            cell.rowSelected = (r == navTable.selectedRow)
        }
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        syncNavRows()
        guard !isProgrammaticSelection else { return }
        let row = navTable.selectedRow
        guard row >= 0, row != currentSection else { return }
        currentSection = row
        rebuildContent(scrollToTop: true)
        log("高级配置切到分区：\(Self.sections[row])")
    }

    @objc private func navClicked(_ sender: Any) {
        // 单击已选中的行也要有反馈（选中态没变时 tableViewSelectionDidChange 不触发）
        let row = navTable.clickedRow
        guard row >= 0, row == currentSection else { return }
        rebuildContent(scrollToTop: true)
    }

    // MARK: 各分区内容（一页一张卡片，互不打扰）

    private func sectionViews(_ index: Int) -> [NSView] {
        switch index {
        case 0:  return page("时区同步", "程序把系统时区切到出口 IP 对应的时区，这里显示当前是否已经一致。",
                             [sectionSyncCard()])
        case 1:  return page("菜单栏", "菜单栏标题的显示方式。", [sectionMenuBarCard()])
        case 2:  return page("启动", "登录后是否自动运行。", [sectionLoginCard()])
        case 3:  return page("改时区方式", "改系统时区要提权，这里选走哪条通道。", [sectionBackendCard()])
        case 4:  return page("维护", "诊断入口与本地文件位置。", [sectionMaintenanceCard()])
        default: return page("关于", nil, [sectionAboutCard()])
        }
    }

    /// 页面 = 标题 + 一句说明 + 卡片
    private func page(_ title: String, _ desc: String?, _ cards: [NSView]) -> [NSView] {
        let h = NSTextField(labelWithString: title)
        h.font = .systemFont(ofSize: 14, weight: .semibold)
        h.textColor = .labelColor
        var head: [NSView] = [h]
        if let d = desc { head.append(caption(d)) }
        let box = NSStackView(views: head)
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 5
        box.translatesAutoresizingMaskIntoConstraints = false
        return [box] + cards
    }

    private func sectionSyncCard() -> AZCard {
        let store = Store.shared
        let syncSwitch = NSButton(checkboxWithTitle: "跟随出口 IP 自动同步系统时区",
                                  target: self, action: #selector(toggleSync(_:)))
        syncSwitch.state = store.syncEnabled ? .on : .off

        let table = makeStatusTable()
        let sep = hrule()

        // 归位时区：关掉跟随 / 退出程序时系统时区写回哪里。
        // 早先按「开启同步那一刻的快照」恢复，而快照会被跟随功能自己写脏
        // （实测被写成 America/Los_Angeles，用户点恢复反而回到代理时区），
        // 所以改成显式配置，默认东八区。
        let homeTZ = TimeZone(identifier: store.homeZone)
        let homeValue = NSTextField(labelWithString: homeTZ.map { zoneLineText($0) } ?? store.homeZone)
        homeValue.font = .systemFont(ofSize: 13)
        homeValue.textColor = .labelColor
        homeValue.lineBreakMode = .byTruncatingTail
        homeValue.toolTip = store.homeZone
        let homeRow = vrow("归位时区", hstack([homeValue, button("更改…", #selector(pickHomeZone(_:)))]))

        let autoHome = NSButton(checkboxWithTitle: "关闭跟随或退出程序时自动归位到该时区",
                                target: self, action: #selector(toggleAutoHome(_:)))
        autoHome.state = store.autoHome ? .on : .off

        let btns = row(button("立即检查并同步", #selector(checkAndSync(_:))),
                       button("仅查询（不改系统）", #selector(checkOnly(_:))))

        let card = AZCard([syncSwitch, table, sep, homeRow, autoHome, btns])
        card.stretch(table)
        card.stretch(sep)
        card.stretch(homeRow)
        return card
    }

    private func sectionMenuBarCard() -> AZCard {
        let secSwitch = NSButton(checkboxWithTitle: "在菜单栏标题里显示秒",
                                 target: self, action: #selector(toggleSeconds(_:)))
        secSwitch.state = Store.shared.showSeconds ? .on : .off
        return AZCard([secSwitch,
                       caption("标题格式跟随系统自带时钟（中文下即「10月3日 周六 08:18」）；"
                               + "与系统时区不一致时变橙。")])
    }

    private func sectionLoginCard() -> AZCard {
        let loginSwitch = NSButton(checkboxWithTitle: "登录时自动启动",
                                   target: self, action: #selector(toggleLaunchAtLogin(_:)))
        loginSwitch.state = LoginItem.isEnabled ? .on : .off
        let path = NSTextField(labelWithString: tilde(LoginItem.plistURL.path))
        path.font = Theme.mono11
        path.textColor = .tertiaryLabelColor
        return AZCard([loginSwitch,
                       caption("\(LoginItem.statusText)。可在「系统设置 → 通用 → 登录项」里撤销。"),
                       path])
    }

    private func sectionBackendCard() -> AZCard {
        let store = Store.shared
        let backendName: String
        switch store.privBackend {
        case .helper:      backendName = "免授权助手（推荐）"
        case .native:      backendName = "一次性授权 · 原生 Security.framework"
        case .appleScript: backendName = "一次性授权 · AppleScript（回退）"
        }
        let chip: (AZPill.Kind, String) = store.privBackend == .helper
            ? (lastHelperOK ? .ok : .plain, lastHelperOK ? "已启用" : "未安装")
            : (.plain, "已选中")

        let btnInstall   = button(lastHelperOK ? "重新安装助手" : "安装免授权助手（推荐）",
                                  #selector(installHelper(_:)))
        let btnUninstall = button("卸载助手", #selector(uninstallHelper(_:)))
        btnUninstall.isEnabled = lastHelperInstalled

        let r1 = NSButton(radioButtonWithTitle: "免授权助手（推荐）",
                          target: self, action: #selector(useHelper(_:)))
        let r2 = NSButton(radioButtonWithTitle: "一次性授权 · 原生 Security.framework",
                          target: self, action: #selector(useNative(_:)))
        let r3 = NSButton(radioButtonWithTitle: "一次性授权 · AppleScript（回退）",
                          target: self, action: #selector(useAppleScript(_:)))
        r1.state = store.privBackend == .helper ? .on : .off
        r2.state = store.privBackend == .native ? .on : .off
        r3.state = store.privBackend == .appleScript ? .on : .off

        let card = AZCard([
            vrow("当前通道", hstack([NSTextField(labelWithString: backendName), AZPill(chip.1, chip.0)])),
            vrow("运行方式", secondary("launchd 按需拉起，不常驻")),
            hrule(),
            row(btnInstall, btnUninstall),
            caption("可选通道（改完立即生效）"),
            r1, r2, r3,
        ])
        return card
    }

    private func sectionMaintenanceCard() -> AZCard {
        let store = Store.shared
        let rows: [(String, NSView)] = [
            ("日志", mono(tilde(K.logPath))),
            ("偏好", mono("~/Library/Preferences/\(bundleID).plist")),
            ("上次动作", mono(store.lastAction)),
        ]
        var content: [NSView] = [
            row(button("打开「日期与时间」设置", #selector(openDateSettings(_:))),
                button("打开系统日历", #selector(openCalendar(_:)))),
            row(button("打开运行日志", #selector(openLog(_:))),
                button("复制诊断信息", #selector(copyDiagnostics(_:)))),
            row(button("测试通知", #selector(testNotification(_:)))),
            hrule(),
        ]
        let kv = rows.map { vrow($0.0, $0.1) }
        content.append(contentsOf: kv)

        let card = AZCard(content)
        kv.forEach { card.stretch($0) }
        return card
    }

    private func sectionAboutCard() -> AZCard {
        let rows: [(String, NSView)] = [
            ("版本", mono("\(K.version) · \(bundleID)")),
            ("开源仓库", mono("github.com/etng/autoz")),
            ("许可证", mono("MIT License")),
            ("文档", mono("docs/how-it-works.md · docs/troubleshooting.md")),
        ]
        var content: [NSView] = [
            caption("菜单栏常显东八区（UTC+8）时间；开启同步后按出口 IP 写入系统时区，"
                    + "并关掉「自动设置时区」，随时可一键还原。出口 IP 走代理或 VPN 时，"
                    + "解析出的是代理所在地。"),
            hrule(),
        ]
        let kv = rows.map { vrow($0.0, $0.1) }
        content.append(contentsOf: kv)

        let card = AZCard(content)
        kv.forEach { card.stretch($0) }
        return card
    }

    // MARK: 小组件

    private func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        return b
    }

    private func hrule() -> AZHairline {
        let r = AZHairline()
        r.translatesAutoresizingMaskIntoConstraints = false
        r.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return r
    }

    private func row(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    /// 键值行：键列定宽 86，保证各行的值列左边缘对齐。
    /// 用 .centerY 而不是 .firstBaseline —— 值可能是嵌套的 stack，拿不到可靠基线。
    private func vrow(_ key: String, _ value: NSView) -> NSStackView {
        let k = NSTextField(labelWithString: key)
        k.font = .systemFont(ofSize: 12)
        k.textColor = .tertiaryLabelColor
        k.translatesAutoresizingMaskIntoConstraints = false
        k.setContentHuggingPriority(.required, for: .horizontal)
        k.setContentCompressionResistancePriority(.required, for: .horizontal)
        k.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let s = NSStackView(views: [k, value])
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 11
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func mono(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = Theme.mono11
        t.textColor = .secondaryLabelColor
        t.lineBreakMode = .byTruncatingMiddle
        return t
    }

    private func secondary(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 13)
        t.textColor = .secondaryLabelColor
        return t
    }

    private func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func caption(_ text: String, maxWidth: CGFloat = 616) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 12)
        t.textColor = .secondaryLabelColor
        t.maximumNumberOfLines = 9
        // 内容区宽 = 880(窗口) - 176(导航) - 1(分隔线) - ~15(滚动条) - 20/20(内边距) - 32(卡片内边距)
        t.preferredMaxLayoutWidth = maxWidth
        // 光设 preferredMaxLayoutWidth 只影响换行，**不钳制 intrinsicContentSize** ——
        // 文案一长窗口照样被撑开（实测 880 被撑成 917）。所以要一条硬约束。
        t.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        return t
    }

    // MARK: 归位时区

    /// 选归位时区：可输入筛选的 IANA 标识列表（全量 400+，靠输入缩小范围，不用笨重下拉）。
    /// 条目文本与解析分别用 `homeZonePickerItem` / `zoneIDFromPickerInput`（纯函数，可自测）。
    private func chooseHomeZone() {
        let current = Store.shared.homeZone
        let items = TimeZone.knownTimeZoneIdentifiers.sorted().map { homeZonePickerItem($0) }

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 78))
        let hint = NSTextField(labelWithString: "输入片段筛选（shanghai / tokyo / los），或从列表里挑：")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 58, width: 400, height: 16)

        let combo = NSComboBox()
        combo.usesDataSource = false
        combo.completes = true
        combo.numberOfVisibleItems = 12
        combo.addItems(withObjectValues: items)
        combo.stringValue = homeZonePickerItem(current)
        combo.frame = NSRect(x: 0, y: 26, width: 400, height: 26)

        let note = NSTextField(labelWithString: "关闭「跟随出口 IP」和退出 AutoZ 时，系统时区会写回这里。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 0, y: 2, width: 400, height: 16)

        host.addSubview(hint)
        host.addSubview(combo)
        host.addSubview(note)

        let a = NSAlert()
        a.messageText = "归位时区"
        a.informativeText = "当前：\(homeZonePickerItem(current))"
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消")
        a.accessoryView = host
        a.window.initialFirstResponder = combo

        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let id = zoneIDFromPickerInput(combo.stringValue) else {
            let bad = NSAlert()
            bad.messageText = "认不出这个时区"
            bad.informativeText = "「\(combo.stringValue)」无法匹配到唯一的时区标识，"
                + "请用 IANA 名（例如 Asia/Shanghai）或更具体的片段。"
            bad.addButton(withTitle: "知道了")
            bad.runModal()
            return
        }
        actions?.azSetHomeZone(id)
    }

    // MARK: 动作转发（界面层不碰业务，全部交回 AppDelegate）

    @objc private func closeConsole(_ sender: Any) { window?.orderOut(nil) }
    @objc private func toggleSync(_ sender: Any)   { actions?.azToggleSync() }
    @objc private func checkAndSync(_ sender: Any) { actions?.azCheckAndSync() }
    @objc private func checkOnly(_ sender: Any)    { actions?.azCheckOnly() }
    @objc private func restore(_ sender: Any)      { actions?.azRestoreHome() }
    @objc private func pickHomeZone(_ sender: Any) { chooseHomeZone() }
    @objc private func toggleAutoHome(_ sender: Any) {
        actions?.azSetAutoHome((sender as? NSButton)?.state == .on)
    }
    @objc private func toggleSeconds(_ sender: Any) { actions?.azSetShowSeconds((sender as? NSButton)?.state == .on) }
    @objc private func toggleLaunchAtLogin(_ sender: Any) { actions?.azSetLaunchAtLogin((sender as? NSButton)?.state == .on) }
    @objc private func installHelper(_ sender: Any) { actions?.azInstallHelper() }
    @objc private func uninstallHelper(_ sender: Any) { actions?.azUninstallHelper() }
    @objc private func useHelper(_ sender: Any)      { actions?.azSetBackend(.helper) }
    @objc private func useNative(_ sender: Any)      { actions?.azSetBackend(.native) }
    @objc private func useAppleScript(_ sender: Any) { actions?.azSetBackend(.appleScript) }
    @objc private func openDateSettings(_ sender: Any) { actions?.azOpenDateSettings() }
    @objc private func openCalendar(_ sender: Any) { actions?.azOpenCalendar() }
    @objc private func openLog(_ sender: Any)      { actions?.azOpenLog() }
    @objc private func copyDiagnostics(_ sender: Any) { actions?.azCopyDiagnostics() }
    @objc private func testNotification(_ sender: Any) { actions?.azTestNotification() }
}

// MARK: - 通知横幅（自绘，不使用系统通知、也不用 osascript）

final class ToastCenter {

    static let shared = ToastCenter()
    private struct Item { let title: String; let message: String }
    private var queue: [Item] = []
    private var current: ToastPanel?

    /// GUI 模式：右上角横幅；CLI 模式（没有 NSApplication）：只写日志并打印
    /// 注意：调用方可能在工作队列上（例如时区应用完成后），而创建 NSPanel 必须在主线程，
    /// 所以这里统一做一次主线程派发 —— 否则会以 NSException 崩掉。
    func post(title: String, message: String, sound: String? = "Glass") {
        log("通知: \(title) — \(message)")
        guard NSApp != nil else {
            print("[通知] \(title) — \(message)")
            return
        }
        if Thread.isMainThread {
            present(title: title, message: message, sound: sound)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.present(title: title, message: message, sound: sound)
            }
        }
    }

    private func present(title: String, message: String, sound: String?) {
        if let s = sound { NSSound(named: NSSound.Name(s))?.play() }
        queue.append(Item(title: title, message: message))
        if queue.count > 4 { queue.removeFirst(queue.count - 4) }
        pump()
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        let panel = ToastPanel(title: item.title, message: item.message)
        current = panel
        panel.present { [weak self] in
            self?.current = nil
            self?.pump()
        }
    }
}

/// 横幅卡片：实底绘制（不采样背后窗口），深浅色都能读清
final class ToastBackground: NSView {

    weak var panel: ToastPanel?

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 15, yRadius: 15)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { panel?.pointerInside(true) }
    override func mouseExited(with event: NSEvent)  { panel?.pointerInside(false) }
    override func mouseDown(with event: NSEvent)    { panel?.dismissNow() }
}

final class ToastPanel: NSPanel {

    private var onDone: (() -> Void)?
    private var ticker: Timer?
    private var deadline: Date?
    private var hovering = false
    private var hiding = false

    private static let width: CGFloat = 360

    init(title: String, message: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: ToastPanel.width, height: 80),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = ToastBackground()
        bg.panel = self

        let icon = NSImageView()
        icon.image = Artwork.iconImage(size: 72)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 38).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 38).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let bodyLabel = NSTextField(wrappingLabelWithString: message)
        bodyLabel.font = .systemFont(ofSize: 12.5)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 3
        bodyLabel.preferredMaxLayoutWidth = ToastPanel.width - 38 - 15 * 2 - 11

        let textStack = NSStackView(views: [titleLabel, bodyLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 11
        row.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: bg.topAnchor, constant: 13),
            row.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 15),
            row.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -15),
            row.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -13),
        ])

        contentView = bg
        let fit = row.fittingSize
        setContentSize(NSSize(width: ToastPanel.width, height: max(74, fit.height + 26)))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // 由 ToastBackground 回调：悬停暂停倒计时，点击立即关闭
    func pointerInside(_ inside: Bool) {
        hovering = inside
        deadline = inside ? nil : Date().addingTimeInterval(2.6)
    }

    func dismissNow() { beginHide() }

    func present(done: @escaping () -> Void) {
        onDone = done
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            orderFrontRegardless()
            deadline = Date().addingTimeInterval(4.0)
            return
        }
        let vf = screen.visibleFrame
        let size = frame.size
        let target = NSPoint(x: vf.maxX - size.width - 14, y: vf.maxY - size.height - 12)

        alphaValue = 0
        setFrameOrigin(NSPoint(x: target.x + 28, y: target.y))
        orderFrontRegardless()
        log("通知横幅已显示，frame=\(NSStringFromRect(NSRect(origin: target, size: size)))")

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrameOrigin(target)
        }
        deadline = Date().addingTimeInterval(4.6)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let d = self.deadline else { return }
            if self.hovering { return }
            if Date() >= d { self.beginHide() }
        }
    }

    private func beginHide() {
        guard !hiding else { return }
        hiding = true
        ticker?.invalidate()
        ticker = nil
        var f = frame
        f.origin.x += 22
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            self.animator().setFrame(f, display: true)
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.onDone?()
            self?.onDone = nil
        })
    }
}
