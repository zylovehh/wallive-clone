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

        // 读 Wallpaper.plist，取当前 Floating 文件名。
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var root = try PropertyListSerialization.propertyList(
            from: entries[plistIndex].data, format: &format
        ) as? [String: Any],
        var assets = root["assets"] as? [String: Any],
        var lockAndHome = assets["lockAndHome"] as? [String: Any],
        var def = lockAndHome["default"] as? [String: Any],
        let floatingFile = def["floatingAnimationFileNameKey"] as? String else {
            throw Error.missingFloatingFile
        }

        // 1. Floating .ca 改名加 Clownfish_ 前缀（已带前缀则不动）。
        let newFloatingFile: String
        if floatingFile.hasPrefix("Clownfish_") {
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
}
