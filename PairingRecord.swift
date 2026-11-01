// PairingRecord.swift
// 配对记录的运行时加载——按 Rust 配对主机实际写出的文件格式校验。
//
// 真文件只有 4 个键（idevice 的 RpPairingFile）：
//   public_key: Data(32)，private_key: Data(32)，identifier: String，
//   alt_irk: Data(16)，且 alt_irk 是可选的（可能没有）。
// 没有 peer_identifier / peer_public_key：那俩是对端信息，不属于主机身份文件，
// 老 loader 要求它们全有，拿真文件去喂会直接加载失败，所以改成不要求。
// 也不再假设“同一份私钥既当签名又当协商”：持久化私钥只是 Ed25519，
// 协商密钥只在握手里临时用、不进文件；本文件只做格式校验，不做任何密码学假设。
// 本文件不含广告 SDK、不含解锁逻辑；字段值绝不打印、不记录。

import Foundation

/// 配对记录（主机身份），仅在内存中持有，用于状态显示校验。
/// 注意：安装本身不再解析这份记录，FFI 直接拿文件路径去用；
/// 这里只校验文件格式对不对、给状态页一个脱敏描述。
public struct PairingRecord {

    /// host 公钥（32 字节）。
    public let hostPublicKey: Data
    /// host 私钥（32 字节）。只在内存中用，绝不打印、绝不写盘。
    public let hostPrivateKey: Data
    /// host 标识（字符串）。
    public let hostIdentifier: String
    /// alt IRK（16 字节），可能没有。
    public let altIRK: Data?

    public enum Error: Swift.Error {
        case fileNotFound
        case invalidPlist
        case missingField(String)
        case invalidLength(field: String, expected: Int, actual: Int)
    }

    /// 从配对文件加载并校验（运行时行为；不内嵌、不缓存到磁盘）。
    public static func load(from url: URL) throws -> PairingRecord {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.fileNotFound
        }
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, format: &format)
        guard let root = plist as? [String: Any] else { throw Error.invalidPlist }

        func dataField(_ name: String, expected: Int) throws -> Data {
            guard let value = root[name] else { throw Error.missingField(name) }
            guard let d = value as? Data else { throw Error.invalidPlist }
            guard d.count == expected else {
                throw Error.invalidLength(field: name, expected: expected, actual: d.count)
            }
            return d
        }
        func optionalDataField(_ name: String, expected: Int) throws -> Data? {
            guard let value = root[name] else { return nil }
            guard let d = value as? Data else { throw Error.invalidPlist }
            guard d.count == expected else {
                throw Error.invalidLength(field: name, expected: expected, actual: d.count)
            }
            return d
        }
        func stringField(_ name: String) throws -> String {
            guard let value = root[name] else { throw Error.missingField(name) }
            guard let s = value as? String else { throw Error.invalidPlist }
            return s
        }

        return PairingRecord(
            hostPublicKey: try dataField("public_key", expected: 32),
            hostPrivateKey: try dataField("private_key", expected: 32),
            hostIdentifier: try stringField("identifier"),
            altIRK: try optionalDataField("alt_irk", expected: 16)
        )
    }

    /// 供日志使用的脱敏描述：只含字段存在性与字节长度，绝不含任何值。
    public var redactedDescription: String {
        let irk = altIRK.map { "\($0.count)B" } ?? "无"
        return "PairingRecord(public_key: \(hostPublicKey.count)B, private_key: \(hostPrivateKey.count)B, "
            + "identifier: present, alt_irk: \(irk))"
    }
}
