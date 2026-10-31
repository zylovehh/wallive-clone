// InstallFlow.swift
// 干净重写：端到端安装流程（代码层面走通“配对 → 连 lockdownd →
// 传文件 → 登记安装”这条路）。
//
// 完整路径：
//   1. TendiesPackage.inspect：识别 WALLIVE1/标准 zip、校验描述符结构；
//   2. DescriptorInstaller.stage：本地暂存（不需要特权）；
//   3. PrivilegedTransportFactory.make：运行时加载用户提供的配对记录；
//   4. TCP 连 10.7.0.1:62078 → 配对握手 → StartSession → StartService(AFC)；
//   5. AFC 写盘：暂存树 → PosterBoard 描述符目录（路径映射见
//      PrivilegedLockdownTransport.mapPath）；
//   6. recordInstall：确认描述符在位 + 写复刻版收据（系统记录格式待确认）。
// 前置条件：用户已安装并连接回环 VPN（LocalDevVPN，设备 IP 10.7.0.1）。
// 本文件不含广告 SDK、不含解锁逻辑、不含 exploit 代码、不含任何密钥值。

import Foundation

/// 端到端安装：包数据 + 配对记录文件 → 设备上的 PosterBoard 描述符。
/// 返回描述符 UUID。调用方负责在真机上验证安装结果（见报告清单）。
public enum InstallFlow {

    /// - Parameters:
    ///   - packageData: .tendies/.wallive 包数据（WALLIVE1 或标准 zip）。
    ///   - zip: ZipEditing 实现（接入方提供，如 ZIPFoundation 适配）。
    ///   - pairingRecordFile: 用户提供的配对记录文件 URL（运行时加载）。
    ///   - host/port: lockdownd 地址，默认回环 VPN 的 10.7.0.1:62078。
    public static func install(
        packageData: Data,
        zip: ZipEditing,
        pairingRecordFile: URL,
        host: String = "10.7.0.1",
        port: UInt16 = 62078
    ) async throws -> String {
        let installer = DescriptorInstaller(zip: zip)
        let (stage, descriptorUUID) = try installer.stage(packageData)
        let transport = try PrivilegedTransportFactory.make(
            pairingRecordFile: pairingRecordFile, host: host, port: port)
        do {
            try await installer.install(
                stagedDirectory: stage, descriptorUUID: descriptorUUID, via: transport)
        } catch {
            transport.close()
            throw error
        }
        transport.close()
        return descriptorUUID
    }
}
