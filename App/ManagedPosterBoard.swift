// ManagedPosterBoard.swift
// App 自己的安装账本（阶段 C）：原版登记的第一层。
// 已证实（原版 Wallive 1.1.3 反汇编）：
//   记录落在 App 自身的 NSUserDefaults.standardUserDefaults，不是系统侧文件；
//   三个键名已钉死（ManagedPosterBoardRemoteInstallRecords /
//   ManagedPosterBoardPackageInstallRecords / ManagedPosterBoardWallpaperNames，
//   见 REGISTRATION-INVESTIGATION-1105.md 2.2 节）；
//   值是 [String: RemoteInstallRecord] 编码后的 Data；
//   RemoteInstallRecord 的键恰好 2 个：paths（tag 0）与 fingerprint（tag 1），
//   1 个必需 + 1 个可选（RE-CONFIRMATION-1105.md 第 6 项，encode 在
//   0x100151024、init(from:) 在 0x100154e20）。
// 纠正：上一版写的 4 个字段名（descriptorIdentifier、provenance、
// packageKey、bundleIdentifier）已被同一份再确认报告证伪——它们不属于
// RemoteInstallRecord，而是另一个更大记录类型的属性表里的名字，本文件
// 已按证实后的 2 个键重写。哪个键必需、哪个键可选，以及两个字段的精确
// Swift 类型，再确认报告里仍是未证实；本文件按最自然的语义取
// paths: [String]（必需，本次安装落地的描述符目录）、
// fingerprint: String?（可选，本次安装的指纹：描述符 UUID），只供本 App
// 自己读写（账本只有本 App 读），与原版的精确类型对上号后再调。
// 未证实、按本 App 自己定的部分：
//   Data 里用 JSON 编码（原版用的编码器未从反汇编区分）；
//   三本账的字典键：远程记录按描述符 UUID、包记录按包显示名、名称记录按
//   描述符 UUID（原版字典键的取值未确认，只供本 App 自己读写）。
// 这个账本本身不会让图库列出壁纸——它只是让 App 自己记得装过哪张，
// 供诊断区显示条数、后续清理时比对用；必须和读回、对账、刷新一起上才完整。

import Foundation

/// 一条安装记录：只写已证实的两个键，不凭空加字段。
/// paths：本次安装落地的描述符目录（两个目标目录的绝对路径）。
/// fingerprint：本次安装的指纹，用描述符 UUID。
struct RemoteInstallRecord: Codable {
    var paths: [String]
    var fingerprint: String?
}

/// 登记结果（诊断区显示用）：三本账各自的条数，失败只记 error、不抛错。
/// 条数为 -1 表示那本账这次没写上（看 error）。
public struct RegistrationResult {
    public let remoteRecords: Int
    public let packageRecords: Int
    public let names: Int
    public let error: String?
}

enum ManagedPosterBoard {
    static let remoteRecordsKey = "ManagedPosterBoardRemoteInstallRecords"
    static let packageRecordsKey = "ManagedPosterBoardPackageInstallRecords"
    static let wallpaperNamesKey = "ManagedPosterBoardWallpaperNames"

    /// 安装成功后记一笔：远程记录（按描述符 UUID 索引）+ 包记录（按包名索引）
    /// + 名称记录（描述符 UUID → 显示名）。三本账各自读旧合并再写回，
    /// 不覆盖之前装过的壁纸。返回三本账写回后的条数。
    static func recordInstallation(
        descriptorUUID: String,
        installedPaths: [String],
        packageKey: String,
        wallpaperName: String
    ) -> RegistrationResult {
        var error: String?
        let remoteRecord = RemoteInstallRecord(
            paths: installedPaths, fingerprint: descriptorUUID)
        let remoteCount = saveRemoteInstallRecords([descriptorUUID: remoteRecord], error: &error)
        let packageRecord = RemoteInstallRecord(
            paths: installedPaths, fingerprint: descriptorUUID)
        let packageCount = savePackageInstallRecords([packageKey: packageRecord], error: &error)
        let namesCount = saveWallpaperNames([descriptorUUID: wallpaperName], error: &error)
        return RegistrationResult(
            remoteRecords: remoteCount, packageRecords: packageCount,
            names: namesCount, error: error)
    }

    /// 原版保存函数之一的干净重写：读旧字典、合并、写回 UserDefaults。
    /// 返回写回后的总条数；失败返回 -1 并把原因写进 error。
    static func saveRemoteInstallRecords(
        _ newRecords: [String: RemoteInstallRecord], error: inout String?
    ) -> Int {
        saveRecords(newRecords, key: remoteRecordsKey, error: &error)
    }

    /// 原版保存函数之二的干净重写：同上，写包记录那本账。
    static func savePackageInstallRecords(
        _ newRecords: [String: RemoteInstallRecord], error: inout String?
    ) -> Int {
        saveRecords(newRecords, key: packageRecordsKey, error: &error)
    }

    private static func saveRecords(
        _ newRecords: [String: RemoteInstallRecord], key: String, error: inout String?
    ) -> Int {
        var merged = loadRecords(key: key)
        for (k, v) in newRecords { merged[k] = v }
        do {
            let data = try JSONEncoder().encode(merged)
            UserDefaults.standard.set(data, forKey: key)
            return merged.count
        } catch let encodeError {
            // 注意：catch 带绑定时 error 才指 inout 参数；不带绑定会被捕获的 Error 遮住。
            appendError(&error, "写\(key)失败：\(encodeError.localizedDescription)")
            return -1
        }
    }

    private static func loadRecords(key: String) -> [String: RemoteInstallRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: RemoteInstallRecord].self, from: data)
        else { return [:] }
        return decoded
    }

    /// 名称记录：描述符 UUID → 显示名，同样读旧合并再写回。
    static func saveWallpaperNames(_ newNames: [String: String], error: inout String?) -> Int {
        var merged = loadWallpaperNames()
        for (k, v) in newNames { merged[k] = v }
        do {
            let data = try JSONEncoder().encode(merged)
            UserDefaults.standard.set(data, forKey: wallpaperNamesKey)
            return merged.count
        } catch let encodeError {
            appendError(&error, "写\(wallpaperNamesKey)失败：\(encodeError.localizedDescription)")
            return -1
        }
    }

    private static func loadWallpaperNames() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: wallpaperNamesKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    /// 诊断用：三本账各自的条数（只读不写）。
    static func recordCounts() -> (remote: Int, package: Int, names: Int) {
        (loadRecords(key: remoteRecordsKey).count,
         loadRecords(key: packageRecordsKey).count,
         loadWallpaperNames().count)
    }

    private static func appendError(_ error: inout String?, _ text: String) {
        error = (error.map { $0 + "；" } ?? "") + text
    }
}
