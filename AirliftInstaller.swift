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
//   5. 返回安装报告（描述符 UUID + 逐目录结果 + 偏好结果 + 读回核对 +
//      登记 + 进程刷新），不再只返回 UUID。注意：写盘结果只代表写盘函数
//      返回成功，不代表图库已列出；目标落地是否真的在设备上，看报告里的
//      读回核对结果；进程刷新只代表 PosterBoard 进程已重启重读，图库里
//      有没有仍要去锁屏图库看。对账（阶段 B）等逆向确认 x0 后再接，
//      确认前不硬编；不重启设备、不调任何重启接口、不做桌面重启冒充。
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

/// 单个目标目录的注入结果（诊断用，不许合并成一个布尔值）。
/// 必须是公开类型：公开的 installWithReport 以它作返回类型的一部分，
/// 内部类型会让编译报错（公开方法不能用内部类型）。
public struct InjectResult {
    public let targetParentDir: String
    public let ok: Bool
    public let error: String?
}

/// 单个目标目录的读回核对结果（诊断用，不许合并成一个布尔值）。
/// channel 为 "house_arrest" 时表示读回通道已通，逐项结果可信；
/// 为 "unavailable" 时表示通道没通（系统不放行容器直读），逐项结果
/// 不可信，页面必须写“读回通道不可用”，不许写成“描述符缺失”。
public struct VerifyResult {
    public let targetParentDir: String
    public let channel: String
    public let descriptorDirExists: Bool
    public let descriptorDirEntries: Int?
    public let wallpaperPlistExists: Bool
    public let wallpaperPlistSize: Int?
    public let wallpaperName: String?
    public let identifierExists: Bool
    public let identifierSize: Int?
    public let identifierContent: String?
    public let error: String?

    /// 三项全在（且通道通）才算核对到。
    public var allPresent: Bool {
        channel == "house_arrest" && descriptorDirExists && wallpaperPlistExists && identifierExists
    }
    /// 通道没通，逐项结果不可信。
    public var channelUnavailable: Bool { channel != "house_arrest" }

    /// 从 Rust 返回的 JSON 组装；JSON 为空（通道失败）时记 unavailable。
    init(targetParentDir: String, jsonString: String?, error: String?) {
        self.targetParentDir = targetParentDir
        self.error = error
        if let jsonString, let data = jsonString.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            channel = obj["channel"] as? String ?? "unavailable"
            descriptorDirExists = obj["descriptor_dir_exists"] as? Bool ?? false
            descriptorDirEntries = obj["descriptor_dir_entries"] as? Int
            wallpaperPlistExists = obj["wallpaper_plist_exists"] as? Bool ?? false
            wallpaperPlistSize = obj["wallpaper_plist_size"] as? Int
            wallpaperName = obj["wallpaper_name"] as? String
            identifierExists = obj["identifier_exists"] as? Bool ?? false
            identifierSize = obj["identifier_size"] as? Int
            identifierContent = obj["identifier_content"] as? String
        } else {
            channel = "unavailable"
            descriptorDirExists = false
            descriptorDirEntries = nil
            wallpaperPlistExists = false
            wallpaperPlistSize = nil
            wallpaperName = nil
            identifierExists = false
            identifierSize = nil
            identifierContent = nil
        }
    }
}

/// 单次进程刷新的结果（阶段 D，诊断用）。
/// confirmed 为真表示：发信号后看到了新 pid，且重连验证也看到了
/// PosterBoard 进程。wallpaperVisible 永远是 "unverified"——图库里有没有，
/// 只能去锁屏图库看，设备侧验不出来（原版自己的日志也是这么记的）。
/// 刷新失败只记进报告、不抛错：写盘与登记已成功，刷新是事后触发。
public struct RefreshResult {
    public let confirmed: Bool
    public let wallpaperVisible: String
    public let oldPid: Int?
    public let newPid: Int?
    public let verifiedPid: Int?
    public let error: String?

    /// 从 Rust 返回的 JSON 组装（宽松解析：只读 refresh_confirmed 与
    /// wallpaper_visible 这两个键，其余键没有也不影响结论）。
    init(jsonString: String?, error: String?) {
        self.error = error
        if let jsonString, let data = jsonString.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            confirmed = obj["refresh_confirmed"] as? Bool ?? false
            wallpaperVisible = obj["wallpaper_visible"] as? String ?? "unverified"
            oldPid = obj["old_pid"] as? Int
            newPid = obj["new_pid"] as? Int
            verifiedPid = obj["verified_pid"] as? Int
        } else {
            confirmed = false
            wallpaperVisible = "unverified"
            oldPid = nil
            newPid = nil
            verifiedPid = nil
        }
    }
}

