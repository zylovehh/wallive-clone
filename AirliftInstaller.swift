// AirliftInstaller.swift
// 真安装通道：走 AirliftFFI 的配对隧道写文件，替换掉原来手写的
// lockdownd/AFC 实现（那套握手已被证伪，真机上连不上）。
// 注意：airlift.h 里没有通用的 lockdownd/AFC 接口，真正的通道就是
// 这里用的这几个 FFI：找 PosterBoard 容器、注入描述符目录、写偏好。
// 流程照 AirCard-iOS 开源项目（MIT）的 TendiesEngine 移植。
//
// 步骤：
//   1. 设目标主机（回环 VPN 的设备 IP，如 10.7.0.1）；
//   2. 用配对文件找 PosterBoard 容器路径；
//   3. 把暂存的描述符目录注入容器里的扩展数据存储
//      （…/PRBPosterExtensionDataStore/<版本>/Extensions/<扩展>/descriptors/<新 UUID>）；
//   4. 写 PosterBoard 偏好（让系统重载描述符、重置文件保护）；
//   5. 返回描述符 UUID，安装完成（不要在这里重启设备，见第 8 步注释）。
// 标识处理照 AirCard 的规矩：如果包里有建议元数据（suggestionMetadata），
// 标识保持原样不动（乱改会让系统查不到）；否则生成新 UUID 并同步改掉
// 描述符里的数字标识，避免重复安装撞标识。
// 本文件不含广告 SDK、不含解锁逻辑、不含任何密钥值（只传配对文件路径）。

import Foundation
import AirliftFFI

/// 安装过程日志：FFI 回调写来的每一行（任意 Rust 线程调，用锁保护）。
/// 装完在安装页显示，供定位卡在哪一步。
final class InstallLog: @unchecked Sendable {
    static let shared = InstallLog()
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock {
            lines.append(line)
            if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        }
    }

    func clear() {
        lock.withLock { lines.removeAll() }
    }

    /// 最后 n 行（安装页显示用）。
    func tail(_ n: Int) -> String {
        lock.withLock { lines.suffix(n).joined(separator: "\n") }
    }
}

/// FFI 日志回调：顶层函数，可直接当 C 函数指针传（不捕获任何变量）。
func airliftLogCallback(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?) {
    if let msg {
        InstallLog.shared.append(String(cString: msg))
    }
}

/// 经配对隧道安装描述符：暂存目录 + 配对文件路径 → 实际装上的描述符 UUID。
public enum AirliftInstaller {

    public enum Error: Swift.Error {
        case missingDescriptorFolder(String)
        case ffiFailed(step: String, detail: String)
    }

    /// - Parameters:
    ///   - stagedDirectory: DescriptorInstaller.stage 解出的暂存目录。
    ///   - descriptorUUID: 包里原来的描述符 UUID。
    ///   - pairingPath: 配对文件路径（Rust 配对主机写出的文件）。
    ///   - targetHost: 回环 VPN 的设备 IP，默认 10.7.0.1。
    /// - Returns: 实际装上的描述符 UUID（有建议元数据时等于原 UUID，否则是新 UUID）。
    public static func install(
        stagedDirectory: URL,
        descriptorUUID: String,
        pairingPath: String,
        targetHost: String = "10.7.0.1",
        forceRefresh: Bool = true
    ) async throws -> String {
        InstallLog.shared.clear()
        // 0. 装前先检查（只读不写）：配对不通就直接报错，不写盘。
        // checkPairing 只设目标主机并找容器，不写任何文件。
        let container = try await checkPairing(pairingPath: pairingPath, targetHost: targetHost)
        // 1. 设目标主机（AirCard 里也是忽略返回值，只当提示）。
        targetHost.withCString { _ = al_set_target_host($0) }

        // 2. 容器已在第 0 步检查时找到，直接用，不再找第二遍。
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        // AirCard 的版本映射：iOS 16 及以下用 59，其余用 61（目标机是 27，走 61）。
        let structVersion = (majorVersion <= 16) ? 59 : 61

        // 3. 描述符目录就是暂存树里的 descriptors/<UUID>。
        let descriptorFolder = stagedDirectory
            .appendingPathComponent("descriptors")
            .appendingPathComponent(descriptorUUID)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: descriptorFolder.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw Error.missingDescriptorFolder(descriptorFolder.path)
        }

        // 4. 扩展名与目标 UUID（建议元数据在就保持原样，否则换新 UUID 并改标识）。
        let hasSuggestionMetadata = FileManager.default.fileExists(
            atPath: descriptorFolder
                .appendingPathComponent("com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist").path)
        let ext = extensionForDescriptor(descriptorFolder)
        let destUUID: String
        if hasSuggestionMetadata {
            destUUID = descriptorUUID
        } else {
            destUUID = UUID().uuidString.uppercased()
            randomizeIdentifiers(in: descriptorFolder)
        }

