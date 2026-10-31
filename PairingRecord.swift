// PairingRecord.swift
// 干净重写：Lockdown 配对记录的运行时加载（远程配对身份）。
//
// 配对记录由用户在运行时提供（文件路径参数）；本文件不内嵌任何密钥，
// 不打印、不记录任何密钥值；密钥只在内存中短暂存在，供握手层使用。
// 记录格式（只提字段名与长度，值绝不出现在这里）：
//   public_key: Data(32)，private_key: Data(32)，identifier: String，
//   alt_irk: Data(16)，peer_identifier: String，peer_public_key: Data(32)。
// 32 字节密钥与 Curve25519 一致；握手里签名与协商各自的用法，
// 待真机验证（见 CLONE-NOTES.md 第 11 节“待真机验证清单”）。
// 本文件不含广告 SDK、不含解锁逻辑、不含 exploit 代码。

import CryptoKit
import Foundation

/// Lockdown 配对记录（远程配对身份），仅在内存中持有。
public struct PairingRecord {

    /// host 公钥（32 字节）。
    public let hostPublicKey: Data
    /// host 私钥（32 字节）。只在内存中用，绝不打印、绝不写盘。
    public let hostPrivateKey: Data
    /// host 标识（字符串）。
    public let hostIdentifier: String
    /// alt IRK（16 字节）。
    public let altIRK: Data
    /// 设备标识（peer_identifier，字符串）。
    public let deviceIdentifier: String
    /// 设备公钥（peer_public_key，32 字节）。
    public let devicePublicKey: Data

    public enum Error: Swift.Error {
        case fileNotFound
        case invalidPlist
        case missingField(String)
        case invalidLength(field: String, expected: Int, actual: Int)
    }

    /// 从用户提供的配对记录文件加载（运行时行为；不内嵌、不缓存到磁盘）。
    /// 校验字段存在性与长度；任何值都不会被打印或记录。
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
        func stringField(_ name: String) throws -> String {
            guard let value = root[name] else { throw Error.missingField(name) }
            guard let s = value as? String else { throw Error.invalidPlist }
            return s
        }

        return PairingRecord(
            hostPublicKey: try dataField("public_key", expected: 32),
            hostPrivateKey: try dataField("private_key", expected: 32),
            hostIdentifier: try stringField("identifier"),
            altIRK: try dataField("alt_irk", expected: 16),
            deviceIdentifier: try stringField("peer_identifier"),
            devicePublicKey: try dataField("peer_public_key", expected: 32)
        )
    }

    /// 供日志使用的脱敏描述：只含字段存在性与字节长度，绝不含任何值。
    public var redactedDescription: String {
        "PairingRecord(public_key: \(hostPublicKey.count)B, private_key: \(hostPrivateKey.count)B, "
            + "identifier: present, alt_irk: \(altIRK.count)B, "
            + "peer_identifier: present, peer_public_key: \(devicePublicKey.count)B)"
    }

    /// Ed25519 签名私钥（由 32 字节种子派生；握手签名用）。
    public func signingPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: hostPrivateKey)
    }

    /// X25519 协商私钥（由同一 32 字节材料派生；握手协商用）。
    public func agreementPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hostPrivateKey)
    }

    /// 对端 X25519 协商公钥（由 peer_public_key 派生）。
    public func deviceAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublicKey)
    }

    /// 对端 Ed25519 签名公钥（由 peer_public_key 派生；验签用）。
    public func deviceSigningPublicKey() throws -> Curve25519.Signing.PublicKey {
        try Curve25519.Signing.PublicKey(rawRepresentation: devicePublicKey)
    }
}
