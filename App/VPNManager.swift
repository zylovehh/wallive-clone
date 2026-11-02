// VPNManager.swift
// 内置回环 VPN 的主程序端：管隧道的保存、启动、停止和状态。
// 扩展包名必须与工程里扩展目标的包名一致，改了包名这里要同步改。

import Foundation
import Combine
import NetworkExtension

/// 内置回环 VPN 的主程序端：状态页直接用这个对象显示和开关。
@MainActor
final class VPNManager: ObservableObject {
    static let tunnelBundleID = "com.example.walliveclone.WalliveTunnel"
    static let tunnelServerAddress = "10.7.0.1"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String = ""

    private var manager: NETunnelProviderManager?
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
    func load() async {
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

    /// 关闭：停掉隧道。
    func stop() {
        lastError = ""
        manager?.connection.stopVPNTunnel()
        refreshStatus()
    }

    private func refreshStatus() {
        if let manager = manager {
            status = manager.connection.status
        }
    }
}