        // 5. 注入主扩展目录。
        let primaryParent = "\(container)/Library/Application Support/PRBPosterExtensionDataStore/\(structVersion)/Extensions/\(ext)/descriptors"
        try await injectFolder(
            folderURL: descriptorFolder, targetParentDir: primaryParent,
            destName: destUUID, pairingPath: pairingPath)

        // 6. iOS 18+ 再双写一份到现代扩展目录（AirCard 的做法，失败不算错）。
        if majorVersion >= 18 {
            let modernExt: String?
            if ext == "com.apple.WallpaperKit.CollectionsPoster" {
                modernExt = "com.apple.Posters.CollectionsPosterApp"
            } else if ext == "com.apple.MercuryPoster" {
                modernExt = "com.apple.Posters.MercuryPosterApp"
            } else {
                modernExt = nil
            }
            if let modernExt = modernExt {
                let modernParent = "\(container)/Library/Application Support/PRBPosterExtensionDataStore/\(structVersion)/Extensions/\(modernExt)/descriptors"
                try? await injectFolder(
                    folderURL: descriptorFolder, targetParentDir: modernParent,
                    destName: destUUID, pairingPath: pairingPath)
            }
        }

        // 7. 写偏好，让 PosterBoard 重载描述符、重置文件保护。
        try await writePosterBoardPreferences(containerPath: container, pairingPath: pairingPath)

        // 8. 补齐兼容目录：现代扩展目录再写一次（与第 6 步同一映射）。
        // 主目录已写好，这里只是补漏，失败不算错，不影响主目录。
        if majorVersion >= 18 {
            let supplementExt: String?
            if ext == "com.apple.WallpaperKit.CollectionsPoster" {
                supplementExt = "com.apple.Posters.CollectionsPosterApp"
            } else if ext == "com.apple.MercuryPoster" {
                supplementExt = "com.apple.Posters.MercuryPosterApp"
            } else {
                supplementExt = nil
            }
            if let supplementExt = supplementExt {
                let supplementParent = "\(container)/Library/Application Support/PRBPosterExtensionDataStore/\(structVersion)/Extensions/\(supplementExt)/descriptors"
                try? await injectFolder(
                    folderURL: descriptorFolder, targetParentDir: supplementParent,
                    destName: destUUID, pairingPath: pairingPath)
            }
        }

        // 9. 强制刷新缓存：开关开着时，再写一次偏好，让系统立刻重新索引壁纸。
        if forceRefresh {
            try await writePosterBoardPreferences(containerPath: container, pairingPath: pairingPath)
        }

