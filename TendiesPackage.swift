// TendiesPackage.swift
// 干净重写：.tendies / .wallive 包的检查与描述符结构校验。
// 包结构（已验证）：标准 PosterBoard 描述符包，顶层为
//   descriptors/<UUID>/versions/1/contents/<名>.wallpaper/
// 内含 Background / Floating / Foreground 三个 .ca + Wallpaper.plist。
// 本文件不含广告 SDK、不含解锁逻辑、不含 exploit 代码。
//
// 说明：iOS 没有内置 zip 读写，zip 层由 ZipEditing 协议抽象，
// 接入时用 ZIPFoundation 或 SSZipArchive 实现该协议即可。

import Foundation

/// zip 读写抽象（接入方实现；本文件只依赖这个接口，不绑定具体 zip 库）。
public protocol ZipEditing {
    /// 列出包内全部条目路径。
    func listEntries(in archive: Data) throws -> [String]
    /// 读出指定条目的字节。
    func readEntry(_ path: String, in archive: Data) throws -> Data
    /// 返回一个新包：以 entries 为全部内容（用于改名、增删条目后重打）。
    func rebuild(entries: [(path: String, data: Data)]) throws -> Data
}

/// 描述符包的关键信息。
public struct TendiesPackageInfo {
    public let descriptorUUID: String
    public let wallpaperDirectory: String   // contents/<名>.wallpaper
    public let backgroundFile: String?      // 如 7400.WWDC_2022_Background-...ca
    public let floatingFile: String?        // 如 7400.WWDC_2022_Floating-...ca（或 Clownfish_ 前缀版）
    public let foregroundFile: String?
    public let hasRenderingConfiguration: Bool
    public let floatingHasClownfishPrefix: Bool
}

/// 包检查器：识别 WALLIVE1 / 标准 zip，并校验描述符结构。
public enum TendiesPackage {

    public enum Error: Swift.Error {
        case notATendiesPackage
        case missingWallpaperDirectory
        case missingWallpaperPlist
    }

    /// 检查一个包（WALLIVE1 加密包或标准 zip），返回其描述符信息。
    /// WALLIVE1 包会先解密；标准 zip 直接检查。
    public static func inspect(_ data: Data, zip: ZipEditing) throws -> TendiesPackageInfo {
        let plaintext: Data
        if Wallive1Crypto.isWallive1(data) {
            plaintext = try Wallive1Crypto.decrypt(data)
        } else {
            plaintext = data
        }
        return try inspectPlaintextZip(plaintext, zip: zip)
    }

    /// 旧格式判断：包是不是 WWDC22 时代的布局（描述符 7400 / 文件名含 WWDC_2022 / 共用描述符 09E9B685-…）。
    /// iOS 27 读不了这种布局：不转换直接装，不报错但永远不显示。iOS 26 能直接读，不用转。
    public static func isOldFormat(_ data: Data, zip: ZipEditing) -> Bool {
        let plaintext: Data
        if Wallive1Crypto.isWallive1(data) {
            guard let d = try? Wallive1Crypto.decrypt(data) else { return false }
            plaintext = d
        } else {
            plaintext = data
        }
        guard let entries = try? zip.listEntries(in: plaintext) else { return false }
        // 任一 WWDC22 痕迹都算旧格式。
        for e in entries {
            if e.contains("WWDC_2022") || e.contains("WWDC22") { return true }
            if e.contains("09E9B685-7456-4856-9C10-47DF26B76C33") { return true }
        }
        // Wallpaper.plist 里的 identifier 是 7400 也算旧格式。
        if let info = try? inspectPlaintextZip(plaintext, zip: zip) {
            // 描述符 UUID 是共用的 WWDC22 那一个，或壁纸目录名以 7400. 开头。
            if info.descriptorUUID == "09E9B685-7456-4856-9C10-47DF26B76C33" { return true }
            if info.wallpaperDirectory.hasPrefix("7400.") { return true }
        }
        return false
    }