/// 安装报告：描述符 UUID + 逐目录注入结果 + 偏好写入结果 + 读回核对 + 登记 + 进程刷新。
/// 注意：写盘结果只代表写盘函数返回成功，不代表图库已列出；目标落地是否
/// 真的在设备上，看 verifyResults（读回核对）；登记只记 App 自己的账本；
/// 进程刷新只代表 PosterBoard 进程已重启重读，图库里有没有仍要去锁屏图库看。
public struct InstallReport {
    public let descriptorUUID: String
    public let injectResults: [InjectResult]
    public let preferencesWritten: Bool
    public let verifyResults: [VerifyResult]
    public let registration: RegistrationResult?
    public let refresh: RefreshResult?
}

/// 经配对隧道安装描述符：暂存目录 + 配对文件路径 → 实际装上的描述符 UUID。
public enum AirliftInstaller {

    public enum Error: Swift.Error {
        case missingDescriptorFolder(String)
        case ffiFailed(step: String, detail: String)
    }

    /// 无条件双向扩展名清单（Collections / Mercury 两家族）。
    /// 不论描述符原来的扩展名是旧版还是新版，同一 UUID、同一内容两边都写。
    /// Kaleidoscope / Unity 类不在清单里，先不动，等核对图库读哪边再定。
    static func dualExtensions(for ext: String) -> [String] {
        switch ext {
        case "com.apple.WallpaperKit.CollectionsPoster":
            return ["com.apple.WallpaperKit.CollectionsPoster",
                    "com.apple.Posters.CollectionsPosterApp"]
        case "com.apple.Posters.CollectionsPosterApp":
            return ["com.apple.Posters.CollectionsPosterApp",
                    "com.apple.WallpaperKit.CollectionsPoster"]
        case "com.apple.MercuryPoster":
            return ["com.apple.MercuryPoster",
                    "com.apple.Posters.MercuryPosterApp"]
        case "com.apple.Posters.MercuryPosterApp":
            return ["com.apple.Posters.MercuryPosterApp",
                    "com.apple.MercuryPoster"]
        default:
            return [ext]
        }
    }

    /// - Parameters:
    ///   - stagedDirectory: DescriptorInstaller.stage 解出的暂存目录。
    ///   - descriptorUUID: 包里原来的描述符 UUID。
    ///   - pairingPath: 配对文件路径（Rust 配对主机写出的文件）。
    ///   - targetHost: 回环 VPN 的设备 IP，默认 10.7.0.1。
    /// - Returns: 实际装上的描述符 UUID（有建议元数据时等于原 UUID，否则是新 UUID）。
    /// 旧入口（兼容保留）：只返回描述符 UUID，逐目录结果丢弃。
    /// 诊断页必须走 installWithReport，不要走这个入口。
    public static func install(
        stagedDirectory: URL,
        descriptorUUID: String,
        pairingPath: String,
        targetHost: String = "10.7.0.1",
        forceRefresh: Bool = true
    ) async throws -> String {
        let report = try await installWithReport(
            stagedDirectory: stagedDirectory, descriptorUUID: descriptorUUID,
            pairingPath: pairingPath, targetHost: targetHost, forceRefresh: forceRefresh)
        return report.descriptorUUID
    }

