// AppState.swift
// 共享状态：当前包、配对记录状态、安装记录、提示信息。
// 配对记录文件由用户在 App 内导入，存放在 App 沙盒 Documents 内
// （wallive-pairing.plist），运行时加载；代码里不含任何密钥材料，
// 状态显示只用 PairingRecord.redactedDescription（字段长度，不含值）。

import Foundation
import Network
import UIKit

/// 导入库里的一张包：包文件存在沙盒 Documents/imported-packages/ 里，App 重启还在；
/// 元数据（名字、大小、时间、封面文件名）记在 UserDefaults，启动时读回来。
struct ImportedPackage: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let fileName: String
    let thumbFileName: String?
    let size: Int
    let importedAt: Date
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab = 0
    /// 深景页“设为当前包并去安装”用：置 true 后导入页自动打开详情页（跳安装），导入页消费后自己置回 false。
    @Published var showImportDetail = false
    @Published var packageData: Data?
    @Published var packageInfo: TendiesPackageInfo?
    @Published var packageImportedAt: Date?
    @Published var packageError: String?
    /// 目录下载时带来的中文名（如“蜘蛛侠 2”）；直接导入文件时为空，详情页改显示清理过的包名。
    @Published var packageDisplayName: String?
    /// 导入库：所有导过的壁纸包（新的导进来不顶掉旧的），存在沙盒里，重启还在。
    @Published var importedPackages: [ImportedPackage] = []
    private let importedDefaultsKey = "wallive-clone-imported-packages"
    private let importedDirName = "imported-packages"
    @Published var pairingLoaded = false
    @Published var pairingDescription = "未导入"
    @Published var installHistory: [String] = []
    @Published var installReports: [InstallReport] = []
    @Published var statusMessage = ""
    /// 旧格式壁纸包自动转换：打开时，旧格式（WWDC22 布局）包在 iOS 27 上装之前会转成新格式；
    /// 每个包第一次装时会问转还是按原样，答案会记住。关掉后一律按原样装、不转换。
    /// iOS 26 能直接读旧包，不用转、也不会弹询问；iOS 27 起全系列都需要转。
    @Published var autoConvertOldFormat = true {
        didSet { UserDefaults.standard.set(autoConvertOldFormat, forKey: "wallive-clone-auto-convert-old-format") }
    }
    /// 每个包记住的转换选择：描述符 UUID → true 转、false 按原样。记在 UserDefaults。
    private let convertChoiceKey = "wallive-clone-convert-choices"
    /// 这台设备的身份（UDID、iOS 版本、build）。读不到时为 nil，
    /// 界面显示"设备版本读不到"，安装按 fail closed 走备份路。
    @Published var deviceInfo: BackupFFI.DeviceInfo?

    init() {
        // 启动自愈：上次逃逸中途崩溃会把 App Group 的 Library/Caches 留成
        // 指向壁纸库的软链，不收拾会污染其他走 App Group 的读写。
        WorseQueryEscape.recoverStaleSymlink()
        autoConvertOldFormat = UserDefaults.standard.object(forKey: "wallive-clone-auto-convert-old-format") as? Bool ?? true
        loadImportedPackages()
    }

    /// 记住某个包的转换选择：true 转、false 按原样。
    func rememberConvertChoice(descriptorUUID: String, convert: Bool) {
        var choices = UserDefaults.standard.dictionary(forKey: convertChoiceKey) as? [String: Bool] ?? [:]
        choices[descriptorUUID] = convert
        UserDefaults.standard.set(choices, forKey: convertChoiceKey)
    }

    /// 取某个包记住的转换选择：nil 表示还没问过。
    func rememberedConvertChoice(descriptorUUID: String) -> Bool? {
        let choices = UserDefaults.standard.dictionary(forKey: convertChoiceKey) as? [String: Bool] ?? [:]
        return choices[descriptorUUID]
    }

    /// 这台设备是不是 iOS 27 起（需要转换旧格式）：只看大版本，与小版本和 build 号无关。
    /// 直接读系统版本，不依赖配对/设备信息（没配对也能装旧包，照样要转）。
    var needsOldFormatConversion: Bool {
        let version = UIDevice.current.systemVersion
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        return major >= 27
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

    /// 导入库文件目录：Documents/imported-packages，不存在就建一个。
    var importedPackagesURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(importedDirName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 启动时读回导入库记录；文件已经不在的条目直接丢掉（包删了就没用了）。
    private func loadImportedPackages() {
        guard let data = UserDefaults.standard.data(forKey: importedDefaultsKey),
              let saved = try? JSONDecoder().decode([ImportedPackage].self, from: data) else {
            importedPackages = []
            return
        }
        importedPackages = saved.filter { pkg in
            FileManager.default.fileExists(atPath: importedPackagesURL.appendingPathComponent(pkg.fileName).path)
        }
        saveImportedPackages()
    }

    private func saveImportedPackages() {
        guard let data = try? JSONEncoder().encode(importedPackages) else { return }
        UserDefaults.standard.set(data, forKey: importedDefaultsKey)
    }

    /// 往导入库里加一张：包文件（已转 WALLIVE1 加密版）+ 封面图存沙盒，记录记下来。
    /// thumbnail：从包里抠出来的封面图（JPEG），没有就传 nil，卡片显示占位图。
    func addImportedPackage(data: Data, displayName: String, thumbnail: Data?) {
        let id = UUID().uuidString
        let fileName = "\(id).tendies"
        let fileURL = importedPackagesURL.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL)
        } catch {
            return
        }
        var thumbFileName: String?
        if let thumbnail {
            let thumbName = "\(id)-thumb.jpg"
            if (try? thumbnail.write(to: importedPackagesURL.appendingPathComponent(thumbName))) != nil {
                thumbFileName = thumbName
            }
        }
        let pkg = ImportedPackage(
            id: id, displayName: displayName, fileName: fileName,
            thumbFileName: thumbFileName, size: data.count, importedAt: Date())
        importedPackages.insert(pkg, at: 0)
        saveImportedPackages()
    }

    /// 从导入库里删一张：沙盒里的包文件和封面一起删，记录也去掉（目录里的壁纸不受影响）。
    func removeImportedPackage(_ pkg: ImportedPackage) {
        try? FileManager.default.removeItem(at: importedPackagesURL.appendingPathComponent(pkg.fileName))
        if let thumb = pkg.thumbFileName {
            try? FileManager.default.removeItem(at: importedPackagesURL.appendingPathComponent(thumb))
        }
        importedPackages.removeAll { $0.id == pkg.id }
        saveImportedPackages()
    }

    /// 读导入库里一张包的文件内容（装之前用）；文件没了返回 nil。
    func importedPackageData(_ pkg: ImportedPackage) -> Data? {
        try? Data(contentsOf: importedPackagesURL.appendingPathComponent(pkg.fileName))
    }

    /// 导入库里一张包的封面图地址（没有封面返回 nil，卡片显示占位图）。
    func importedThumbURL(_ pkg: ImportedPackage) -> URL? {
        guard let thumb = pkg.thumbFileName else { return nil }
        return importedPackagesURL.appendingPathComponent(thumb)
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

    /// 安装当前包：统一走 Vellum 同款那条路（直读找库 + 逃逸直写，
    /// 只写一个描述符目录，不碰表和偏好，全程不碰配对隧道）。
    /// V1.19：不分系统版本、不看配对记录，一律这条路；直写隧道那条
    /// 停用，host / forceRefresh 留着签名兼容，不再使用。
    func install(host: String, forceRefresh: Bool = true) async -> String? {
        guard let data = packageData else { return nil }
        do {
            let outcome = try await BackupInstallFlow.install(
                packageData: data,
                pairingPath: "",
                log: { InstallLog.shared.append($0) })
            installHistory.append(outcome.descriptorUUID)
            return outcome.descriptorUUID
        } catch {
            statusMessage = "安装失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 诊断版安装：统一走 Vellum 同款那条路（只写描述符、不碰表和偏好、
    /// 全程不碰配对隧道），返回完整报告。
    /// 与旧 install() 的区别：逐目录结果记进 installReports，诊断页可显示；
    /// 暂存步骤与旧入口相同（DescriptorInstaller.stage），不改写盘逻辑、
    /// 配对、偏好键与路径、结构版本映射、标识策略。
    /// V1.19：不再读设备身份、不再按四态选择分路——直写隧道和备份改表
    /// 两条路都停用，host / forceRefresh 留着签名兼容，不再使用。
    func installWithReport(host: String, forceRefresh: Bool = true, onProgress: ((String, Double) -> Void)? = nil) async throws -> InstallReport? {
        guard let data = packageData else { return nil }
        return try await installWithReportBackup(data: data, onProgress: onProgress)
    }

    /// 备份路安装（V1.19 起是唯一安装路）：走 Vellum 同款那条（直读找库 +
    /// 逃逸直写，只写描述符目录）。结果记进 installReports，报告里
    /// `mode` 是 `.backup`。装完界面补本地桌面刷新，重启手机只作后备按钮。
    /// V1.19：配对路径恒传空串——这条路全程不碰配对隧道，绝不拿着配对
    /// 文件路径去碰隧道（27.2 上隧道必须回环 VPN）。走没走成 Vellum 同款
    /// 用结果的 `preferencesWritten` 判断：这条路从不写偏好，为 false；
    /// 老的改表路才为 true。
    private func installWithReportBackup(data: Data,
                                         onProgress: ((String, Double) -> Void)? = nil) async throws -> InstallReport? {
        do {
            InstallLog.shared.clear()
            let outcome = try await BackupInstallFlow.install(
                packageData: data,
                // 恒传空串：这条路全程不碰配对隧道，绝不拿着配对文件路径
                // 去碰配对隧道（27.2 上隧道必须回环 VPN）。
                pairingPath: "",
                log: { InstallLog.shared.append($0) },
                onProgress: onProgress)
            let configurationsDir = "Library/Application Support/PRBPosterExtensionDataStore/"
                + "Extensions/\(outcome.extensionID)/configurations"
            // 走没走成 Vellum 同款看结果：这条路从不写偏好，preferencesWritten
            // 一定是 false；老的改表路才写偏好（true）。没写偏好的报告里
            // 不凑 configurations 那行。
            let isVellumPath = !outcome.preferencesWritten
            let injectResults = isVellumPath
                ? outcome.injectResults
                : [InjectResult(targetParentDir: configurationsDir, ok: true, error: nil)]
                    + outcome.injectResults
            let report = InstallReport(
                descriptorUUID: outcome.descriptorUUID,
                injectResults: injectResults,
                preferencesWritten: outcome.preferencesWritten,
                verifyResults: [],
                registration: nil,
                // 刷新结论原样带给界面：确认了就不补桌面刷新，没确认
                // 就由界面补一次本地网页法只重启桌面。
                refresh: RefreshResult(confirmed: outcome.refreshConfirmed),
                mode: .backup,
                backupSummary: isVellumPath
                    ? "壁纸已写好（人家同款，只写描述符目录，表和偏好没碰）。"
                        + "正在刷新桌面（跟人家一样），回来后去锁屏图库查看，出现后再点设为墙纸组合。"
                    : "备份还原已完成（\(outcome.payloadCount) 个载荷，"
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
