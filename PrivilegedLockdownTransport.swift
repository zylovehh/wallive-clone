// PrivilegedLockdownTransport.swift
// 干净重写：特权写盘通道的具体实现（PrivilegedTransport 协议）。
//
// 路径（对应 CLONE-NOTES.md 第 5、6 节）：TCP 连回环 VPN 上的本机
// lockdownd（默认 10.7.0.1:62078）→ 配对握手 → StartSession →
// StartService（AFC 远端服务）→ AFC 写盘 → 登记安装。
// 前置条件（不在代码里做）：用户已安装并连接回环 VPN 描述文件，
// 使 10.7.0.1:62078 可达；配对记录文件由用户在运行时提供。
//
// 待真机确认的点（见 CLONE-NOTES.md 第 11 节清单）：
//   - 握手消息拼写与帧格式（RemoteLockdown.swift 文件头）；
//   - AFC 服务名：先试 "com.apple.afc"，失败则试 "<名>.shim.remote"
//     变体（变体命名规则待确认）；
//   - AFC 路径根解释：本实现按绝对路径直传（与 DescriptorInstaller
//     的目标路径写法一致），Media 相对根的可能性待确认；
//   - 系统 ManagedPosterBoard 安装记录的真实格式未确认，
//     recordInstall 目前写一份可审计的复刻版收据占位（见该方法注释）。
// 本文件不含广告 SDK、不含解锁逻辑、不含 exploit 代码、不含任何密钥值。

import Foundation

/// 特权传输：经 lockdownd 远端服务（AFC）写盘的具体实现。
public final class PrivilegedLockdownTransport: PrivilegedTransport {

    public enum Error: Swift.Error {
        case notConnected
        case descriptorNotFound(String)
        case serviceUnavailable(String)
    }

    private let record: PairingRecord
    private let host: String
    private let port: UInt16
    private let afcServiceName: String

    private var session: LockdownSession?
    private var afc: AFCClient?

    /// - Parameters:
    ///   - record: 运行时加载的配对记录（绝不内嵌）。
    ///   - host: lockdownd 主机，默认回环 VPN 设备 IP。
    ///   - port: lockdownd 端口，默认 62078。
    ///   - afcServiceName: AFC 服务名；失败时自动试 .shim.remote 变体。
    public init(
        record: PairingRecord,
        host: String = "10.7.0.1",
        port: UInt16 = 62078,
        afcServiceName: String = "com.apple.afc"
    ) {
        self.record = record
        self.host = host
        self.port = port
        self.afcServiceName = afcServiceName
    }

    /// 建链（幂等）：TCP → 配对握手 → StartSession → StartService → AFC。
    private func connectIfNeeded() async throws {
        if afc != nil { return }
        let channel = try TCPByteChannel(host: host, port: port)
        try await channel.connect()
        let session = LockdownSession(channel: channel, record: record)
        do {
            try await session.establish()
            _ = try await session.startSession()
            // 先试基本服务名；失败则试 .shim.remote 变体（命名规则待真机确认）。
            do {
                _ = try await session.startService(afcServiceName)
            } catch {
                _ = try await session.startService(afcServiceName + ".shim.remote")
            }
        } catch {
            session.close()
            throw error
        }
        self.session = session
        self.afc = AFCClient(channel: try session.serviceChannel)
    }

    public func close() {
        session?.close()
        session = nil
        afc = nil
    }

    // MARK: - PrivilegedTransport

