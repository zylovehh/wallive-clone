// RemoteLockdown.swift
// 干净重写：回环 VPN 之上的 lockdownd 远端会话（配对 → 会话 → 服务）。
//
// 流程（对应 CLONE-NOTES.md 第 5、6 节）：TCP 连 10.7.0.1:62078 →
// 配对握手（以配对记录的身份互认证）→ lockdownd 会话（StartSession）→
// 启动远端服务（StartService，AFC 等 .shim.remote 变体）→ 服务通道。
//
// !!! 真机验证提示：本文件的握手消息结构与帧格式是“实现模型”，
// 其不变部分是安全属性（验对端公钥、互认证、会话密钥派生），
// 而线上的具体拼写（消息键名、帧头格式、密码套件细节）必须在真机上
// 对照实际 lockdownd 行为确认，见 CLONE-NOTES.md 第 11 节清单。
// 在确认前，不要把本文件当作已验证的线协议实现。
// 本文件不含广告 SDK、不含解锁逻辑、不含 exploit 代码、不含任何密钥值。

import CryptoKit
import Foundation
import Network

// MARK: - 小端整数读写（AFC 与帧头共用）

extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
    mutating func appendUInt64LE(_ value: UInt64) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 8))
    }
    func readUInt32LE(at offset: Int) -> UInt32 {
        subdata(in: offset..<offset + 4).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }
    func readUInt64LE(at offset: Int) -> UInt64 {
        subdata(in: offset..<offset + 8).withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
    }
}

// MARK: - 字节通道抽象

/// 双向字节通道（TCP、加密会话通道、测试环回都实现它）。
public protocol ByteChannel {
    func send(_ data: Data) async throws
    /// 精确读满 count 字节（不足则继续等；对端关闭则抛错）。
    func receiveExact(_ count: Int) async throws -> Data
    func close()
}

/// TCP 通道（Network 框架；走系统路由，因此回环 VPN 连通时可达 10.7.0.1）。
public final class TCPByteChannel: ByteChannel {
    private let connection: NWConnection
    private let lock = NSLock()
    private var buffer = Data()

    public enum Error: Swift.Error {
        case invalidPort
        case notReady
        case closed
        case sendFailed
    }

    public init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw Error.invalidPort
        }
        connection = NWConnection(
            host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    }

    /// 等连接就绪（10 秒超时）。
    public func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            var resumed = false
            let resumeOnce: (Result<Void, Swift.Error>) -> Void = { result in
                self.lock.lock()
                defer { self.lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(Error.closed))
                default:
                    break
                }
            }
            connection.start(queue: .global())
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                resumeOnce(.failure(Error.notReady))
            }
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    public func receiveExact(_ count: Int) async throws -> Data {
        lock.lock()
        var pending = buffer
        lock.unlock()
        while pending.count < count {
            let chunk = try await receiveChunk(maxLength: count - pending.count)
            guard !chunk.isEmpty else { throw Error.closed }
            pending.append(chunk)
        }
        let out = pending.prefix(count)
        lock.lock()
        buffer = pending.dropFirst(count)
        lock.unlock()
        return out
    }

    private func receiveChunk(maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Swift.Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let data = data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: Data())
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }
}

// MARK: - 帧格式（实现模型，待真机确认）

/// 长度前缀帧：4 字节大端长度 + 负载。握手阶段传明文 plist，
/// 握手完成后传 AES-GCM 密封体（见 SecureByteChannel）。
/// 帧格式本身是实现模型；若真机用另一种 RemoteXPC 信封，
/// 只改这一层，不改消息结构。
enum FramedMessage {
    static func encode(_ payload: Data) -> Data {
        var out = Data()
        var length = UInt32(payload.count).bigEndian
        out.append(Data(bytes: &length, count: 4))
        out.append(payload)
        return out
    }

    static func decodeHeader(_ bytes: Data) -> Int {
        Int(bytes.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
    }
}

// MARK: - 加密会话通道

/// 握手完成后的加密通道：每条消息独立 AES-GCM 密封，
/// nonce 为 12 字节（4 字节零 + 8 字节大端计数器），收发各用一个计数器。
/// 密码套件细节（AES-GCM + 计数器 nonce）待真机确认。
final class SecureByteChannel: ByteChannel {
    private let inner: ByteChannel
    private let key: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(inner: ByteChannel, key: SymmetricKey) {
        self.inner = inner
        self.key = key
    }

    private func nonce(for counter: UInt64) throws -> AES.GCM.Nonce {
        var bytes = Data(count: 4)
        var c = counter.bigEndian
        bytes.append(Data(bytes: &c, count: 8))
        return try AES.GCM.Nonce(data: bytes)
    }

    func send(_ data: Data) async throws {
        let sealed = try AES.GCM.seal(data, using: key, nonce: nonce(for: sendCounter))
        sendCounter += 1
        try await inner.send(FramedMessage.encode(sealed.combined!))
    }

    /// 解密后的字节流缓冲：AFC 层按字节流读（先读包头、再读包体），
    /// 而安全通道按消息密封；本缓冲把“消息”拼回“字节流”。
    /// 注意：会话阶段（sendRequest/receiveMessage）与 AFC 阶段不得交错，
    /// 两个阶段各自消费整条消息，缓冲在阶段切换时应为空。
    private var decryptedBuffer = Data()

