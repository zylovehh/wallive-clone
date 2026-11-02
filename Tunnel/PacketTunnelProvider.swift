// PacketTunnelProvider.swift
// 内置回环 VPN 的通道端：让 App 像连另一台机器一样连上本机管家服务。
// 做法（对齐 LocalDevVPN）：接口地址与对端地址分开，每包交换源 / 目的 IP 并重算校验和，
// 内核在两端各自终结 TCP，小模块不持有任何 TCP 状态。
// 只放行 IPv4 + TCP + {10.7.1.1, 10.7.0.1} 两个方向的包，其他丢弃。

import Foundation
import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var running = false

    // 隧道本端（接口）地址与对端（虚拟电脑）地址，必须分开。
    // 对端 10.7.0.1 是 App 要连的目的；本端 10.7.1.1 是 App 发包时的源。
    // 以前两边都写 10.7.0.1，源和目的撞车，握手没法收敛。
    private let interfaceBytes: [UInt8] = [10, 7, 1, 1]
    private let remoteBytes: [UInt8] = [10, 7, 0, 1]
    private let remoteAddress = "10.7.0.1"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        settings.mtu = NSNumber(value: 1500)
        settings.ipv4Settings = NEIPv4Settings(addresses: ["10.7.1.1"], subnetMasks: ["255.255.255.255"])
        settings.ipv4Settings?.includedRoutes = [
            NEIPv4Route(destinationAddress: remoteAddress, subnetMask: "255.255.255.255")
        ]
        // 排除默认路由：除对端外的流量不进隧道。
        settings.ipv4Settings?.excludedRoutes = [
            NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")
        ]
        // 不设 DNS：App 只连 IP（10.7.0.1），不走域名，别的不碰。
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                completionHandler(error)
                return
            }
            self.running = true
            self.packetLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        running = false
        completionHandler()
    }

    /// 包循环：从通道读包，交换后写回；无状态，内核两端各自维护 TCP。
    private func packetLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.running else { return }
            var out: [Data] = []
            var outProtocols: [NSNumber] = []
            for (packet, proto) in zip(packets, protocols) {
                if let swapped = self.swapIPv4Packet(packet, protocolNumber: proto) {
                    out.append(swapped)
                    outProtocols.append(proto)
                }
                // 非 IPv4 / 非 TCP / 非目标流量直接丢弃，不写回，避免回环。
            }
            if !out.isEmpty {
                _ = self.packetFlow.writePackets(out, withProtocols: outProtocols)
            }
            self.packetLoop()
        }
    }

    /// 交换一个 IPv4 包的源 / 目的 IP，并重算校验和；不符合条件的返回 nil（丢弃）。
    /// - 协议号必须是 AF_INET（2），即 IPv4；其他直接丢弃。
    /// - 只放行 TCP（IP 协议字段 6）且 {源, 目的} 为 {10.7.1.1, 10.7.0.1} 任一方向的包。
    /// - 后续分片（片偏移 ≠ 0）：只交换 IP 并重算 IP 校验和，不碰 TCP 校验和、不按端口过滤，直接放行。
    private func swapIPv4Packet(_ packet: Data, protocolNumber: NSNumber) -> Data? {
        guard protocolNumber.intValue == 2 else { return nil } // AF_INET
        guard packet.count >= 20 else { return nil }
        var bytes = [UInt8](packet)
        // IPv4 头：第 0 字节高 4 位版本必须为 4，低 4 位 IHL × 4 = 头长（可能大于 20，不能硬编码）。
        guard (bytes[0] >> 4) == 4 else { return nil }
        let ihl = Int(bytes[0] & 0x0F) * 4
        guard ihl >= 20, packet.count >= ihl else { return nil }
        // 总长（大端 16 位）必须 ≤ 包实际长度。
        let totalLength = (Int(bytes[2]) << 8) | Int(bytes[3])
        guard totalLength >= ihl, totalLength <= packet.count else { return nil }
        // 只处理 TCP（协议字段偏移 9）。
        guard bytes[9] == 6 else { return nil }
        // 源（偏移 12）与目的（偏移 16），各 4 字节。
        let src = Array(bytes[12..<16])
        let dst = Array(bytes[16..<20])
        let isTargetPair = (src == interfaceBytes && dst == remoteBytes)
            || (src == remoteBytes && dst == interfaceBytes)
        guard isTargetPair else { return nil }
        // 分片：标志 / 片偏移字段（偏移 6，2 字节大端）；片偏移（低 13 位）≠ 0 即为后续分片。
        let fragField = (UInt16(bytes[6]) << 8) | UInt16(bytes[7])
        let isSubsequentFragment = (fragField & 0x1FFF) != 0
        // 交换源 / 目的。
        for i in 0..<4 {
            bytes[12 + i] = dst[i]
            bytes[16 + i] = src[i]
        }
        // 重算 IPv4 头校验和（偏移 10，2 字节）：先清零，对头长按 16 位大端字求和、折叠、取反。
        bytes[10] = 0
        bytes[11] = 0
        let ipChecksum = checksum(Array(bytes[0..<ihl]))
        bytes[10] = UInt8(ipChecksum >> 8)
        bytes[11] = UInt8(ipChecksum & 0xFF)
        // 后续分片没有完整 TCP 头：只换 IP，不碰 TCP，直接放行。
        if isSubsequentFragment {
            return Data(Array(bytes[0..<totalLength]))
        }
        // 首片或未分片：重算 TCP 校验和（伪首部必须用交换后的源 / 目的，否则内核直接丢包）。
        // TCP 头起点 = IP 头长；TCP 校验和字段在 TCP 头偏移 16。
        let tcpStart = ihl
        let tcpLength = totalLength - ihl
        guard tcpLength >= 20, tcpStart + tcpLength <= packet.count else { return nil }
        // 伪首部：源（交换后）+ 目的（交换后）+ 0 + 协议 6 + TCP 长（大端 16 位）。
        var pseudo: [UInt8] = []
        pseudo.append(contentsOf: bytes[12..<16]) // 交换后源
        pseudo.append(contentsOf: bytes[16..<20]) // 交换后目的
        pseudo.append(0)
        pseudo.append(6)
        pseudo.append(UInt8(tcpLength >> 8))
        pseudo.append(UInt8(tcpLength & 0xFF))
        // TCP 校验和字段清零（TCP 头偏移 16），再拼伪首部 + TCP 段一起算。
        bytes[tcpStart + 16] = 0
        bytes[tcpStart + 17] = 0
        var tcpBytes: [UInt8] = []
        tcpBytes.append(contentsOf: pseudo)
        tcpBytes.append(contentsOf: bytes[tcpStart..<(tcpStart + tcpLength)])
        let tcpChecksum = checksum(tcpBytes)
        bytes[tcpStart + 16] = UInt8(tcpChecksum >> 8)
        bytes[tcpStart + 17] = UInt8(tcpChecksum & 0xFF)
        return Data(Array(bytes[0..<totalLength]))
    }

    /// 16 位校验和：按大端字求和、折叠进位、取反；奇数长度末尾补零字节参与计算（不写入包）。
    private func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i < bytes.count {
            let hi = UInt32(bytes[i]) << 8
            let lo: UInt32 = (i + 1 < bytes.count) ? UInt32(bytes[i + 1]) : 0
            sum += hi | lo
            i += 2
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }
}
