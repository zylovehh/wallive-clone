// AFCClient.swift
// 干净重写：AFC 包协议客户端（lockdownd 远端服务通道上的文件操作）。
//
// 包头（来自 CLONE-NOTES.md 第 6 节二进制内含的 AfcPacket 字段顺序）：
//   magic(4, "CFA6") + entire_len(u32 LE) + header_payload_len(u32 LE)
//   + packet_num(u32 LE) + operation(u32 LE) + 负载。
// 本实现定义：entire_len = 整包字节数（包头 20 + 负载）；
// header_payload_len = 负载字节数。header_payload_len 的确切语义
// 待真机确认；若真机用法不同，只改该字段的计算，不改包结构。
// 操作码表为标准 AFC 操作码（与 libimobiledevice 的公开 AFC 表一致）；
// 二进制只确认了操作名，数字映射待真机确认。
// 传输模型：顺序请求/响应（同一时间只有一个未完成请求），
// 响应按发送顺序到达，不按 packet_num 匹配。
// 本文件不含广告 SDK、不含解锁逻辑、不含 exploit 代码。

import Foundation

/// AFC 操作码（标准表；数字映射待真机确认）。
public enum AFCOperation: UInt32 {
    case invalid = 0
    case status = 1
    case data = 2
    case readDir = 3
    case readFile = 4
    case writeFile = 5
    case writePart = 6
    case truncate = 7
    case removePath = 8
    case makeDir = 9
    case getFileInfo = 10
    case getDevInfo = 11
    case writeFileAtom = 12
    case fileOpen = 13
    case fileOpenResult = 14
    case read = 15
    case write = 16
    case fileSeek = 17
    case fileTell = 18
    case fileTellResult = 19
    case fileClose = 20
    case fileSetSize = 21
    case getConInfo = 22
    case setConOptions = 23
    case renamePath = 24
    case setFsBlockSize = 25
    case setSocketBlockSize = 26
    case fileSetModificationTime = 27
    case removePathAndContents = 28
}

/// AFC 包：20 字节包头 + 负载。
public struct AfcPacket {
    public static let headerLength = 20
    public static let magic = Data("CFA6".utf8)

    public let packetNumber: UInt32
    public let operation: AFCOperation
    public let payload: Data

    public init(packetNumber: UInt32, operation: AFCOperation, payload: Data) {
        self.packetNumber = packetNumber
        self.operation = operation
        self.payload = payload
    }

    /// 编码：magic + entire_len + header_payload_len + packet_num + operation + 负载。
    public func encode() -> Data {
        var out = Data()
        out.append(Self.magic)
        out.appendUInt32LE(UInt32(Self.headerLength + payload.count))
        out.appendUInt32LE(UInt32(payload.count))
        out.appendUInt32LE(packetNumber)
        out.appendUInt32LE(operation.rawValue)
        out.append(payload)
        return out
    }

    /// 解码一整包（调用方保证 data 长度恰好为 entire_len）。
    public static func decode(_ data: Data) throws -> AfcPacket {
        guard data.count >= headerLength else { throw AFCError.truncatedPacket }
        guard data.prefix(4) == magic else { throw AFCError.invalidMagic }
        let entireLength = Int(data.readUInt32LE(at: 4))
        guard entireLength == data.count else { throw AFCError.invalidHeader }
        let packetNumber = data.readUInt32LE(at: 12)
        let operationRaw = data.readUInt32LE(at: 16)
        guard let operation = AFCOperation(rawValue: operationRaw) else {
            throw AFCError.unknownOperation(operationRaw)
        }
        return AfcPacket(
            packetNumber: packetNumber,
            operation: operation,
            payload: data.dropFirst(headerLength)
        )
    }
}

/// AFC 客户端：经任一字节通道（通常是 lockdownd 会话的服务通道）发包。
public final class AFCClient {

    public enum Error: Swift.Error {
        case statusFailed(UInt32)
        case unexpectedOperation(expected: AFCOperation, got: AFCOperation)
        case invalidResponse
    }

    private let channel: ByteChannel
    private var nextPacketNumber: UInt32 = 0

    public init(channel: ByteChannel) {
        self.channel = channel
    }

    // MARK: - 收发

    /// 发一包、收一包（顺序模型）。
    private func transact(operation: AFCOperation, payload: Data) async throws -> AfcPacket {
        let packet = AfcPacket(
            packetNumber: nextPacketNumber, operation: operation, payload: payload)
        nextPacketNumber &+= 1
        try await channel.send(packet.encode())
        let header = try await channel.receiveExact(AfcPacket.headerLength)
        guard header.prefix(4) == AfcPacket.magic else { throw AFCError.invalidMagic }
        let entireLength = Int(header.readUInt32LE(at: 4))
        guard entireLength >= AfcPacket.headerLength else { throw AFCError.invalidHeader }
        let body = try await channel.receiveExact(entireLength - AfcPacket.headerLength)
        return try AfcPacket.decode(header + body)
    }

    /// 要求响应为 STATUS 且状态码为 0，否则抛错。
    private func expectStatus(_ packet: AfcPacket) throws {
        guard packet.operation == .status else {
            throw Error.unexpectedOperation(expected: .status, got: packet.operation)
        }
        let code: UInt32 = packet.payload.count >= 4 ? packet.payload.readUInt32LE(at: 0) : 0
        guard code == 0 else { throw Error.statusFailed(code) }
    }

