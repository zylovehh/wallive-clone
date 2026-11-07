// Wallive1Crypto.swift
// 干净重写：WALLIVE1 v1 包的加解密（与原版 App 的 v1 格式兼容）。
// 格式来源：对 1.1.3 二进制的逆向分析（见 ../wallive-re/NOTES.md），
// 与 wallive1.py 的验证结果一致（往返验证通过、原包解密一致）。
// 本文件不含任何广告 SDK、不含任何解锁/验证逻辑、不含 exploit 代码。

import CryptoKit
import Foundation

/// WALLIVE1 v1 包格式（已验证）：
///   头 32 字节 = "WALLIVE1"(8) + 16 字节随机值 + 8 字节大端明文长度，
///   全部 32 字节头用作 AES-GCM 的 AAD；
///   32 字节起 = SealedBox(combined) = nonce(12) + 密文 + tag(16)。
public enum Wallive1Crypto {

    // 格式常量：二进制内置的固定密钥材料（见 wallive-re/NOTES.md）。
    // 注意：这是 v1 包格式的公开常量，不是用户凭证；v2 走设备绑定路线，本文件不处理 v2。
    private static let materialA = Data([
        0x54, 0x97, 0xd1, 0x4e, 0x72, 0x0f, 0xaa, 0xa3,
        0xeb, 0x13, 0x69, 0x9f, 0x11, 0x1f, 0x4e, 0x12,
        0xf9, 0xbb, 0x67, 0x59, 0xb5, 0xce, 0x0a, 0xc5,
        0x6d, 0xfd, 0x9e, 0xbd, 0x28, 0xdc, 0xef, 0xc8,
    ])
    private static let materialB = Data([
        0x6a, 0x06, 0xf3, 0xe1, 0x01, 0x37, 0xa0, 0x09,
        0x5b, 0x49, 0xfe, 0x52, 0x1a, 0x1b, 0x64, 0xdd,
        0x74, 0xb4, 0xb3, 0x3b, 0xf5, 0xdc, 0xe4, 0x21,
        0xfd, 0xcf, 0xda, 0xc1, 0x9b, 0x3b, 0x9e, 0x82,
    ])
    private static let saltC = Data([
        0xff, 0x9f, 0xbc, 0xe3, 0xf8, 0xd8, 0xae, 0x22,
        0x1b, 0x6e, 0x16, 0x10, 0x63, 0xec, 0xd0, 0x2f,
    ])
    private static let info = Data("Wallive-offline-v1".utf8)

    /// 派生密钥：HKDF-SHA256(IKM = A‖B, salt = C, info = "Wallive-offline-v1", L = 32)。
    /// 与 wallive1.py 的派生结果一致（已验证）。
    public static var derivedKey: SymmetricKey {
        let inputKeyMaterial = SymmetricKey(data: materialA + materialB)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKeyMaterial,
            salt: saltC,
            info: info,
            outputByteCount: 32
        )
    }

    public enum Error: Swift.Error {
        case badMagic
        case tooShort
        case lengthMismatch
    }

    /// 解密 WALLIVE1 包 -> 明文 ZIP。
    public static func decrypt(_ package: Data) throws -> Data {
        guard package.count >= 32 + 12 + 16 else { throw Error.tooShort }
        guard package.prefix(8) == Data("WALLIVE1".utf8) else { throw Error.badMagic }
        let header = package.prefix(32)
        let body = package.dropFirst(32)
        let sealedBox = try AES.GCM.SealedBox(combined: body)
        let plaintext = try AES.GCM.open(sealedBox, using: derivedKey, authenticating: header)
        let expectedLength = header.dropFirst(24).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        guard plaintext.count == expectedLength else { throw Error.lengthMismatch }
        return plaintext
    }

    /// 加密明文 ZIP -> WALLIVE1 包（与原包长度结构一致：32 + 12 + 明文 + 16）。
    public static func encrypt(_ plaintext: Data) throws -> Data {
        var header = Data("WALLIVE1".utf8)
        header.append(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        var length = UInt64(plaintext.count).bigEndian
        header.append(Data(bytes: &length, count: 8))
        let sealedBox = try AES.GCM.seal(plaintext, using: derivedKey, authenticating: header)
        // SealedBox.combined = nonce(12) + 密文 + tag(16)。
        return header + sealedBox.combined!
    }

    /// 快速判断：是否为 WALLIVE1 包（只看魔数，不解密）。
    public static func isWallive1(_ data: Data) -> Bool {
        data.prefix(8) == Data("WALLIVE1".utf8)
    }
}
