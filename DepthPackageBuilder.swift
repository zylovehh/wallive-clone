// DepthPackageBuilder.swift
// 干净重写：给标准 .tendies 包加上深景配置（已验证的配方）。
// 配方（2026-11-01 装机验证通过，开关 + 前缀组合；无加密也可出深景）：
//   1. 加入 versions/1/com.apple.posterkit.provider.instance.renderingConfiguration.plist
//      （PRPosterRenderingConfiguration：depthEffectDisabled = False，
//       motionEffectsDisabled = False；即深景总开关）；
//   2. Floating .ca 目录名加 Clownfish_ 前缀，并同步改 Wallpaper.plist 里
//      assets.lockAndHome.default.floatingAnimationFileNameKey 的值。
// 本文件只做包内变换，不碰安装、不含广告 SDK、不含解锁逻辑。
//
// 说明：渲染配置模板以下以 base64 内嵌（282 字节，与 law 解密包里的文件字节一致）。
// zip 层复用 TendiesPackage.swift 的 ZipEditing 协议。

import Foundation

public enum DepthPackageBuilder {

    /// 渲染配置模板（base64，解码后即为 law 包里的 renderingConfiguration.plist 原文件）。
    private static let renderingConfigurationBase64 =
        "YnBsaXN0MDDUAQIDBAUGFBdZJGFyY2hpdmVyWCRvYmplY3RzVCR0b3BYJHZlcnNpb25fEA9OU0tleWVkQXJjaGl2ZXKjBwgOVSRudWxs0wkKCwwNDVYkY2xhc3NfEBNkZXB0aEVmZmVjdERpc2FibGVkXxAVbW90aW9uRWZmZWN0c0Rpc2FibGVkgAII0g8QERJYJGNsYXNzZXNaJGNsYXNzbmFtZaISE18QHlBSUG9zdGVyUmVuZGVyaW5nQ29uZmlndXJhdGlvblhOU09iamVjdNEVFlRyb290gAESAAGGoAgRGyQpMkRITlVccoqMjZKbpqnK09bb3QAAAAAAAAEBAAAAAAAAABgAAAAAAAAAAAAAAAAAAADi"

    public enum Error: Swift.Error {
        case missingWallpaperPlist
        case missingFloatingFile
        case badTemplate
    }

    /// 给标准 .tendies zip 加上深景配置，返回新的标准 zip（不加密）。
    /// 注意：开关与前缀各自是否充分尚未拆开验证；两个一起上是装机验证过的组合。
    public static func addingDepthConfiguration(to zipData: Data, zip: ZipEditing) throws -> Data {
        var entries: [(path: String, data: Data)] = []
        let paths = try zip.listEntries(in: zipData)
        for path in paths {
            entries.append((path: path, data: try zip.readEntry(path, in: zipData)))
        }

        // 定位 Wallpaper.plist 与描述符目录。
        guard let plistIndex = entries.firstIndex(where: { $0.path.hasSuffix(".wallpaper/Wallpaper.plist") }) else {
            throw Error.missingWallpaperPlist
        }
        let plistPath = entries[plistIndex].path
        let parts = plistPath.split(separator: "/")
        // descriptors/<UUID>/versions/1/contents/<名>.wallpaper/Wallpaper.plist
        let versionsDir = parts[0..<4].joined(separator: "/") // descriptors/<UUID>/versions/1
        let wallpaperDir = parts[0..<parts.count - 1].joined(separator: "/")

        // 读 Wallpaper.plist，取当前 Floating 文件名；没有漂浮层也照加深景开关
        // （只补渲染配置、跳过改名），用户拍板：没层也不拦。
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var root = try PropertyListSerialization.propertyList(
            from: entries[plistIndex].data, format: &format
        ) as? [String: Any],
        var assets = root["assets"] as? [String: Any],
        var lockAndHome = assets["lockAndHome"] as? [String: Any],
        var def = lockAndHome["default"] as? [String: Any] else {
            throw Error.missingWallpaperPlist
        }
        let floatingFile = def["floatingAnimationFileNameKey"] as? String

        // 1. Floating .ca 改名加 Clownfish_ 前缀（名字里已含 Clownfish 则不动——
        //    旧格式转换产物形如 7400.Clownfish_Floating-…，别再二次加前缀）。
        //    没有漂浮层（键都没有）就整段跳过，只补下面的渲染配置。
        if let floatingFile {
            let newFloatingFile: String
            if floatingFile.contains("Clownfish") {
                newFloatingFile = floatingFile
            } else {
                newFloatingFile = "Clownfish_" + floatingFile
                let oldDir = wallpaperDir + "/" + floatingFile
                let newDir = wallpaperDir + "/" + newFloatingFile
                entries = entries.map { entry in
                    if entry.path == oldDir || entry.path.hasPrefix(oldDir + "/") {
                        return (path: newDir + entry.path.dropFirst(oldDir.count), data: entry.data)
                    }
                    return entry
                }
                // 同步 Wallpaper.plist 的键值。
                def["floatingAnimationFileNameKey"] = newFloatingFile
                lockAndHome["default"] = def
                assets["lockAndHome"] = lockAndHome
                root["assets"] = assets
                let newPlist = try PropertyListSerialization.data(
                    fromPropertyList: root, format: format, options: 0
                )
                entries[plistIndex] = (path: plistPath, data: newPlist)
            }
        }

        // 2. 加入渲染配置 plist（已存在则替换为模板字节，保证一致）。
        guard let templateData = Data(base64Encoded: renderingConfigurationBase64) else {
            throw Error.badTemplate
        }
        let renderingPath = versionsDir + "/com.apple.posterkit.provider.instance.renderingConfiguration.plist"
        if let existing = entries.firstIndex(where: { $0.path == renderingPath }) {
            entries[existing] = (path: renderingPath, data: templateData)
        } else {
            entries.append((path: renderingPath, data: templateData))
        }

        return try zip.rebuild(entries: entries)
    }

