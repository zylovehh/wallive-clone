// DescriptorInstaller.swift
// 干净重写：描述符安装逻辑（分两段，缺口明说）。
//
// 已实现（不需要特权）：把描述符包暂存到本地目录、校验结构、
// 算出 PosterBoard 目标路径、生成安装记录占位。
// 未实现（需要特权通道，见 PrivilegedTransport）：真正把文件写进
// PosterBoard 目录并向系统登记安装记录。
//
// 为什么缺这一段：原版 App 是靠“回环 VPN + 自配对 + lockdownd 远端服务
// （AFC 等）”把文件写出沙盒的。那套通道（AirCard 模式，MIT；
// SideStore 的 StosVPN 模式，宽松许可）本身是公开的工程模式，
// 但完整实现它是一项独立的大工程（配对协议、lockdownd 远端服务、
// AFC 包协议、安装记录格式），不是本复刻第一阶段的范围，
// 本文件不冒充已实现它，也不从原版二进制里抠 exploit 代码。

import Foundation

/// 特权传输通道（未实现）：把已暂存的描述符写进系统 PosterBoard 目录。
/// 实现它需要（缺口清单，见 README）：
///   1. 用户已安装并连接回环 VPN（如 LocalDevVPN，设备 IP 10.7.0.1），
///      使本机 lockdownd（端口 62078）可达；
///   2. 配对记录（Lockdown pairing record，含 peer_public_key / peer_identifier），
///      即原版流程里“重新配对这台 iPhone”一步；
///   3. 经 lockdownd 远端服务通道调用 AFC 文件操作
///      （MakeDir / WriteFile / RenamePath 等）写目标路径；
///   4. 写入并登记安装记录（ManagedPosterBoardRemoteInstallRecords / 
///      ManagedPosterBoardPackageInstallRecords，格式未从静态分析中确认）。
public protocol PrivilegedTransport {
    /// 把本地暂存目录下的全部文件写到目标根目录（递归）。
    func writeDirectory(at localStage: URL, to remoteRoot: String) async throws
    /// 登记一次安装记录（格式待确认）。
    func recordInstall(descriptorUUID: String) async throws
}

/// 描述符安装器：特权无关的部分全部实现，特权写盘走 PrivilegedTransport。
public struct DescriptorInstaller {

    /// PosterBoard 描述符目标根（系统路径，沙盒内不可写，仅作目标描述）。
    public static let posterBoardDescriptorsRoot =
        "/var/mobile/Library/com.apple.Posters.CollectionsPosterApp/descriptors"
    /// PosterBoard 扩展数据存储根（系统路径，同上）。
    public static let posterExtensionDataStoreRoot =
        "/var/mobile/Library/Application Support/PRBPosterExtensionDataStore"

    public enum Error: Swift.Error {
        case invalidPackage
        case transportMissing
    }

    private let zip: ZipEditing

    public init(zip: ZipEditing) {
        self.zip = zip
    }

    /// 第一段（本地可做）：校验并暂存描述符包，返回暂存目录与描述符 UUID。
    /// 返回的暂存目录可直接交给 PrivilegedTransport 写盘。
    public func stage(_ packageData: Data) throws -> (stageDirectory: URL, descriptorUUID: String) {
        let info = try TendiesPackage.inspect(packageData, zip: zip)
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallive-clone-stage-\(info.descriptorUUID)")
        try? FileManager.default.removeItem(at: stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        // 把包内条目原样解到暂存目录（zip 层由 ZipEditing 提供）。
        let entries = try zip.listEntries(in: packageData)
        for path in entries where !path.hasSuffix("/") {
            let data = try zip.readEntry(path, in: packageData)
            let dest = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: dest)
        }
        return (stage, info.descriptorUUID)
    }

    /// 第二段（需要特权通道）：经 PrivilegedTransport 写盘并登记。
    /// 未提供 transport 时明确报错，不静默假装装上了。
    public func install(
        stagedDirectory: URL, descriptorUUID: String, via transport: PrivilegedTransport?
    ) async throws {
        guard let transport = transport else { throw Error.transportMissing }
        let remoteRoot = Self.posterBoardDescriptorsRoot + "/" + descriptorUUID
        try await transport.writeDirectory(at: stagedDirectory, to: remoteRoot)
        try await transport.recordInstall(descriptorUUID: descriptorUUID)
    }
}