        // 10. 到此为止，直接返回，绝不要在这里重启设备，更不要重启手机。
        // 教训（2026-11-01 实测）：原来这一步调 al_device_respring，
        // 它实际是向 diagnostics_relay 发 Restart，等于整机重启，
        // 会把安装在完成前打断——每次安装都白苹果重启、壁纸进不去。
        // 桌面重启（只重启桌面）是另外一步，不在这里做，也绝不能调整机重启。
        return destUUID
    }

    /// 检查配对是否真的能用：设目标主机后，用配对文件找 PosterBoard 容器。
    /// 只读不写，通就返回容器路径，不通就抛 FFI 原文（状态页“检查配对状态”用）。
    public static func checkPairing(
        pairingPath: String,
        targetHost: String = "10.7.0.1"
    ) async throws -> String {
        targetHost.withCString { _ = al_set_target_host($0) }
        return try await findPosterBoardContainer(pairingPath: pairingPath)
    }

    // MARK: - FFI 小包装（这些调用会阻塞，必须在后台线程跑）

    private static func findPosterBoardContainer(pairingPath: String) async throws -> String {
        try await runBlocking {
            var outContainer: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc = pairingPath.withCString { pairC in
                "com.apple.PosterBoard".withCString { bundleC in
                    al_find_app_container(pairC, bundleC, airliftLogCallback, nil, &outContainer, &outError)
                }
            }
            if rc == 0, let p = outContainer {
                let container = String(cString: p)
                al_string_free(p)
                return container
            }
            let detail = freeErrorString(&outError) ?? "找不到 PosterBoard 容器"
            throw Error.ffiFailed(step: "找 PosterBoard 容器", detail: detail)
        }
    }

    private static func injectFolder(
        folderURL: URL, targetParentDir: String, destName: String, pairingPath: String
    ) async throws {
        try await runBlocking {
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc = pairingPath.withCString { pairC in
                folderURL.path.withCString { folderC in
                    targetParentDir.withCString { parentC in
                        destName.withCString { destC in
                            al_exploit_inject_folder(
                                pairC, folderC, parentC, destC, airliftLogCallback, nil, &outError)
                        }
                    }
                }
            }
            if rc != 0 {
                let detail = freeErrorString(&outError) ?? "注入描述符失败"
                throw Error.ffiFailed(step: "注入描述符目录", detail: detail)
            }
        }
    }

    private static func writeDirectoryTree(
        sourceDir: URL, targetDir: String, pairingPath: String
    ) async throws {
        try await runBlocking {
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc = pairingPath.withCString { pairC in
                sourceDir.path.withCString { srcC in
                    targetDir.withCString { tgtC in
                        al_exploit_write_dir(pairC, srcC, tgtC, airliftLogCallback, nil, &outError)
                    }
                }
            }
            if rc != 0 {
                let detail = freeErrorString(&outError) ?? "写偏好失败"
                throw Error.ffiFailed(step: "写 PosterBoard 偏好", detail: detail)
            }
        }
    }

    private static func runBlocking<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try work())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func freeErrorString(_ ptr: inout UnsafeMutablePointer<CChar>?) -> String? {
        guard let p = ptr else { return nil }
        let s = String(cString: p)
        al_string_free(p)
        return s
    }

    // MARK: - 偏好与标识

    private static func writePosterBoardPreferences(
        containerPath: String, pairingPath: String
    ) async throws {
        let stageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallive-clone-prefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stageDir) }

        let prefURL = stageDir.appendingPathComponent("com.apple.PosterBoard.unprotectedUserDefaults.plist")
        let prefDict: [String: Any] = [
            "PBF_RESET_FILE_PROTECTIONS": true,
            "PBF_LOCALE_DID_CHANGE": true,
            "PersistedPosterContainerBundleIdentifiers": [
                "com.apple.Posters.CollectionsPosterApp",
                "com.apple.WallpaperKit.CollectionsPoster",
                "com.apple.MercuryPoster",
                "com.apple.Posters.MercuryPosterApp",
                "com.apple.PhotosUIPrivate.PhotosPosterProvider",
            ],
            "CompletedPosterBundleIdentifierMigrations": [
                "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
                "com.apple.Posters.WeatherPosterApp.WeatherPoster",
                "com.apple.Posters.UnityPosterApp.Unity2025Poster",
                "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
                "com.apple.Posters.UnityPosterApp.RhizomePoster",
                "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster",
            ],
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: prefDict, format: .binary, options: 0)
        try plistData.write(to: prefURL)

        try await writeDirectoryTree(
            sourceDir: stageDir, targetDir: "\(containerPath)/Library/Preferences",
            pairingPath: pairingPath)
        // 系统全局偏好也写一份（失败不算错，AirCard 里同样是尽力写）。
        try? await writeDirectoryTree(
            sourceDir: stageDir, targetDir: "/var/mobile/Library/Preferences",
            pairingPath: pairingPath)
    }

    /// 从建议元数据里找扩展名，找不到就默认 CollectionsPoster（编辑器导出的包都是这族）。
    private static func extensionForDescriptor(_ folderURL: URL) -> String {
        let metadataURL = folderURL.appendingPathComponent(
            "com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist")
        if let data = try? Data(contentsOf: metadataURL),
           let plist = try? PropertyListSerialization.propertyList(
               from: data, options: [], format: nil) as? [String: Any],
           let objects = plist["$objects"] as? [Any] {
            for obj in objects {
                if let str = obj as? String,
                   str.hasPrefix("com.apple."), str.contains("Poster") {
                    return str
                }
            }
        }
        return "com.apple.WallpaperKit.CollectionsPoster"
    }

    /// 换新 UUID 时同步改掉描述符里的数字标识（照 AirCard 的规矩，只改纯数字那几处）。
    private static func randomizeIdentifiers(in folderURL: URL) {
        let randomizedID = Int.random(in: 10000...99999)
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        while let fileURL = enumerator.nextObject() as? URL {
            let fileName = fileURL.lastPathComponent
            if fileName == "com.apple.posterkit.provider.descriptor.identifier" {
                // 只有内容是纯数字时才改（Mercury/Unity 那种字符串标识不能动）。
                if let content = try? String(contentsOf: fileURL, encoding: .utf8),
                   Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                    try? "\(randomizedID)".data(using: .utf8)?.write(to: fileURL)
                }
            } else if fileName == "com.apple.posterkit.provider.contents.userInfo" {
                if let data = try? Data(contentsOf: fileURL),
                   var plist = (try? PropertyListSerialization.propertyList(
                       from: data, options: .mutableContainers, format: nil)) as? [String: Any],
                   plist["wallpaperRepresentingIdentifier"] != nil {
                    plist["wallpaperRepresentingIdentifier"] = randomizedID
                    if let updated = try? PropertyListSerialization.data(
                        fromPropertyList: plist, format: .binary, options: 0) {
                        try? updated.write(to: fileURL)
                    }
                }
            } else if fileName.hasSuffix("Wallpaper.plist") {
                if let data = try? Data(contentsOf: fileURL),
                   var plist = (try? PropertyListSerialization.propertyList(
                       from: data, options: .mutableContainers, format: nil)) as? [String: Any] {
                    plist["identifier"] = randomizedID
                    if let updated = try? PropertyListSerialization.data(
                        fromPropertyList: plist, format: .binary, options: 0) {
                        try? updated.write(to: fileURL)
                    }
                }
            }
        }
    }
}

extension AirliftInstaller.Error: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingDescriptorFolder(let path):
            return "包里找不到描述符目录：\(path)"
        case .ffiFailed(let step, let detail):
            return "\(step)失败：\(detail)"
        }
    }
}
