// DescriptorInstaller.swift
// 描述符安装的第一段（本地可做，不需要特权）：校验并暂存描述符包。
// 第二段（真正写盘）走 AirliftInstaller，不再经过已删除的手写 lockdownd/AFC。
//
// 顺带修了一个老问题：WALLIVE1 加密包以前是拿原包（还是加密的）去解条目，
// 解出来是错的；现在先解密成标准 zip 再暂存。
// 本文件不含广告 SDK、不含解锁逻辑、不含 exploit 代码。

import Foundation

/// 描述符安装器：本地暂存。
public struct DescriptorInstaller {

    public enum Error: Swift.Error {
        case invalidPackage
    }

    private let zip: ZipEditing

    public init(zip: ZipEditing) {
        self.zip = zip
    }

    /// 校验并暂存描述符包，返回暂存目录与描述符 UUID。
    /// 暂存目录可直接交给 AirliftInstaller 写盘。
    public func stage(_ packageData: Data) throws -> (stageDirectory: URL, descriptorUUID: String) {
        let info = try TendiesPackage.inspect(packageData, zip: zip)
        // WALLIVE1 包先解密，否则后面解出来的条目全是错的。
        let plainData: Data
        if Wallive1Crypto.isWallive1(packageData) {
            plainData = try Wallive1Crypto.decrypt(packageData)
        } else {
            plainData = packageData
        }
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallive-clone-stage-\(info.descriptorUUID)")
        try? FileManager.default.removeItem(at: stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        // 把包内条目原样解到暂存目录（zip 层由 ZipEditing 提供）。
        let entries = try zip.listEntries(in: plainData)
        for path in entries where !path.hasSuffix("/") {
            let data = try zip.readEntry(path, in: plainData)
            let dest = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: dest)
        }
        return (stage, info.descriptorUUID)
    }
}
