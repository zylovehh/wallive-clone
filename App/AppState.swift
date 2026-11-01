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
    @Published var packageError: String?
    @Published var pairingLoaded = false
    @Published var pairingDescription = "未导入"
    @Published var installHistory: [String] = []
    @Published var statusMessage = ""

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
    func setPackage(_ data: Data) {
        packageData = data
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
