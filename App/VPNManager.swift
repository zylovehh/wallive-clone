// VPNManager.swift
// 内置回环 VPN 的主程序端：管隧道的保存、启动、停止和状态。
// 扩展包名跟着主程序包名走（主程序包名 + .WalliveTunnel），重签改了主程序包名也不用再改这里。

import Foundation
import Combine
import NetworkExtension

/// 内置回环 VPN 的主程序端：状态页直接用这个对象显示和开关。
@MainActor
final class VPNManager: ObservableObject {
    /// 扩展包名 = 主程序包名 + .WalliveTunnel，重签后自动跟上，不写死。
    static var tunnelBundleID: String {
        (Bundle.main.bundleIdentifier ?? "com.example.walliveclone") + ".WalliveTunnel"
    }
    static let tunnelServerAddress = "10.7.0.1"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String = ""

    private var manager: NETunnelProviderManager?
    /// 这次会话里用户亲手关过 VPN 就不再自动连（避免“关了又被打开”）。
    private var userStopped = false
    /// 载入进行中的标记：自动连和 init 里的载入可能同时跑，串起来防止
    /// 并发载入把配置存出两份。
    private var loadInFlight = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        Task { await load() }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 状态文字（状态页直接显示）。
    var statusText: String {
        switch status {
        case .invalid: return "未设置"
        case .disconnected: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .disconnecting: return "断开中…"
        case .reasserting: return "重连中…"
        @unknown default: return "未知"
        }
    }

    var isConnected: Bool { status == .connected }

    /// 载入已保存的隧道配置（没有就新建一个，保存进系统偏好）。
    /// 同时只跑一份：有载入在跑时直接返回，等下一轮（onAppear 或手动点）再来。
    func load() async {
        guard !loadInFlight else { return }
        loadInFlight = true
        defer { loadInFlight = false }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.tunnelBundleID }) {
                manager = existing
            } else {
                let fresh = NETunnelProviderManager()
                fresh.localizedDescription = "WalliveClone 内置回环 VPN"
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = Self.tunnelBundleID
                proto.serverAddress = Self.tunnelServerAddress
                fresh.protocolConfiguration = proto
                fresh.isEnabled = true
                try await fresh.saveToPreferences()
                manager = fresh
            }
            refreshStatus()
        } catch {
            lastError = "载入 VPN 配置失败：\(error.localizedDescription)"
        }
    }

    /// 开启：保存配置（首次会弹系统提示，点“允许”），然后启动隧道。
    func start() async {
        lastError = ""
        if manager == nil { await load() }
        guard let manager = manager else { return }
        do {
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try manager.connection.startVPNTunnel()
            refreshStatus()
        } catch {
            lastError = "开启失败：\(error.localizedDescription)"
        }
    }

    /// 关闭：停掉隧道。用户亲手关过就记下，自动连不再碰。
    func stop() {
        lastError = ""
        userStopped = true
        manager?.connection.stopVPNTunnel()
        refreshStatus()
    }

    /// 进状态页自动连：没连上、也没正在连/正在断，而且这次会话里用户没亲手
    /// 关过，就自动开。第一次会弹系统授权提示，点“允许”后隧道直接连上。
    func autoConnectIfNeeded() {
        guard !userStopped else { return }
        switch status {
        case .connected, .connecting, .disconnecting, .reasserting:
            return
        default:
            Task { await start() }
        }
    }

    private func refreshStatus() {
        if let manager = manager {
            status = manager.connection.status
        }
    }
}
