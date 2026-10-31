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

    /// 检查已解密的标准 zip 包。
    public static func inspectPlaintextZip(_ zipData: Data, zip: ZipEditing) throws -> TendiesPackageInfo {
        let entries = try zip.listEntries(in: zipData)
        // 找 contents/<名>.wallpaper/Wallpaper.plist，借此定位描述符 UUID 与壁纸目录。
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