    /// 把暂存目录写到远端根目录（递归）。
    /// 路径映射：暂存树含 "descriptors/<UUID>/" 前缀时剥掉它，
    /// 因为 remoteRoot 本身已含该 UUID（见 DescriptorInstaller.install）；
    /// 无此前缀时按原相对路径直写。
    public func writeDirectory(at localStage: URL, to remoteRoot: String) async throws {
        try await connectIfNeeded()
        guard let afc = afc else { throw Error.notConnected }

        let uuid = remoteRoot.split(separator: "/").last.map(String.init) ?? ""
        let stripPrefix = "descriptors/" + uuid + "/"

        var entries: [(relative: String, isDirectory: Bool)] = []
        let enumerator = FileManager.default.enumerator(
            at: localStage, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        while let url = enumerator?.nextObject() as? URL {
            let relative = url.path.replacingOccurrences(
                of: localStage.path + "/", with: "")
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            entries.append((relative: relative, isDirectory: values.isDirectory ?? false))
        }
        // 父目录先于子项：按深度、再按路径排序。
        entries.sort {
            ($0.relative.split(separator: "/").count, $0.relative)
                < ($1.relative.split(separator: "/").count, $1.relative)
        }

        for entry in entries {
            // 跳过“前缀本身的祖先目录”（如 descriptors、descriptors/<UUID>），
            // 它们只是暂存树的中间层，剥前缀后无对应物；写出会成多余空目录。
            if stripPrefix.hasPrefix(entry.relative + "/") { continue }
            let remotePath = remoteRoot + "/" + Self.mapPath(entry.relative, stripPrefix: stripPrefix)
            if entry.isDirectory {
                try await ensureDirectory(remotePath, afc: afc)
            } else {
                // 先确保父目录存在，再写文件。
                let parent = (remotePath as NSString).deletingLastPathComponent
                if !parent.isEmpty {
                    try await ensureDirectory(parent, afc: afc)
                }
                let data = try Data(contentsOf: localStage.appendingPathComponent(entry.relative))
                try await afc.writeFile(at: remotePath, data: data)
            }
        }
    }

    /// 登记一次安装记录。
    /// 现状说明：系统 ManagedPosterBoard 记录的真实格式未从静态分析中确认，
    /// 本方法先做两件可验证的事——(1) 确认描述符目录已在设备上；
    /// (2) 在描述符的 versions/1/ 下写一份复刻版收据（wallive-clone
    /// 专属文件名，不冒充系统文件名），含 UUID 与安装时间，供审计。
    /// 若真机验证发现系统需要特定的记录格式或 reconcile 通知，
    /// 在此处补，不改调用方。
    public func recordInstall(descriptorUUID: String) async throws {
        try await connectIfNeeded()
        guard let afc = afc else { throw Error.notConnected }
        let remoteRoot = DescriptorInstaller.posterBoardDescriptorsRoot + "/" + descriptorUUID
        let info = try await afc.getFileInfo(remoteRoot)
        guard info["st_ifmt"] == "S_IFDIR" || !info.isEmpty else {
            throw Error.descriptorNotFound(descriptorUUID)
        }
        let receipt: [String: Any] = [
            "descriptorUUID": descriptorUUID,
            "installedAt": ISO8601DateFormatter().string(from: Date()),
            "tool": "wallive-clone",
            "transport": "PrivilegedLockdownTransport",
        ]
        let receiptData = try PropertyListSerialization.data(
            fromPropertyList: receipt, format: .xml, options: 0)
        try await afc.writeFile(
            at: remoteRoot + "/versions/1/wallive-clone-install-receipt.plist",
            data: receiptData
        )
    }

    // MARK: - 内部

    /// 路径映射（可单测）：剥掉 "descriptors/<UUID>/" 前缀（若存在）。
    static func mapPath(_ relative: String, stripPrefix: String) -> String {
        if relative.hasPrefix(stripPrefix) {
            return String(relative.dropFirst(stripPrefix.count))
        }
        return relative
    }

    /// 确保远端目录存在：MakeDir 失败时用 GetFileInfo 复核——
    /// 若已是目录则放行（MakeDir 对已存在目录会报错），否则抛原错。
    private func ensureDirectory(_ path: String, afc: AFCClient) async throws {
        do {
            try await afc.makeDirectory(path)
        } catch {
            let info = try await afc.getFileInfo(path)
            if info["st_ifmt"] == "S_IFDIR" { return }
            throw error
        }
    }
}

/// 工厂：运行时从用户提供的配对记录文件建传输通道（绝不内嵌密钥）。
public enum PrivilegedTransportFactory {
    public static func make(
        pairingRecordFile: URL,
        host: String = "10.7.0.1",
        port: UInt16 = 62078
    ) throws -> PrivilegedLockdownTransport {
        let record = try PairingRecord.load(from: pairingRecordFile)
        return PrivilegedLockdownTransport(record: record, host: host, port: port)
    }
}
