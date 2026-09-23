// ui.swift — 程序自绘的界面层
//
//   1. AdvancedWindowController：高级配置窗口（关于 + 全部次级操作）。
//      设计约定：**实底、高对比**。窗口背景 windowBackgroundColor（不采样背后窗口），
//      卡片 controlBackgroundColor，正文 labelColor 系 —— 深色/浅色模式都能读清。
//   2. ToastCenter / ToastPanel：程序内通知横幅（自绘，不用系统通知权限，也不用 osascript）。
//   3. 图标与矢量图形见 artwork.swift。

import Cocoa

// MARK: - 打开「日期与时间」设置面板

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

// MARK: - 高级配置窗口要执行的动作（由 AppDelegate 实现，避免界面层反向依赖业务）

protocol AutoZActions: AnyObject {
    func azToggleSync()
    func azCheckAndSync()
    func azCheckOnly()
    func azRestore()
    func azSetShowSeconds(_ on: Bool)
    func azSetLaunchAtLogin(_ on: Bool)
    func azInstallHelper()
    func azUninstallHelper()
    func azSetBackend(_ backend: PrivBackend)
    func azOpenDateSettings()
    func azOpenLog()
    func azCopyDiagnostics()
    func azTestNotification()
}

// MARK: - 高级配置窗口

final class AdvancedWindowController: NSWindowController {

    static let shared = AdvancedWindowController()
    weak var actions: AutoZActions?

