// InstallFlow.swift
// 端到端安装：包数据 + 配对文件路径 → 设备上的 PosterBoard 描述符。
//
// 路径：
//   1. TendiesPackage.inspect：识别 WALLIVE1/标准 zip、校验描述符结构；
//   2. DescriptorInstaller.stage：本地暂存（不需要特权）；
//   3. AirliftInstaller.install：装前先检查（只读），经配对隧道写盘
//      （找容器、注入描述符、写偏好），装完补兼容目录并强制刷新
//      偏好，装完直接返回，不重启设备、不重启手机。
// 前置条件：用户已安装并连接回环 VPN（LocalDevVPN，设备 IP 10.7.0.1），
// 且已生成配对文件（状态页“生成配对文件”）。
// 本文件不含广告 SDK、不含解锁逻辑、不含任何密钥值。

import Foundation

/// 端到端安装：包数据 + 配对文件路径 → 实际装上的描述符 UUID。
/// 返回的 UUID 可能和包里原 UUID 不同（无建议元数据时换新 UUID，见 AirliftInstaller）。
/// 调用方负责在真机上验证安装结果。
public enum InstallFlow {

    /// - Parameters:
    ///   - packageData: .tendies/.wallive 包数据（WALLIVE1 或标准 zip）。
    ///   - zip: ZipEditing 实现（接入方提供，如 ZIPFoundation 适配）。
    ///   - pairingPath: 配对文件路径（Rust 配对主机写出的文件）。
    ///   - targetHost: 回环 VPN 的设备 IP，默认 10.7.0.1。
    public static func install(
        packageData: Data,
        zip: ZipEditing,
        pairingPath: String,
        targetHost: String = "10.7.0.1",
        forceRefresh: Bool = true
    ) async throws -> String {
        let installer = DescriptorInstaller(zip: zip)
        let (stage, descriptorUUID) = try installer.stage(packageData)
        return try await AirliftInstaller.install(
            stagedDirectory: stage, descriptorUUID: descriptorUUID,
            pairingPath: pairingPath, targetHost: targetHost, forceRefresh: forceRefresh)
    }
}