    func receiveExact(_ count: Int) async throws -> Data {
        while decryptedBuffer.count < count {
            decryptedBuffer.append(try await receiveMessage())
        }
        let out = decryptedBuffer.prefix(count)
        decryptedBuffer.removeFirst(count)
        return out
    }

    /// 读一整条解密后的消息（不预设长度）。
    func receiveMessage() async throws -> Data {
        let header = try await inner.receiveExact(4)
        let length = FramedMessage.decodeHeader(header)
        let sealedBytes = try await inner.receiveExact(length)
        let sealedBox = try AES.GCM.SealedBox(combined: sealedBytes)
        let plain = try AES.GCM.open(sealedBox, using: key)
        receiveCounter += 1
        return plain
    }

    func close() {
        inner.close()
    }
}

// MARK: - lockdownd 会话

/// lockdownd 远端会话：配对握手 → StartSession → StartService。
public final class LockdownSession {

    public enum Error: Swift.Error {
        case notEstablished
        case peerKeyMismatch
        case authenticationFailed
        case invalidResponse
        case serviceFailed(String)
    }

    private let channel: ByteChannel
    private let record: PairingRecord
    private var secure: SecureByteChannel?

    public init(channel: ByteChannel, record: PairingRecord) {
        self.channel = channel
        self.record = record
    }

    /// 配对握手（实现模型，见文件头提示）：
    ///  1. 发 hello（host 标识 + host 公钥）；
    ///  2. 收设备 hello，验其公钥必须等于配对记录的 peer_public_key，
    ///     否则立即中止（这是防中间人的关键检查）；
    ///  3. X25519 协商 + HKDF-SHA256 派生会话密钥；
    ///  4. Ed25519 互认证：双方对握手 transcript 签名并验签；
    ///  5. 其后全部 lockdownd 消息走加密通道。
    public func establish() async throws {
        let hello = try plistData([
            "Type": "PairingHello",
            "HostID": record.hostIdentifier,
            "HostPublicKey": record.hostPublicKey,
        ])
        try await channel.send(FramedMessage.encode(hello))

        let deviceHelloBytes = try await receiveFramedPlain()
        let deviceHello = try plistDict(deviceHelloBytes)
        guard let deviceKey = deviceHello["DevicePublicKey"] as? Data,
              deviceKey == record.devicePublicKey
        else {
            throw Error.peerKeyMismatch
        }

        let sharedSecret = try record.agreementPrivateKey().sharedSecretFromKeyAgreement(
            with: record.deviceAgreementPublicKey())
        let sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("RemotePairing-session".utf8),
            outputByteCount: 32
        )

        let transcript = hello + deviceHelloBytes
        let signature = try record.signingPrivateKey().signature(for: transcript)
        try await channel.send(FramedMessage.encode(plistData([
            "Type": "PairingAuth",
            "Signature": signature,
        ])))

        let deviceAuthBytes = try await receiveFramedPlain()
        let deviceAuth = try plistDict(deviceAuthBytes)
        guard let deviceSignatureData = deviceAuth["Signature"] as? Data else {
            throw Error.authenticationFailed
        }
        guard try record.deviceSigningPublicKey().isValidSignature(deviceSignatureData, for: transcript) else {
            throw Error.authenticationFailed
        }

        secure = SecureByteChannel(inner: channel, key: sessionKey)
    }

    /// 握手完成后的服务通道（AFC 等服务走它）。
    public var serviceChannel: ByteChannel {
        get throws {
            guard let secure = secure else { throw Error.notEstablished }
            return secure
        }
    }

    /// 发一个 lockdownd 请求（plist），收一个响应（plist）。
    public func sendRequest(_ request: [String: Any]) async throws -> [String: Any] {
        guard let secure = secure else { throw Error.notEstablished }
        try await secure.send(plistData(request))
        let response = try await secure.receiveMessage()
        return try plistDict(response)
    }

    public func queryType() async throws -> [String: Any] {
        try await sendRequest(["Request": "QueryType"])
    }

    /// StartSession：HostID 取配对记录的 identifier；
    /// SystemBUID 在本记录格式里没有对应字段，故不发，待真机确认是否需要。
    public func startSession() async throws -> [String: Any] {
        try await sendRequest(["Request": "StartSession", "HostID": record.hostIdentifier])
    }

    /// StartService：返回响应字典。远端服务（.shim.remote 变体）假设在
    /// 本会话通道上直接可用（不另开 TCP）；若真机返回 Port 字段，
    /// 调用方需按经典 lockdownd 方式另连该端口（见报告清单）。
    public func startService(_ name: String) async throws -> [String: Any] {
        let response = try await sendRequest(["Request": "StartService", "Service": name])
        if let error = response["Error"] as? String {
            throw Error.serviceFailed(error)
        }
        return response
    }

    public func close() {
        channel.close()
    }

    // MARK: - 内部：明文帧与 plist 编解码

    private func receiveFramedPlain() async throws -> Data {
        let header = try await channel.receiveExact(4)
        let length = FramedMessage.decodeHeader(header)
        return try await channel.receiveExact(length)
    }

    private func plistData(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0)
    }

    private func plistDict(_ data: Data) throws -> [String: Any] {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, format: &format)
        guard let dict = plist as? [String: Any] else { throw Error.invalidResponse }
        return dict
    }
}
