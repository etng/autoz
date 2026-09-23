// Artwork.swift — 程序内唯一的矢量图形来源
//
// 设计语义（一眼能读懂的那种）：
//   ・深空蓝渐变圆角背板 = 地球/时区，上面铺一层极淡的经纬网格做质感
//   ・白色表盘环 + 刻度    = 时钟
//   ・分针指 12、时针指 8  = **8 点 = UTC+8 = 东八区**，这就是程序在讲的那件事
//   ・橙红时针            = 呼应用户需求里「不是我系统时区时标题变色」的提示色
//
// 同一份绘制代码供三处使用，保证视觉一致：
//   1. build 时导出 AppIcon.icns（makeicon.swift）
//   2. 运行期 NSApp.applicationIconImage / 关于窗口里的大图标
//   3. 通知横幅左侧的小图标

import Cocoa

enum Artwork {

    enum Palette {
        static let skyTop    = NSColor(srgbRed: 0.318, green: 0.514, blue: 0.878, alpha: 1) // #5183E0
        static let skyBottom = NSColor(srgbRed: 0.055, green: 0.114, blue: 0.263, alpha: 1) // #0E1D43
        static let dial      = NSColor(white: 1.0, alpha: 0.97)
        static let tick      = NSColor(white: 1.0, alpha: 0.70)
        static let accent    = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.28, alpha: 1)    // #FF6B48
    }

    /// 把图标画进任意 CGContext（坐标：原点左下，边长 = size）
    static func drawIcon(in ctx: CGContext, size s: CGFloat) {
        let tiny = s < 64               // 小尺寸要简化并加粗，否则细节糊成一团

        let pad = s * 0.0977            // macOS 图标规范：内容区约占 80%，四周留透明边
        let body = CGRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
        let radius = body.width * 0.2237
        let cx = body.midX, cy = body.midY
        let half = body.width / 2
        let space = CGColorSpaceCreateDeviceRGB()

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()

        // ── 1. 背板渐变
        if let g = CGGradient(colorsSpace: space,
                              colors: [Palette.skyTop.cgColor, Palette.skyBottom.cgColor] as CFArray,
                              locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: body.minX, y: body.maxY),
                                   end: CGPoint(x: body.maxX, y: body.minY),
                                   options: [])
        }

        // ── 2. 左上柔光 + 内缘高光，避免大面积死板
        if let g = CGGradient(colorsSpace: space,
                              colors: [NSColor(white: 1, alpha: 0.20).cgColor,
                                       NSColor(white: 1, alpha: 0.0).cgColor] as CFArray,
                              locations: [0, 1]) {
            let c = CGPoint(x: cx - half * 0.38, y: cy + half * 0.60)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: half * 1.10, options: [])
        }
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setLineWidth(s * 0.012)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.17).cgColor)
        ctx.strokePath()

        // ── 3. 表盘环（细一点才显精致）
        let dialR = half * (tiny ? 0.56 : 0.535)
        let ringW = s * (tiny ? 0.075 : 0.020)
        let rr = dialR - ringW / 2
        ctx.setLineWidth(ringW)
        ctx.setStrokeColor(Palette.dial.withAlphaComponent(0.94).cgColor)
        ctx.strokeEllipse(in: CGRect(x: cx - rr, y: cy - rr, width: 2 * rr, height: 2 * rr))

        // ── 4. 12/3/6/9 四个小圆点代替刻度线：形状与指针不同，不会视觉粘连
        if !tiny {
            let dotR = s * 0.0125
            let dist = dialR - ringW - s * 0.036
            ctx.setFillColor(NSColor(white: 1, alpha: 0.45).cgColor)
            for i in stride(from: 0, to: 12, by: 3) {
                let a = CGFloat(i) * .pi / 6
                let px = cx + sin(a) * dist, py = cy + cos(a) * dist
                ctx.fillEllipse(in: CGRect(x: px - dotR, y: py - dotR, width: 2 * dotR, height: 2 * dotR))
            }
        }

        // ── 5. 指针：分针指 12，时针指 8（= UTC+8）
        ctx.setLineCap(.round)
        let minLen = dialR * 0.48
        ctx.setLineWidth(s * (tiny ? 0.068 : 0.022))
        ctx.setStrokeColor(Palette.dial.cgColor)
        ctx.move(to: CGPoint(x: cx, y: cy - dialR * 0.06))
        ctx.addLine(to: CGPoint(x: cx, y: cy + minLen))
        ctx.strokePath()

        let a8 = CGFloat(240.0) * .pi / 180      // 8 点钟方向（12 点起顺时针 240°）
        let hourLen = dialR * (tiny ? 0.34 : 0.34)
        ctx.setLineWidth(s * (tiny ? 0.082 : 0.032))
        ctx.setStrokeColor((tiny ? Palette.dial : Palette.accent).cgColor)
        ctx.move(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx + sin(a8) * hourLen, y: cy + cos(a8) * hourLen))
        ctx.strokePath()

        // ── 6. 中心轴
        let hub = s * (tiny ? 0.050 : 0.026)
        ctx.setFillColor(Palette.dial.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - hub, y: cy - hub, width: 2 * hub, height: 2 * hub))

        ctx.restoreGState()
    }

    /// 运行期用的 NSImage（关于窗口、通知、Dock 图标）
    static func iconImage(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext { drawIcon(in: ctx, size: size) }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    /// 供 makeicon 导出 PNG
    static func pngData(size: CGFloat) -> Data? {
        let px = Int(size.rounded())
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        drawIcon(in: ctx, size: CGFloat(px))
        guard let cg = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
