// PairingGenerator.swift
// 干净重写：状态页“生成配对文件”——本机自配对，生成配对记录。
//
// 流程：
//   1. 本地生成主机密钥对与主机侧字段（不需要设备，全部本地完成）；
//   2. 经现有 TCPByteChannel 连回环 VPN 的 lockdownd（默认 10.7.0.1:62078）；
//   3. 发 Pair 请求，收设备回的配对材料（设备标识 + 设备公钥）；
//   4. 按 PairingRecord 的 6 字段结构组装记录，先写临时文件、
//      经 PairingRecord.load 回读校验通过后，才替换正式文件；
//   5. 任何一步失败都不写正式文件（旧文件原样不动），绝不编假记录冒充。
//
// !!! 推断、待真机验证（不要把以下当作已验证）：
//   - Pair 请求与响应字段名（Request/Pair、HostID、HostPublicKey、
//     DeviceID、DevicePublicKey 及 peer_identifier/peer_public_key 回退）
//     是按 RemoteLockdown.swift 现有帧 plist 风格推断的；原版走的是
//     RPPairing（RemoteXPC + Bonjour 发现，见 CLONE-NOTES.md 第 5 节），
//     本实现用直连 TCP + 帧 plist 近似，lockdownd 是否接受待真机验证。
//   - 自配对是否需要在手机上点信任，静态分析无法确认
//     （见 CLONE-NOTES.md 第 5 节末与第 11.5 节第 3 条）；若设备要求
//     点信任而用户没点，配对会失败，本实现只会如实报错，不会绕过。
//   - identifier 取新 UUID、alt_irk 取 16 字节随机数：是实现选择，
//     设备是否接受该格式待真机验证；alt_irk 的字段语义亦待确认，
//     本实现只保证记录格式要求它存在且为 16 字节。
//   - 与 PairingRecord 模型一致：同一 32 字节种子既作 Ed25519 签名种子、
//     也作 X25519 协商种子（现有模型如此，待真机验证）。
//   - 现有 LockdownSession.establish() 不能复用做 fresh Pair：它要求
//     已有记录做互认证；本实现只复用传输层（TCPByteChannel +
//     FramedMessage 帧格式），Pair 交换是新增的。
//
// 安全：私钥只在生成过程的内存里存在，写盘只写 App 沙盒内的正式文件
// （与导入记录同一存放处）；不打印、不记录、不分享、不导出任何密钥值；
// 进度文案只含步骤名，不含任何值。
// 本文件不含广告 SDK、不含解锁逻辑、不含 exploit 代码、不含任何密钥值。

import CryptoKit
import Foundation

/// 本机自配对，生成配对记录文件。
public enum PairingGenerator {

    public enum Error: Swift.Error {
        case connectionFailed(String)
        case timeout
        case pairRejected(String)
        case invalidResponse(String)
        case missingDeviceMaterial
        case invalidRecord(String)
    }