    /// 诊断版入口：返回报告，不只返回 UUID。
    /// 流程与旧入口相同（配对检查、结构版本 59/61 映射、偏好键与两处路径均不动，
    /// 标识策略也不动：有建议元数据的包保持原 UUID、不改标识），改动：
    /// 双写改成无条件双向，现代/补充目录失败不再用 try? 吞掉，而是逐目标
    /// 收集进报告；主目录（清单第一项）注入失败仍抛错。
    /// 之后依次做：读回核对（阶段 A，每个目标各调一次 al_verify_descriptor，
    /// 失败只记进报告、不抛错）→ 登记（阶段 C，写 App 自己的 ManagedPosterBoard
    /// 账本）→ 进程刷新（阶段 D，给 PosterBoard 发信号 9、等重启、重连验证，
    /// 失败只记进报告、不抛错）。对账（阶段 B）还没接：reconcile 的 x0 身份
    /// 未证实，等逆向定下来再接，确认前不硬编。
    /// 不重启设备、不调任何重启接口、不做桌面重启冒充。
    public static func installWithReport(
        stagedDirectory: URL,
        descriptorUUID: String,
        pairingPath: String,
        targetHost: String = "10.7.0.1",
        forceRefresh: Bool = true,
        onProgress: ((String, Double) -> Void)? = nil
    ) async throws -> InstallReport {
        InstallLog.shared.clear()
        // 0. 装前先检查（只读不写）：配对不通就直接报错，不写盘。
        // checkPairing 只设目标主机并找容器，不写任何文件。
        let container = try await checkPairing(pairingPath: pairingPath, targetHost: targetHost)
        onProgress?("正在检查配对…", 0.10)
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

        // 5. 双写：清单第一项就是原来的主目录，失败仍抛错（保持原行为）；
        // 其余目标逐个收集结果，失败进报告、不抛错、不吞掉。
        // 原第 6 步、第 8 步那种“现代目录再写一次”的重复写法，已被本双写取代，
        // 每个目标只写一次，不再重复写同一目录。
        let targets = dualExtensions(for: ext).map {
            "\(container)/Library/Application Support/PRBPosterExtensionDataStore/\(structVersion)/Extensions/\($0)/descriptors"
        }
        var injectResults: [InjectResult] = []
        onProgress?("正在写入描述符…", 0.15)
        for (index, targetParent) in targets.enumerated() {
            do {
                try await injectFolder(
                    folderURL: descriptorFolder, targetParentDir: targetParent,
                    destName: destUUID, pairingPath: pairingPath)
                injectResults.append(InjectResult(targetParentDir: targetParent, ok: true, error: nil))
            } catch {
                if index == 0 {
                    throw error
                }
                injectResults.append(InjectResult(targetParentDir: targetParent, ok: false, error: "\(error)"))
            }
            onProgress?("正在写入描述符…", 0.15 + 0.175 * Double(index + 1))
        }

        // 6. 写偏好，让 PosterBoard 重载描述符、重置文件保护（键与路径均不动）。
        // 失败抛错，与原行为一致；能走到返回处，说明偏好已写入。
        try await writePosterBoardPreferences(containerPath: container, pairingPath: pairingPath)

        // 7. 强制刷新缓存：开关开着时，再写一次偏好，让系统立刻重新索引壁纸。
        if forceRefresh {
            try await writePosterBoardPreferences(containerPath: container, pairingPath: pairingPath)
        }
        onProgress?("正在写入偏好…", 0.60)

        // 8. 读回核对（阶段 A）：对每个注入目标各调一次 al_verify_descriptor，
        //    结果进报告。核对失败不抛错、不影响“已写入设备”的结论，只如实记录；
        //    通道不可用时结果里 channel 记 unavailable，页面不得写成“描述符缺失”。
        var verifyResults: [VerifyResult] = []
        onProgress?("正在读回核对…", 0.65)
        for (index, targetParent) in targets.enumerated() {
            verifyResults.append(await verifyDescriptor(
                targetParentDir: targetParent, destName: destUUID, pairingPath: pairingPath))
            onProgress?("正在读回核对…", 0.65 + 0.05 * Double(index + 1))
        }

        // 9. 登记（阶段 C）：把这次安装记进 App 自己的 ManagedPosterBoard 账本。
        //    只写本 App 的 UserDefaults，不碰系统文件；失败只记进报告，不抛错。
        //    显示名从暂存的 contents 目录里找 <名>.wallpaper，找不到就用描述符 UUID。
        //    paths 记两个目标目录的完整落地路径（目标父目录 + 描述符 UUID）。
        let wallpaperName = discoverWallpaperName(in: descriptorFolder) ?? destUUID
        let installedPaths = targets.map { "\($0)/\(destUUID)" }
        let registration = ManagedPosterBoard.recordInstallation(
            descriptorUUID: destUUID,
            installedPaths: installedPaths,
            packageKey: wallpaperName,
            wallpaperName: wallpaperName)
        onProgress?("正在登记…", 0.80)

        // 10. 进程刷新（阶段 D）：给 PosterBoard 进程发信号 9（SIGKILL），
        //     等它重启、重读扩展目录，再重连验证。刷新失败只记进报告、不抛错；
        //     图库里有没有壁纸，仍要去锁屏图库看（wallpaper_visible 永远是
        //     unverified）。只杀 PosterBoard 一个进程，不重启桌面、不重启设备。
        onProgress?("正在刷新 PosterBoard…", 0.85)
        let refresh = await posterboardRefresh(pairingPath: pairingPath)

        // 11. 到此为止，直接返回报告，绝不要在这里重启设备，更不要重启手机。
        // 教训（2026-11-01 实测）：原来这一步调整机重启接口，
        // 它实际是向 diagnostics_relay 发 Restart，等于整机重启，
        // 会把安装在完成前打断——每次安装都白苹果重启、壁纸进不去。
        // 桌面重启（只重启桌面）是另外一步，不在这里做，也绝不能调整机重启。
        onProgress?("安装完成", 1.0)
        return InstallReport(
            descriptorUUID: destUUID,
            injectResults: injectResults,
            preferencesWritten: true,
            verifyResults: verifyResults,
            registration: registration,
            refresh: refresh)
    }