    private let headerBar   = NSVisualEffectView()
    private let headerIcon  = NSImageView()
    private let headerTitle = NSTextField(labelWithString: appDisplayName)
    private let headerSub   = NSTextField(labelWithString: "")
    private let badge       = NSStackView()
    private let badgeDot    = NSView()
    private let badgeText   = NSTextField(labelWithString: "")
    private let content     = NSStackView()
    private let scroll      = NSScrollView()
    private let footNote    = NSTextField(labelWithString: "")

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 860),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = appDisplayName
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        // 实底：不透明窗口背景，浅/深色各自解析，保证对比度
        w.isOpaque = true
        w.backgroundColor = .windowBackgroundColor
        super.init(window: w)
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(b)?.isHidden = true
        }
        buildShell()
    }

    required init?(coder: NSCoder) { fatalError("不支持归档") }

    // MARK: 外壳（一次建好：头图 / 滚动区 / 底栏）

    private func buildShell() {
        guard let w = window, let root = w.contentView else { return }

        headerBar.material = .headerView
        headerBar.blendingMode = .withinWindow
        headerBar.state = .active
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

        badgeDot.wantsLayer = true
        badgeDot.layer?.cornerRadius = 4
        badgeDot.translatesAutoresizingMaskIntoConstraints = false
        badgeText.font = .systemFont(ofSize: 12, weight: .medium)
        badge.orientation = .horizontal
        badge.alignment = .centerY
        badge.spacing = 6
        badge.setViews([badgeDot, badgeText], in: .leading)
        badge.translatesAutoresizingMaskIntoConstraints = false

        headerBar.addSubview(headerIcon)
        headerBar.addSubview(headerTitle)
        headerBar.addSubview(headerSub)
        headerBar.addSubview(badge)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        root.addSubview(scroll)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        let clip = NSClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        clip.addSubview(content)

        let footer = NSVisualEffectView()
        footer.material = .headerView
        footer.blendingMode = .withinWindow
        footer.state = .active
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)

        footNote.font = .systemFont(ofSize: 11)
        footNote.textColor = .secondaryLabelColor
        footNote.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(closeConsole(_:)))
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\r"
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        footer.addSubview(footNote)
        footer.addSubview(closeBtn)

        let footSep = NSBox()
        footSep.boxType = .separator
        footSep.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footSep)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: root.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 104),

            headerIcon.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 22),
            headerIcon.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor, constant: 6),
            headerIcon.widthAnchor.constraint(equalToConstant: 60),
            headerIcon.heightAnchor.constraint(equalToConstant: 60),

            headerTitle.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 15),
            headerTitle.topAnchor.constraint(equalTo: headerIcon.topAnchor, constant: 2),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: headerBar.trailingAnchor, constant: -22),

            headerSub.leadingAnchor.constraint(equalTo: headerTitle.leadingAnchor),
            headerSub.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 4),

            badge.leadingAnchor.constraint(equalTo: headerTitle.leadingAnchor),
            badge.topAnchor.constraint(equalTo: headerSub.bottomAnchor, constant: 8),
            badgeDot.widthAnchor.constraint(equalToConstant: 8),
            badgeDot.heightAnchor.constraint(equalToConstant: 8),

            scroll.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footSep.topAnchor),

            footSep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footSep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footSep.bottomAnchor.constraint(equalTo: footer.topAnchor),

            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 54),

            footNote.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 22),
            footNote.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            closeBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -22),
            closeBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    // MARK: 展示与刷新

    func show() {
        // 屏幕矮（笔记本）时别把窗口顶出屏幕
        if let screen = NSScreen.main ?? NSScreen.screens.first, let w = window {
            let maxH = screen.visibleFrame.height - 70
            if w.frame.height > maxH {
                var f = w.frame
                f.size.height = max(460, maxH)
                w.setFrame(f, display: false)
            }
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        if let f = window?.frame { log("高级配置窗口已显示，frame=\(NSStringFromRect(f))") }
    }

    func refresh() {
        headerSub.stringValue = "版本 \(K.version) · \(appTagline)"

        // 用文件判断代替 ping：刷新可能发生在主线程上，不能因为助手卡住就把界面顶住
        let helperOK = HelperChannel.socketExists && HelperChannel.binaryInstalled && HelperChannel.plistInstalled
        let helperInstalled = HelperChannel.plistInstalled
        let (dot, text): (NSColor, String) = helperOK
            ? (.systemGreen, "免授权模式已启用 · 改时区零弹窗")
            : (helperInstalled ? .systemOrange : .systemGray,
               helperInstalled ? "助手已就位但没响应 · 可在下面重装" : "免授权模式未安装 · 每次改时区会弹授权框")
        badgeDot.layer?.backgroundColor = dot.cgColor
        badgeText.stringValue = text
        badgeText.textColor = .secondaryLabelColor

        content.setViews(rebuildCards(helperOK: helperOK, helperInstalled: helperInstalled), in: .top)
        footNote.stringValue = "\(appDisplayName) \(K.version) · MIT License · 日志 ~/Library/Logs/AutoZ.log"
        log("高级配置已刷新（助手就绪=\(helperOK)）")
    }

    private func rebuildCards(helperOK: Bool, helperInstalled: Bool) -> [NSView] {
        let store = Store.shared
        let sys = systemZoneID()
        let off = isOffSystemZone()

        // ── A. 时区同步
        let syncSwitch = NSButton(checkboxWithTitle: "跟随出口 IP 自动同步系统时区",
                                  target: self, action: #selector(toggleSync(_:)))
        syncSwitch.state = store.syncEnabled ? .on : .off

        let btnCheck = button("立即检查并同步", #selector(checkAndSync(_:)))
        let btnOnly  = button("仅查询（不改系统）", #selector(checkOnly(_:)))
        let btnBack  = button(store.originalZone.map { "恢复开启前状态（\($0)）" } ?? "恢复开启前状态",
                              #selector(restore(_:)))
        btnBack.isEnabled = store.originalZone != nil

        var detLines: [String] = []
        if let d = store.lastDetection {
            detLines.append("出口 IP  \(d.ip) · \(d.locationText)")
            detLines.append("解析时区  \(d.zoneID)  ← \(d.zoneSource)")
        } else {
            detLines.append("出口 IP  尚未检测")
        }
        detLines.append("系统时区  \(sys.isEmpty ? "未知" : sys)\(off ? "　⚠️ 非东八区，菜单栏标题已变橙" : "　✓ 与菜单栏显示一致")")
        if store.lastAction != "—" { detLines.append("上次动作  \(store.lastAction)") }

        let cardA = card("时区同步", [
            syncSwitch,
            row(btnCheck, btnOnly, btnBack),
            caption(detLines.joined(separator: "\n")),
        ])

        // ── B. 菜单栏
        let secSwitch = NSButton(checkboxWithTitle: "在菜单栏标题里显示秒",
                                 target: self, action: #selector(toggleSeconds(_:)))
        secSwitch.state = store.showSeconds ? .on : .off
        let cardB = card("菜单栏", [
            secSwitch,
            caption("当前标题  \(beijingClockText(showSeconds: store.showSeconds))　\(beijingDateText())"),
            caption("显示时间与系统时区不一致时，标题会变橙。"),
        ])

        // ── B2. 启动
        let loginSwitch = NSButton(checkboxWithTitle: "登录时自动启动",
                                   target: self, action: #selector(toggleLaunchAtLogin(_:)))
        loginSwitch.state = LoginItem.isEnabled ? .on : .off
        let cardB2 = card("启动", [
            loginSwitch,
            caption("开机自启：\(LoginItem.statusText)"),
            caption("写的是 \(LoginItem.plistURL.path)，下次登录生效；"),
            caption("可在「系统设置 → 通用 → 登录项」里查看或撤销。"),
        ])

        // ── C. 改时区方式
        let btnInstall   = button(helperOK ? "重新安装助手" : "安装免授权助手（推荐）", #selector(installHelper(_:)))
        let btnUninstall = button("卸载助手", #selector(uninstallHelper(_:)))
        btnUninstall.isEnabled = helperInstalled

        let r1 = NSButton(radioButtonWithTitle: "免授权助手（推荐，装一次以后不再弹框）",
                          target: self, action: #selector(useHelper(_:)))
        let r2 = NSButton(radioButtonWithTitle: "一次性授权 · 原生 Security.framework",
                          target: self, action: #selector(useNative(_:)))
        let r3 = NSButton(radioButtonWithTitle: "一次性授权 · AppleScript（回退方案）",
                          target: self, action: #selector(useAppleScript(_:)))
        r1.state = store.privBackend == .helper ? .on : .off
        r2.state = store.privBackend == .native ? .on : .off
        r3.state = store.privBackend == .appleScript ? .on : .off

        let cardC = card("改时区方式", [
            caption(helperOK ? "助手状态：已启用（launchd 按需拉起，空闲自动退出，不常驻）"
                             : (helperInstalled ? "助手状态：文件已就位但未响应" : "助手状态：未安装")),
            row(btnInstall, btnUninstall),
            caption("通道（改了立即生效）"),
            r1, r2, r3,
        ])

        // ── D. 维护
        let cardD = card("维护", [
            row(button("打开「日期与时间」设置", #selector(openDateSettings(_:))),
                button("打开运行日志", #selector(openLog(_:))),
                button("复制诊断信息", #selector(copyDiagnostics(_:))),
                button("测试通知", #selector(testNotification(_:)))),
            caption("日志 ~/Library/Logs/AutoZ.log　助手日志 \(HelperK.logPath)"),
            caption("偏好 ~/Library/Preferences/\(bundleID).plist"),
        ])

        // ── E. 关于（一屏内说完，详细内容在项目文档里）
        let cardE = card("关于", [
            caption("菜单栏常显东八区（UTC+8）时间，格式跟随系统时钟；与系统时区不一致时标题变橙。开启同步后按出口 IP 写入系统时区，并关掉「自动设置时区」，随时可一键还原。"),
            caption("出口 IP 走代理或 VPN 时，解析出的是代理所在地，不是你的实际所在地。"),
            caption("免费开源软件（MIT）。完整说明、隐私与安全边界见项目文档 docs/。"),
        ])

        return [cardA, cardB, cardB2, cardC, cardD, cardE]
    }

    // MARK: 小组件

    private func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        return b
    }

    private func row(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 8
        return s
    }

    private func caption(_ text: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 12)
        t.textColor = .secondaryLabelColor
        t.maximumNumberOfLines = 6
        t.preferredMaxLayoutWidth = 688
        return t
    }

    private func card(_ title: String, _ rows: [NSView]) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        // 深色下 windowBackgroundColor 与 controlBackgroundColor 常常一样，卡片会"糊"在背景上；
        // 用 labelColor 的低透明度叠加，两种外观下都能看出层次
        box.fillColor = NSColor.labelColor.withAlphaComponent(0.075)
        box.borderColor = NSColor.separatorColor.withAlphaComponent(0.7)
        box.borderWidth = 1
        box.cornerRadius = 10
        box.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [label] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 13, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: 724),
        ])
        return box
    }

    // MARK: 动作转发（界面层不碰业务，全部交回 AppDelegate）

    @objc private func closeConsole(_ sender: Any) { window?.orderOut(nil) }
    @objc private func toggleSync(_ sender: Any)   { actions?.azToggleSync() }
    @objc private func checkAndSync(_ sender: Any) { actions?.azCheckAndSync() }
    @objc private func checkOnly(_ sender: Any)    { actions?.azCheckOnly() }
    @objc private func restore(_ sender: Any)      { actions?.azRestore() }
    @objc private func toggleSeconds(_ sender: Any) { actions?.azSetShowSeconds((sender as? NSButton)?.state == .on) }
    @objc private func toggleLaunchAtLogin(_ sender: Any) { actions?.azSetLaunchAtLogin((sender as? NSButton)?.state == .on) }
    @objc private func installHelper(_ sender: Any) { actions?.azInstallHelper() }
    @objc private func uninstallHelper(_ sender: Any) { actions?.azUninstallHelper() }
    @objc private func useHelper(_ sender: Any)      { actions?.azSetBackend(.helper) }
    @objc private func useNative(_ sender: Any)      { actions?.azSetBackend(.native) }
    @objc private func useAppleScript(_ sender: Any) { actions?.azSetBackend(.appleScript) }
    @objc private func openDateSettings(_ sender: Any) { actions?.azOpenDateSettings() }
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