    /// 生成并保存配对记录；成功返回经回读校验的记录。
    /// - Parameters:
    ///   - host/port: lockdownd 地址（默认回环 VPN 的 10.7.0.1:62078）。
    ///   - targetURL: 正式文件地址（调用方传 App 沙盒 Documents/wallive-pairing.plist）。
    ///   - progress: 步骤文案回调（只含步骤名，不含任何值）。
    public static func generate(
        host: String = "10.7.0.1",
        port: UInt16 = 62078,
        targetURL: URL,
        progress: @escaping (String) -> Void
    ) async throws -> PairingRecord {
        // 1. 主机侧字段：本地生成，不需要设备。
        progress("正在生成主机密钥…")
        let signingKey = Curve25519.Signing.PrivateKey()
        let hostPrivateKey = signingKey.rawRepresentation
        let hostPublicKey = signingKey.publicKey.rawRepresentation
        let hostIdentifier = UUID().uuidString
        let altIRK = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        // 2. 连 lockdownd（TCPByteChannel 自带 10 秒连接超时）。
        progress("正在连接 lockdownd…")
        let channel = try TCPByteChannel(host: host, port: port)
        do {
            try await channel.connect()
        } catch {
            channel.close()
            throw Error.connectionFailed(error.localizedDescription)
        }
        defer { channel.close() }

        // 3. Pair 交换（推断格式，待真机验证）：一发一收，30 秒总超时。
        progress("正在发送配对请求…")
        let request = try plistData([
            "Request": "Pair",
            "HostID": hostIdentifier,
            "HostPublicKey": hostPublicKey,
        ])
        let responseData = try await withTimeout(seconds: 30) {
            try await channel.send(FramedMessage.encode(request))
            return try await receiveFramed(channel)
        }
        let response = try plistDict(responseData)
        if let rejected = response["Error"] as? String {
            throw Error.pairRejected(rejected)
        }

        // 设备侧材料只能来自设备回包，缺失就是失败，绝不编造。
        // 字段名是推断：主用 DeviceID/DevicePublicKey（与现有设备
        // hello 的 DevicePublicKey 命名一致），回退记录字段原名。
        progress("正在等设备回配对材料…")
        guard let deviceKey = (response["DevicePublicKey"] as? Data)
                ?? (response["peer_public_key"] as? Data),
              deviceKey.count == 32,
              let deviceID = (response["DeviceID"] as? String)
                ?? (response["peer_identifier"] as? String),
              !deviceID.isEmpty
        else {
            throw Error.missingDeviceMaterial
        }

        // 4. 组装 → 临时文件 → 回读校验 → 替换正式文件。
        progress("正在校验并保存…")
        let dict: [String: Any] = [
            "public_key": hostPublicKey,
            "private_key": hostPrivateKey,
            "identifier": hostIdentifier,
            "alt_irk": altIRK,
            "peer_identifier": deviceID,
            "peer_public_key": deviceKey,
        ]
        let directory = targetURL.deletingLastPathComponent()
        let tmpURL = directory.appendingPathComponent(".wallive-pairing.tmp.plist")
        let tmpData = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0)
        try tmpData.write(to: tmpURL, options: .atomic)
        do {
            let loaded = try PairingRecord.load(from: tmpURL)
            guard loaded.hostPublicKey == hostPublicKey,
                  loaded.hostPrivateKey == hostPrivateKey,
                  loaded.hostIdentifier == hostIdentifier,
                  loaded.altIRK == altIRK,
                  loaded.deviceIdentifier == deviceID,
                  loaded.devicePublicKey == deviceKey
            else {
                throw Error.invalidRecord("回读字段与生成内容不一致")
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            if let e = error as? Error { throw e }
            throw Error.invalidRecord(error.localizedDescription)
        }
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: targetURL)
        return try PairingRecord.load(from: targetURL)
    }

    // MARK: - 内部：帧收发、plist 编解码、超时

    private static func receiveFramed(_ channel: ByteChannel) async throws -> Data {
        let header = try await channel.receiveExact(4)
        let length = FramedMessage.decodeHeader(header)
        guard length > 0, length < 1_000_000 else {
            throw Error.invalidResponse("帧长度异常：\(length)")
        }
        return try await channel.receiveExact(length)
    }

    private static func plistData(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0)
    }

    private static func plistDict(_ data: Data) throws -> [String: Any] {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, format: &format)
        guard let dict = plist as? [String: Any] else {
            throw Error.invalidResponse("响应不是字典")
        }
        return dict
    }

    private static func withTimeout<T>(
        seconds: UInt64, _ work: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw Error.timeout
            }
            guard let result = try await group.next() else {
                throw Error.timeout
            }
            group.cancelAll()
            return result
        }
    }
}

extension PairingGenerator.Error: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail):
            return "连不上 lockdownd：\(detail)"
        case .timeout:
            return "等设备回应超时（30 秒）：请确认回环 VPN 已连接，再试一次。"
        case .pairRejected(let detail):
            return "设备拒绝了配对：\(detail)"
        case .invalidResponse(let detail):
            return "设备回包看不懂：\(detail)"
        case .missingDeviceMaterial:
            return "设备没有返回配对材料：可能需要在手机上点信任，或配对握手格式还需在真机上确认。"
        case .invalidRecord(let detail):
            return "生成的记录校验没过，已放弃保存：\(detail)"
        }
    }
}