    /// 清除已安装（重索引）：先确认配对通，再重写 PosterBoard 偏好两次，
    /// 让系统立刻重新索引壁纸图库。
    /// 使用方法（必须配合系统删除）：先在锁屏长按进图库、上滑删掉那张锁屏，
    /// 再点这个按钮重索引，图库里那条才会刷新掉。
    /// 注意：这个按钮不直接删 PosterBoard 描述符文件夹——当前特权通道里
    /// 没有经过验证的删除路径，乱删可能动到系统自带壁纸，所以不伪装成
    /// “已删描述符”。如果删完锁屏、重索引后图库里还出现，再把那张包发来查。
    public static func clearInstalledRecords(
        pairingPath: String,
        targetHost: String = "10.7.0.1"
    ) async throws -> String {
        let container = try await checkPairing(pairingPath: pairingPath, targetHost: targetHost)
        try await writePosterBoardPreferences(containerPath: container, pairingPath: pairingPath)
        try await writePosterBoardPreferences(containerPath: container, pairingPath: pairingPath)
        return container
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

    /// 读回核对一个目标目录（阶段 A）：调 al_verify_descriptor，绝不抛错。
    /// 通道失败（JSON 为空）时结果里 channel 记 unavailable；
    /// 通道通但有项缺失时，逐项结果进报告，error 记缺哪几项。
    private static func verifyDescriptor(
        targetParentDir: String, destName: String, pairingPath: String
    ) async -> VerifyResult {
        // 闭包本身不抛错；try? 只是为了满足 runBlocking 的 throws 签名。
        let result = try? await runBlocking {
            var outJSON: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            _ = pairingPath.withCString { pairC in
                targetParentDir.withCString { parentC in
                    destName.withCString { destC in
                        al_verify_descriptor(
                            pairC, parentC, destC, airliftLogCallback, nil, &outJSON, &outError)
                    }
                }
            }
            let jsonString: String? = {
                guard let p = outJSON else { return nil }
                let s = String(cString: p)
                al_string_free(p)
                return s
            }()
            let errorString = freeErrorString(&outError)
            return VerifyResult(
                targetParentDir: targetParentDir, jsonString: jsonString, error: errorString)
        }
        return result ?? VerifyResult(
            targetParentDir: targetParentDir, jsonString: nil, error: "读回核对未执行")
    }

    /// 进程刷新一次（阶段 D）：调 al_posterboard_refresh，绝不抛错。
    /// 刷新跑完（JSON 到了）就按 JSON 组装结果；通道失败（JSON 为空）时
    /// confirmed 为假，error 记原因。
    private static func posterboardRefresh(pairingPath: String) async -> RefreshResult {
        // 闭包本身不抛错；try? 只是为了满足 runBlocking 的 throws 签名。
        let result = try? await runBlocking {
            var outJSON: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            _ = pairingPath.withCString { pairC in
                al_posterboard_refresh(pairC, airliftLogCallback, nil, &outJSON, &outError)
            }
            let jsonString: String? = {
                guard let p = outJSON else { return nil }
                let s = String(cString: p)
                al_string_free(p)
                return s
            }()
            let errorString = freeErrorString(&outError)
            return RefreshResult(jsonString: jsonString, error: errorString)
        }
        return result ?? RefreshResult(jsonString: nil, error: "进程刷新未执行")
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

    /// 从暂存的 contents 目录里找 <名>.wallpaper，返回去掉后缀的显示名。
    /// 登记的 WallpaperNames 用这个名字；找不到就返回 nil（调用方用描述符 UUID）。
    private static func discoverWallpaperName(in folderURL: URL) -> String? {
        let contentsURL = folderURL
            .appendingPathComponent("versions").appendingPathComponent("1")
            .appendingPathComponent("contents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: contentsURL, includingPropertiesForKeys: nil) else { return nil }
        for entry in entries where entry.lastPathComponent.hasSuffix(".wallpaper") {
            return String(entry.lastPathComponent.dropLast(".wallpaper".count))
        }
        return nil
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