    /// 给已解包的描述符目录补深景结构（V1.13，无配对装包路用）。
    /// 1. Floating .ca 目录加 Clownfish_ 前缀（有 Floating 层才改），同步 Wallpaper.plist；
    /// 2. versions/1/ 补 renderingConfiguration.plist（总是写，已存在则覆盖）——
    ///    系统渲染壁纸前要读这份配置，缺了就是黑卡片。Vellum 装包时同样补：
    ///    静态包没有浮动层也照补 282B 声明，所以配置永远写。
    /// 调用时机：装包路的改 id/改名都做完之后（保证清单值和目录名一致）。
    public static func applyingDepthConfiguration(toDescriptorDir dir: URL,
                                                  log: (String) -> Void) {
        let fm = FileManager.default
        let versionsDir = dir.appendingPathComponent("versions/1")
        let contentsDir = versionsDir.appendingPathComponent("contents")
        guard fm.fileExists(atPath: contentsDir.path) else {
            log("深景补齐：找不到 contents 目录，跳过。")
            return
        }
        // 找第一个 .wallpaper 目录里的 Wallpaper.plist（跟 zip 版一致只处理一个）。
        let wallDirNames = (try? fm.contentsOfDirectory(atPath: contentsDir.path))?
            .filter { $0.hasSuffix(".wallpaper") } ?? []
        if wallDirNames.isEmpty {
            log("深景补齐：contents 里没有 .wallpaper 目录，跳过浮动层改名（配置照补）。")
        }
        if let wallName = wallDirNames.first {
            let wallpaperDir = contentsDir.appendingPathComponent(wallName)
            let plistURL = wallpaperDir.appendingPathComponent("Wallpaper.plist")
            guard var plist = try? PosterBoardPlist.load(contentsOf: plistURL),
                  var assets = plist["assets"] as? [String: Any],
                  var lockAndHome = assets["lockAndHome"] as? [String: Any],
                  var def = lockAndHome["default"] as? [String: Any] else {
                log("深景补齐：清单结构读不出，跳过浮动层改名（配置照补）。")
                writeRenderingConfig(versionsDir: versionsDir, log: log)
                return
            }
            if let floatingFile = def["floatingAnimationFileNameKey"] as? String,
               !floatingFile.isEmpty, !floatingFile.contains("Clownfish") {
                let oldDir = wallpaperDir.appendingPathComponent(floatingFile)
                let newFile = "Clownfish_" + floatingFile
                let newDir = wallpaperDir.appendingPathComponent(newFile)
                var renamed = false
                if fm.fileExists(atPath: oldDir.path) {
                    do {
                        try fm.moveItem(at: oldDir, to: newDir)
                        renamed = true
                    } catch {
                        log("深景补齐：浮动层改名没成（\(error.localizedDescription)），继续补配置。")
                    }
                } else {
                    log("深景补齐：清单指的浮动层「\(floatingFile)」目录不在包里，跳过改名（配置照补）。")
                }
                if renamed {
                    def["floatingAnimationFileNameKey"] = newFile
                    lockAndHome["default"] = def
                    assets["lockAndHome"] = lockAndHome
                    plist["assets"] = assets
                    if let data = try? PropertyListSerialization.data(
                        fromPropertyList: plist, format: .xml, options: 0) {
                        try? data.write(to: plistURL)
                    }
                    log("深景补齐：浮动层加了 Clownfish_ 前缀。")
                }
            } else {
                let current = def["floatingAnimationFileNameKey"] as? String
                if current == nil {
                    log("深景补齐：清单里没有浮动层键（双层包），跳过改名（配置照补）。")
                } else if current!.isEmpty {
                    log("深景补齐：清单浮动层键是空的，跳过改名（配置照补）。")
                } else {
                    log("深景补齐：浮动层已带 Clownfish_ 前缀，跳过改名（配置照补）。")
                }
            }
        }
        writeRenderingConfig(versionsDir: versionsDir, log: log)
    }

    /// 渲染配置写盘：已存在则覆盖，保证字节一致。
    private static func writeRenderingConfig(versionsDir: URL, log: (String) -> Void) {
        guard let templateData = Data(base64Encoded: renderingConfigurationBase64) else {
            log("深景补齐：内置模板坏了，跳过。把这条发我。")
            return
        }
        let renderingURL = versionsDir
            .appendingPathComponent("com.apple.posterkit.provider.instance.renderingConfiguration.plist")
        do {
            try templateData.write(to: renderingURL)
            log("深景补齐：渲染配置已补上。")
        } catch {
            log("深景补齐：渲染配置写盘没成（\(error.localizedDescription)）。")
        }
    }
}
