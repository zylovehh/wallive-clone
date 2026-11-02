// PacketTunnelProvider.swift
// 内置回环 VPN 的通道端：只做一件事——把发往 10.7.0.1 的包原样送回本机栈，
// 让本机管家服务（lockdownd）收到；路由只含 10.7.0.1，流量不出手机。
// 第一版（待真机验证）：反射式回环；若真机上检查不通，再按报错调整。

import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var running = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        settings.mtu = NSNumber(value: 1500)
        settings.ipv4Settings = NEIPv4Settings(addresses: ["10.7.0.1"], subnetMasks: ["255.255.255.255"])
        settings.ipv4Settings?.includedRoutes = [
            NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")
        ]
        // 不设 DNS：App 只连 IP（10.7.0.1），不走域名，别的不碰。
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                completionHandler(error)
                return
            }
            self.running = true
            self.reflectLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        running = false
        completionHandler()
    }

    /// 反射循环：从通道读到的包，原样写回，让本机栈投递给 10.7.0.1 的监听服务。
    private func reflectLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.running else { return }
            if !packets.isEmpty {
                _ = self.packetFlow.writePackets(packets, withProtocols: protocols)
            }
            self.reflectLoop()
        }
    }
}
