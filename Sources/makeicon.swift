// makeicon.swift — 把 Artwork 里的矢量图标导出成 .iconset（再由 build.sh 调 iconutil 打成 .icns）
//
// 用法:
//   makeicon <输出目录.iconset>      生成整套 iconset
//   makeicon --png <文件> <尺寸>     只导出一张 PNG（预览/调试用）

import Cocoa

@main
struct MakeIcon {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.first == "--png" {
            guard args.count >= 3, let size = Double(args[2]) else {
                FileHandle.standardError.write(Data("用法: makeicon --png <文件> <尺寸>\n".utf8))
                exit(2)
            }
            guard let data = Artwork.pngData(size: CGFloat(size)) else {
                FileHandle.standardError.write(Data("绘制失败\n".utf8)); exit(1)
            }
            do { try data.write(to: URL(fileURLWithPath: args[1])) }
            catch { FileHandle.standardError.write(Data("写入失败: \(error)\n".utf8)); exit(1) }
            print("已导出 \(args[1])（\(Int(size))px）")
            exit(0)
        }

        let outDir = args.first ?? "build/AppIcon.iconset"
        let fm = FileManager.default
        try? fm.removeItem(atPath: outDir)
        do { try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch { FileHandle.standardError.write(Data("创建目录失败: \(error)\n".utf8)); exit(1) }

        // iconset 必须包含这 10 个文件名（同名尺寸各出现两次，用缓存避免重复绘制）
        let entries: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        var cache: [Int: Data] = [:]
        for (name, px) in entries {
            let data: Data
            if let c = cache[px] { data = c } else {
                guard let d = Artwork.pngData(size: CGFloat(px)) else {
                    FileHandle.standardError.write(Data("绘制 \(px)px 失败\n".utf8)); exit(1)
                }
                cache[px] = d
                data = d
            }
            let path = outDir + "/" + name + ".png"
            do { try data.write(to: URL(fileURLWithPath: path)) }
            catch { FileHandle.standardError.write(Data("写入 \(path) 失败\n".utf8)); exit(1) }
        }
        print("已生成 iconset: \(outDir)（\(entries.count) 个文件）")
    }
}