    /// 要求响应为 DATA，返回负载。
    private func expectData(_ packet: AfcPacket) throws -> Data {
        guard packet.operation == .data else {
            throw Error.unexpectedOperation(expected: .data, got: packet.operation)
        }
        return packet.payload
    }

    // MARK: - 负载编解码

    /// NUL 结尾的字符串。
    private func cString(_ string: String) -> Data {
        Data(string.utf8) + Data([0])
    }

    /// 负载按 NUL 切分，丢弃空段。
    private func splitNUL(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// NUL 交替键值对 -> 字典（奇数个时丢弃最后一个孤键）。
    private func parseKeyValues(_ data: Data) -> [String: String] {
        let parts = splitNUL(data)
        var dict: [String: String] = [:]
        var i = 0
        while i + 1 < parts.count {
            dict[parts[i]] = parts[i + 1]
            i += 2
        }
        return dict
    }

    // MARK: - 操作

    public func getConnectionInfo() async throws -> [String: String] {
        let response = try await transact(operation: .getConInfo, payload: Data())
        return parseKeyValues(try expectData(response))
    }

    public func setConnectionOptions(_ options: [String: String]) async throws {
        var payload = Data()
        for (key, value) in options.sorted(by: { $0.key < $1.key }) {
            payload.append(cString(key))
            payload.append(cString(value))
        }
        try expectStatus(try await transact(operation: .setConOptions, payload: payload))
    }

    public func getDeviceInfo() async throws -> [String: String] {
        let response = try await transact(operation: .getDevInfo, payload: Data())
        return parseKeyValues(try expectData(response))
    }

    public func getFileInfo(_ path: String) async throws -> [String: String] {
        let response = try await transact(operation: .getFileInfo, payload: cString(path))
        return parseKeyValues(try expectData(response))
    }

    public func readDirectory(_ path: String) async throws -> [String] {
        let response = try await transact(operation: .readDir, payload: cString(path))
        return splitNUL(try expectData(response))
    }

    public func makeDirectory(_ path: String) async throws {
        try expectStatus(try await transact(operation: .makeDir, payload: cString(path)))
    }

    public func removePath(_ path: String) async throws {
        try expectStatus(try await transact(operation: .removePath, payload: cString(path)))
    }

    public func renamePath(from: String, to: String) async throws {
        try expectStatus(try await transact(
            operation: .renamePath, payload: cString(from) + cString(to)))
    }

    /// FileOpen：返回文件句柄（u64）。mode 如 "r"、"w"、"a"。
    public func fileOpen(_ path: String, mode: String) async throws -> UInt64 {
        let response = try await transact(
            operation: .fileOpen, payload: cString(path) + cString(mode))
        guard response.operation == .fileOpenResult, response.payload.count >= 8 else {
            throw Error.invalidResponse
        }
        return response.payload.readUInt64LE(at: 0)
    }

    public func fileWrite(handle: UInt64, data: Data) async throws {
        var payload = Data()
        payload.appendUInt64LE(handle)
        payload.append(data)
        try expectStatus(try await transact(operation: .write, payload: payload))
    }

    public func fileRead(handle: UInt64, length: UInt64) async throws -> Data {
        var payload = Data()
        payload.appendUInt64LE(handle)
        payload.appendUInt64LE(length)
        let response = try await transact(operation: .read, payload: payload)
        return try expectData(response)
    }

    public func fileClose(handle: UInt64) async throws {
        var payload = Data()
        payload.appendUInt64LE(handle)
        try expectStatus(try await transact(operation: .fileClose, payload: payload))
    }

    public func fileSetSize(handle: UInt64, size: UInt64) async throws {
        var payload = Data()
        payload.appendUInt64LE(handle)
        payload.appendUInt64LE(size)
        try expectStatus(try await transact(operation: .fileSetSize, payload: payload))
    }

    /// 改文件时间：time 为自 1970 年起的纳秒数（单位待真机确认）。
    public func fileSetModificationTime(handle: UInt64, nanoseconds: UInt64) async throws {
        var payload = Data()
        payload.appendUInt64LE(handle)
        payload.appendUInt64LE(nanoseconds)
        try expectStatus(try await transact(
            operation: .fileSetModificationTime, payload: payload))
    }

    /// 单包写小文件（路径 + 全量数据一包发；大文件走 fileOpen/Write/Close 分块）。
    public func writeFileAtom(_ path: String, data: Data) async throws {
        try expectStatus(try await transact(
            operation: .writeFileAtom, payload: cString(path) + data))
    }

    /// 写文件：FileOpen("w") → 分块 Write → FileClose；出错时尽力关闭句柄。
    public func writeFile(at path: String, data: Data, chunkSize: Int = 64 * 1024) async throws {
        let handle = try await fileOpen(path, mode: "w")
        do {
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                try await fileWrite(handle: handle, data: data[offset..<end])
                offset = end
            }
            // 空文件也需要一次 FileOpen/Close（句柄已建、零字节写入即空文件）。
            try await fileClose(handle: handle)
        } catch {
            try? await fileClose(handle: handle)
            throw error
        }
    }
}

/// AFC 层错误。
public enum AFCError: Swift.Error {
    case invalidMagic
    case invalidHeader
    case truncatedPacket
    case unknownOperation(UInt32)
}
