// AppState.swift
// 共享状态：当前包、配对记录状态、安装记录、提示信息。
// 配对记录文件由用户在 App 内导入，存放在 App 沙盒 Documents 内
// （wallive-pairing.plist），运行时加载；代码里不含任何密钥材料，
// 状态显示只用 PairingRecord.redactedDescription（字段长度，不含值）。

import Foundation
import Network

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab = 0
    @Published var packageData: Data?
    @Published var packageInfo: TendiesPackageInfo?
    @Published var packageImportedAt: Date?
    @Published var packageError: String?
    /// 目录下载时带来的中文名（如“蜘蛛侠 2”）；直接导入文件时为空，详情页改显示清理过的包名。
    @Published var packageDisplayName: String?
    @Published var pairingLoaded = false
    @Published var pairingDescription = "未导入"
    @Published var installHistory: [String] = []
    @Published var installReports: [InstallReport] = []
    @Published var statusMessage = ""
    /// 安装方式四选一（自动 / 直写 / 备份还原 / 测试版），存 UserDefaults，默认自动。
    /// "自动"走 `PosterBoardApplyModeSettings.resolved()`：直写被藏时自动切备份。
    /// "测试版"不经过那套解析，直接走只写描述符的新路子，装完要重启手机。
    @Published var applyChoice = ApplyModeChoice.current {
        didSet { ApplyModeChoice.current = applyChoice }
    }
    /// 这台设备的身份（UDID、iOS 版本、build）。读不到时为 nil，
    /// 界面显示"设备版本读不到"，安装按 fail closed 走备份路。
    @Published var deviceInfo: BackupFFI.DeviceInfo?

    init() {
        // 启动自愈：上次逃逸中途崩溃会把 App Group 的 Library/Caches 留成
        // 指向壁纸库的软链，不收拾会污染其他走 App Group 的读写。
        WorseQueryEscape.recoverStaleSymlink()
    }

    /// 读一次设备身份（只读不写）。隧道/配对不通就置空，不抛错——
    /// 调用方按"读不到"处理，不拿旧值冒充。
    func refreshDeviceInfo() async {
        guard hasPairingFile else { deviceInfo = nil; return }
        do {
            deviceInfo = try await BackupFFI.deviceInfo(
                pairingPath: pairingFileURL.path,
                log: { InstallLog.shared.append($0) })
        } catch {
            deviceInfo = nil
        }
    }

    private let zip = ZipFoundationAdapter()

    /// App 沙盒内的配对记录文件（用户导入后存放处）。
    var pairingFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallive-pairing.plist")
    }

    var hasPairingFile: Bool {
        FileManager.default.fileExists(atPath: pairingFileURL.path)
    }

    /// 设为当前包并做检查（WALLIVE1 加密包先解密再校验结构）。
    /// displayName：目录下载时传条目标题；直接导入文件时不传。
    /// V8：不是 WALLIVE1 加密的包，先转成加密版再存——这样装出去的包
    /// 只有咱们安装器能解开用，3105、CAPlayground、Wallive 打不开。
    /// 加密失败（极少）不拦安装，原样用明文包继续。
    func setPackage(_ data: Data, displayName: String? = nil) {
        var stored = data
        if !Wallive1Crypto.isWallive1(data) {
            do {
                stored = try Wallive1Crypto.encrypt(data)
                InstallLog.shared.append("restore: 导入的包不是加密版，已转成 WALLIVE1 加密版（\(data.count) 字节 → \(stored.count) 字节）。")
            } catch {
                InstallLog.shared.append("restore: 导入的包转加密失败（\(error.localizedDescription)），原样用明文包继续。")
            }
        }
        packageData = stored
        packageDisplayName = displayName
        packageImportedAt = Date()
        do {
            packageInfo = try TendiesPackage.inspect(stored, zip: zip)
            packageError = nil
        } catch {
            packageInfo = nil
            packageError = "包检查失败：\(error.localizedDescription)"
        }
    }

    /// 导入配对记录文件：拷进 App 沙盒 Documents，刷新状态。
    func importPairingFile(from url: URL) {
        do {
            if FileManager.default.fileExists(atPath: pairingFileURL.path) {
                try FileManager.default.removeItem(at: pairingFileURL)
            }
            try FileManager.default.copyItem(at: url, to: pairingFileURL)
            refreshPairingStatus()
        } catch {
            statusMessage = "配对记录导入失败：\(error.localizedDescription)"
        }
    }

    func removePairingFile() {
        try? FileManager.default.removeItem(at: pairingFileURL)
        pairingLoaded = false
        pairingDescription = "未导入"
    }

    /// 刷新配对状态：只读字段存在性与长度，不显示任何值。
    func refreshPairingStatus() {
        guard hasPairingFile else {
            pairingLoaded = false
            pairingDescription = "未导入"
            return
        }
        do {
            let record = try PairingRecord.load(from: pairingFileURL)
            pairingLoaded = true
            pairingDescription = record.redactedDescription
        } catch {
            pairingLoaded = false
            pairingDescription = "文件无效：\(error.localizedDescription)"
        }
    }

    /// 安装当前包：本地暂存 → 经配对隧道写盘。返回实际装上的描述符 UUID。
    /// 没配对也能装：没有配对记录时改走备份还原那条路（直读取表 + 逃逸
    /// 直写，全程不碰配对隧道）；直写这条路没有配对走不了，不在这硬试。
    func install(host: String, forceRefresh: Bool = true) async -> String? {
        guard let data = packageData else { return nil }
        if !hasPairingFile {
            do {
                InstallLog.shared.append("install: 没配对记录，改走备份还原路（不用配对）。")
                let outcome = try await BackupInstallFlow.install(
                    packageData: data, pairingPath: "",
                    log: { InstallLog.shared.append($0) })
                return outcome.descriptorUUID
            } catch {
                statusMessage = "安装失败：\(error.localizedDescription)"
                return nil
            }
        }
        do {
            let uuid = try await InstallFlow.install(
                packageData: data, zip: zip,
                pairingPath: pairingFileURL.path, targetHost: host, forceRefresh: forceRefresh)
            installHistory.append(uuid)
            return uuid
        } catch {
            statusMessage = "安装失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 诊断版安装：本地暂存 → 经配对隧道写盘，返回完整报告。
    /// 与旧 install() 的区别：逐目录结果记进 installReports，诊断页可显示；
    /// 暂存步骤与旧入口相同（DescriptorInstaller.stage），不改写盘逻辑、
    /// 配对、偏好键与路径、结构版本映射、标识策略。
    /// 先读设备身份、按四态选择定模式：直写走下面原有流程一字不动；
    /// 备份走 `BackupInstallFlow`（改表还原：拿表 → 插行 → 写文件 → 写回表
    /// → 写偏好 → 刷新），不用整机备份；刷新确认了不用重启手机。
    /// 测试版走 `BackupInstallFlow.installTest`（只写描述符、不写表），
    /// 装完要重启手机（报告里 `mode` 是 `.test`）。
    func installWithReport(host: String, forceRefresh: Bool = true, onProgress: ((String, Double) -> Void)? = nil) async throws -> InstallReport? {
        guard let data = packageData else { return nil }
        // 安装开始先读一次设备身份（只读不写）。读不到就用缓存的，
        // 连缓存都没有就按空版本算——`resolved()` 会 fail closed 走备份路，
        // 不猜版本走直写。测试版不看设备版本，点了就是测试版。
        onProgress?("正在读设备版本…", 0.02)
        await refreshDeviceInfo()
        let version = deviceInfo?.productVersion ?? ""
        let build = deviceInfo?.buildVersion ?? ""
        let mode = applyChoice.resolvedMode(deviceVersion: version, buildVersion: build)
        // 没配对也能装：直写和测试版两条路都要配对隧道，只有备份还原
        //（直读取表 + 逃逸直写）不碰配对。没配对时固定走备份还原。
        if !hasPairingFile && mode != .backup {
            InstallLog.shared.append("install: 没配对记录，这次固定走备份还原路（不用配对）。")
            return try await installWithReportBackup(data: data, onProgress: onProgress)
        }
        if mode == .test {
            return try await installWithReportTest(data: data, onProgress: onProgress)
        }
        if mode == .backup {
            return try await installWithReportBackup(data: data, onProgress: onProgress)
        }
        do {
            onProgress?("正在准备安装包…", 0.05)
            let installer = DescriptorInstaller(zip: zip)
            let (stage, descriptorUUID) = try installer.stage(data)
            let report = try await AirliftInstaller.installWithReport(
                stagedDirectory: stage, descriptorUUID: descriptorUUID,
                pairingPath: pairingFileURL.path, targetHost: host, forceRefresh: forceRefresh,
                onProgress: onProgress)
            installHistory.append(report.descriptorUUID)
            installReports.append(report)
            return report
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            statusMessage = "安装失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 测试版安装：走只写描述符（不读表、不插行、不写回），写完偏好等
    /// PosterBoard 重扫，装完要重启手机。结果同样记进 installReports，
    /// 报告里 `mode` 是 `.test`。失败原样报，不悄悄切回别的模式。
    private func installWithReportTest(data: Data,
                                       onProgress: ((String, Double) -> Void)? = nil) async throws -> InstallReport? {
        do {
            InstallLog.shared.clear()
            let outcome = try await BackupInstallFlow.installTest(
                packageData: data,
                pairingPath: pairingFileURL.path,
                log: { InstallLog.shared.append($0) },
                onProgress: onProgress)
            let configurationsDir = "Library/Application Support/PRBPosterExtensionDataStore/"
                + "Extensions/\(outcome.extensionID)/configurations"
            let report = InstallReport(
                descriptorUUID: outcome.descriptorUUID,
                injectResults: [InjectResult(targetParentDir: configurationsDir,
                                             ok: true, error: nil)] + outcome.injectResults,
                preferencesWritten: outcome.preferencesWritten,
                verifyResults: [],
                registration: nil,
                refresh: nil,
                mode: .test,
                backupSummary: "测试版已完成（\(outcome.payloadCount) 个载荷，"
                    + "只写描述符、没碰数据库表）。" + (outcome.needsReboot
                        ? "重启手机后去锁屏图库查看，出现后再点设为墙纸组合。"
                        : "去锁屏图库查看，出现后再点设为墙纸组合。"))
            installHistory.append(report.descriptorUUID)
            installReports.append(report)
            return report
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            statusMessage = "测试版安装失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 备份路安装：走改表还原（拿表 → 插行 → 写文件 → 写回表 → 写偏好 → 刷新），
    /// 不用整机备份。结果同样记进 installReports，报告里 `mode` 是 `.backup`。
    /// 刷新确认了不用重启手机，没确认才要重启（看 `backupSummary`）。
    /// 不再要设备身份：新流程不用 UDID 和版本号（容器走配对找，门控在
    /// installWithReport 那步按设备版本解析时已经做过了）；配对记录
    /// 和包还是要的，没有就直接返回。
    private func installWithReportBackup(data: Data,
                                         onProgress: ((String, Double) -> Void)? = nil) async throws -> InstallReport? {
        do {
            InstallLog.shared.clear()
            let outcome = try await BackupInstallFlow.install(
                packageData: data,
                // 没配对时传空串：让还原流程明确知道没配对，走直写，
                // 绝不拿着一个不存在的配对文件路径去碰配对隧道。
                pairingPath: hasPairingFile ? pairingFileURL.path : "",
                log: { InstallLog.shared.append($0) },
                onProgress: onProgress)
            let configurationsDir = "Library/Application Support/PRBPosterExtensionDataStore/"
                + "Extensions/\(outcome.extensionID)/configurations"
            let report = InstallReport(
                descriptorUUID: outcome.descriptorUUID,
                injectResults: [InjectResult(targetParentDir: configurationsDir,
                                             ok: true, error: nil)] + outcome.injectResults,
                preferencesWritten: outcome.preferencesWritten,
                verifyResults: [],
                registration: nil,
                // 刷新结论原样带给界面：确认了就不补桌面刷新，没确认
                //（含没配对）就由界面补一次本地网页法只重启桌面。
                refresh: RefreshResult(confirmed: outcome.refreshConfirmed),
                mode: .backup,
                backupSummary: "备份还原已完成（\(outcome.payloadCount) 个载荷，"
                    + "商店：\(outcome.storeSummary)）。" + (outcome.needsReboot
                        ? "重启手机后去锁屏图库查看，出现后再点设为墙纸组合。"
                        : "PosterBoard 已刷新，去锁屏图库查看，出现后再点设为墙纸组合。"))
            installHistory.append(report.descriptorUUID)
            installReports.append(report)
            return report
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            statusMessage = "备份安装失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 清除已安装（重索引）：配对通就重写 PosterBoard 偏好，让系统图库刷新。
    /// 不删描述符文件夹（见 AirliftInstaller.clearInstalledRecords 注释）。
    func clearInstalledRecords(host: String) async -> Bool {
        guard hasPairingFile else {
            statusMessage = "还没导入配对记录，清除前先在状态页导入。"
            return false
        }
        do {
            _ = try await AirliftInstaller.clearInstalledRecords(
                pairingPath: pairingFileURL.path, targetHost: host)
            return true
        } catch {
            statusMessage = "清除失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 检查回环 VPN 连通：TCP 连 host:port，3 秒超时（串行队列守 continuation）。
    func checkVPN(host: String, port: UInt16) async -> Bool {
        guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }
        let queue = DispatchQueue(label: "wallive-clone-vpn-check")
        return await withCheckedContinuation { cont in
            var done = false
            let conn = NWConnection(
                host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !done { done = true; cont.resume(returning: true); conn.cancel() }
                case .failed, .cancelled:
                    if !done { done = true; cont.resume(returning: false) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) {
                if !done { done = true; cont.resume(returning: false); conn.cancel() }
            }
        }
    }
}