    /// 把旧格式（WWDC22 布局）包改写成 iOS 27 能读的新布局：换一个全新唯一描述符 UUID
    /// 和一个 1000–9999 的随机编号（排除 7400），改掉四处身份（Wallpaper.plist identifier、
    /// userInfo wallpaperRepresentingIdentifier、描述符 sidecar、suggestionMetadata），
    /// 并把文件名里的 WWDC_2022 / 7400 前缀也换掉。返回新包数据（明文 zip；调用方再按需加密）。
    public static func convertingOldFormatToNew(_ data: Data, zip: ZipEditing) throws -> Data {
        let plaintext: Data
        if Wallive1Crypto.isWallive1(data) {
            plaintext = try Wallive1Crypto.decrypt(data)
        } else {
            plaintext = data
        }
        let entries = try zip.listEntries(in: plaintext)
        guard let plistPath = entries.first(where: { $0.hasSuffix(".wallpaper/Wallpaper.plist") }) else {
            throw Error.missingWallpaperPlist
        }
        let parts = plistPath.split(separator: "/")
        guard parts.count >= 6, parts[0] == "descriptors" else {
            throw Error.missingWallpaperDirectory
        }
        let oldUUID = String(parts[1])
        let newUUID = UUID().uuidString
        var newNumber = Int.random(in: 1000...9999)
        while newNumber == 7400 { newNumber = Int.random(in: 1000...9999) }
        let newNumberStr = String(newNumber)

        var out: [(path: String, data: Data)] = []
        for path in entries {
            var newPath = path
            // 文件夹 UUID 换掉。
            if newPath.contains(oldUUID) {
                newPath = newPath.replacingOccurrences(of: oldUUID, with: newUUID)
            }
            // 文件名里的 WWDC_2022 / 7400 前缀换成新编号。
            newPath = newPath.replacingOccurrences(of: "WWDC_2022", with: "WALLPAPER")
            if let range = newPath.range(of: "7400\\.", options: .regularExpression) {
                newPath.replaceSubrange(range, with: "\(newNumberStr).")
            }
            // 目录名里的 7400. 也换掉。
            newPath = newPath.replacingOccurrences(of: "/7400.", with: "/\(newNumberStr).")
            let entryData = try zip.readEntry(path, in: plaintext)
            var finalData = entryData
            // Wallpaper.plist：identifier 改新编号。
            if path.hasSuffix(".wallpaper/Wallpaper.plist") {
                if var plist = try? PropertyListSerialization.propertyList(from: entryData, format: nil) as? [String: Any] {
                    plist["identifier"] = newNumberStr
                    if var userInfo = plist["userInfo"] as? [String: Any] {
                        userInfo["wallpaperRepresentingIdentifier"] = newNumberStr
                        plist["userInfo"] = userInfo
                    }
                    if let newPlist = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                        finalData = newPlist
                    }
                }
            }
            // suggestionMetadata：descriptorIdentifier 换新 UUID，7400.DYNAMIC 换新编号。
            if path.hasSuffix("suggestionMetadata.plist") {
                if var plist = try? PropertyListSerialization.propertyList(from: entryData, format: nil) as? [String: Any] {
                    plist["descriptorIdentifier"] = newUUID
                    if let s = plist["suggestionMetadata"] as? String, s.contains("7400.DYNAMIC") {
                        plist["suggestionMetadata"] = s.replacingOccurrences(of: "7400.DYNAMIC", with: "\(newNumberStr).DYNAMIC")
                    }
                    if let newPlist = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                        finalData = newPlist
                    }
                }
            }
            // 描述符 sidecar：内容是 UUID 就换新 UUID。
            if path.hasSuffix("com.apple.posterkit.provider.descriptor.identifier") {
                if let s = String(data: entryData, encoding: .utf8), s.contains(oldUUID) {
                    finalData = s.replacingOccurrences(of: oldUUID, with: newUUID).data(using: .utf8) ?? entryData
                }
            }
            out.append((path: newPath, data: finalData))
        }
        return try zip.rebuild(entries: out)
    }

    /// 检查已解密的标准 zip 包。
    public static func inspectPlaintextZip(_ zipData: Data, zip: ZipEditing) throws -> TendiesPackageInfo {
        let entries = try zip.listEntries(in: zipData)
        guard let plistPath = entries.first(where: { $0.hasSuffix(".wallpaper/Wallpaper.plist") }) else {
            throw Error.missingWallpaperPlist
        }
        // 路径形如 descriptors/<UUID>/versions/1/contents/<名>.wallpaper/Wallpaper.plist
        let parts = plistPath.split(separator: "/")
        guard parts.count >= 6, parts[0] == "descriptors" else {
            throw Error.missingWallpaperDirectory
        }
        let uuid = String(parts[1])
        let wallpaperDir = parts[3..<parts.count - 1].joined(separator: "/")
        let prefix = "descriptors/\(uuid)/versions/1/contents/\(wallpaperDir)/"

        // 读 Wallpaper.plist，取三层文件名（键在 assets.lockAndHome.default 下）。
        let plistData = try zip.readEntry(plistPath, in: zipData)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: &format)
        var backgroundFile: String?
        var floatingFile: String?
        var foregroundFile: String?
        if let root = plist as? [String: Any],
           let assets = root["assets"] as? [String: Any],
           let lockAndHome = assets["lockAndHome"] as? [String: Any],
           let def = lockAndHome["default"] as? [String: Any] {
            backgroundFile = def["backgroundAnimationFileName"] as? String
            floatingFile = def["floatingAnimationFileNameKey"] as? String
            foregroundFile = def["foregroundAnimationFileName"] as? String
        }
        _ = prefix // 保留目录前缀供调用方拼条目路径。

        let hasRenderingConfiguration = entries.contains {
            $0.hasSuffix("com.apple.posterkit.provider.instance.renderingConfiguration.plist")
        }
        let floatingHasClownfishPrefix = (floatingFile ?? "").hasPrefix("Clownfish_")

        return TendiesPackageInfo(
            descriptorUUID: uuid,
            wallpaperDirectory: wallpaperDir,
            backgroundFile: backgroundFile,
            floatingFile: floatingFile,
            foregroundFile: foregroundFile,
            hasRenderingConfiguration: hasRenderingConfiguration,
            floatingHasClownfishPrefix: floatingHasClownfishPrefix
        )
    }
}
