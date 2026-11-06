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
    /// 安装方式三选一（自动 / 直写 / 备份还原），存 UserDefaults，默认自动。
    /// "自动"走 `PosterBoardApplyModeSettings.resolved()`：直写被藏时自动切备份。
    @Published var applyChoice = ApplyModeChoice.current {
        didSet { ApplyModeChoice.current = applyChoice }
    }
    /// 这台设备的身份（UDID、iOS 版本、build）。读不到时为 nil，
    /// 界面显示"设备版本读不到"，安装按 fail closed 走备份路。
    @Published var deviceInfo: BackupFFI.DeviceInfo?

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

    /// 设当前包并做检查（WALLIVE1 加密包先解密再校验结构）。
    /// displayName：目录下载时传条目标题；直接导入文件时不传。
    func setPackage(_ data: Data, displayName: String? = nil) {
        packageData = data
        packageDisplayName = displayName
        packageImportedAt = Date()
        do {
            packageInfo = try TendiesPackage.inspect(data, zip: zip)
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
    func install(host: String, forceRefresh: Bool = true) async -> String? {
        guard let data = packageData, hasPairingFile else { return nil }
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
    /// 先读设备身份、按三态选择定模式：直写走下面原有流程一字不动；
    /// 备份走 `BackupInstallFlow`（取表 → 改表 → 编包 → 还原），装完要重启手机。
    func installWithReport(host: String, forceRefresh: Bool = true, onProgress: ((String, Double) -> Void)? = nil) async throws -> InstallReport? {
        guard let data = packageData, hasPairingFile else { return nil }
        // 安装开始先读一次设备身份（只读不写）。读不到就用缓存的，
        // 连缓存都没有就按空版本算——`resolved()` 会 fail closed 走备份路，
        // 不猜版本走直写。
        onProgress?("正在读设备版本…", 0.02)
        await refreshDeviceInfo()
        let version = deviceInfo?.productVersion ?? ""
        let build = deviceInfo?.buildVersion ?? ""
        let mode = applyChoice.resolvedMode(deviceVersion: version, buildVersion: build)
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

    /// 备份路安装：取表 → 改表 → 编包 → 还原。结果同样记进 installReports，
    /// 报告里 `mode` 是 `.backup`，`backupSummary` 写清"要重启手机"。
    /// 直写路的读回核对 / 登记 / 进程刷新这条路没有：还原的 `completed`
    /// 就是验真，偏好不写、进程不刷，壁纸进图库靠重启手机。
    private func installWithReportBackup(data: Data,
                                         onProgress: ((String, Double) -> Void)? = nil) async throws -> InstallReport? {
        guard let info = deviceInfo else {
            statusMessage = "备份安装没法开始：读不到设备身份（UDID、iOS 版本），"
                + "请确认回环 VPN 已连接、配对记录已导入，再试一次。"
            return nil
        }
        do {
            InstallLog.shared.clear()
            let outcome = try await BackupInstallFlow.install(
                packageData: data, zip: zip,
                pairingPath: pairingFileURL.path, deviceInfo: info,
                log: { InstallLog.shared.append($0) },
                onProgress: onProgress)
            let configurationsDir = "Library/Application Support/PRBPosterExtensionDataStore/"
                + "Extensions/\(outcome.extensionID)/configurations"
            let report = InstallReport(
                descriptorUUID: outcome.descriptorUUID,
                injectResults: [InjectResult(targetParentDir: configurationsDir,
                                             ok: true, error: nil)],
                preferencesWritten: false,
                verifyResults: [],
                registration: nil,
                refresh: nil,
                mode: .backup,
                backupSummary: "备份还原已完成（\(outcome.payloadCount) 个载荷，"
                    + "商店：\(outcome.storeSummary)）。重启手机后去锁屏图库查看，"
                    + "出现后再点设为墙纸组合。")
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
