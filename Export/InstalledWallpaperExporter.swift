import Foundation

/// 导出已装壁纸：取一份 PosterBoard 备份，从备份清单里挑出指定
/// 描述符 UUID 的载荷文件，按标准 .tendies 目录结构重打包。
///
/// 复用取表通道（`PosterBoardBackup.prepareFetchDirectory` +
/// `BackupFFI.fetchPosterBoard`）：备份清单的 relativePath 形如
/// `Library/Application Support/PRBPosterExtensionDataStore/<版本>/
/// Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/<UUID>/…`，
/// 包内路径取 `descriptors/` 起的后缀，正好对上安装链路认的结构。
/// 载荷与包内结构是否逐文件一一对应，待真机跑一次验证。
enum InstalledWallpaperExporter {
    struct ExportResult {
        let descriptorUUID: String
        /// 导出文件名，形如 `wallpaper-<UUID前8位>.tendies`。
        let fileName: String
        let data: Data
        let fileCount: Int
    }

    /// 取备份并重打指定描述符的 .tendies（明文 zip，调用方按需再加密）。
    static func exportWallpaper(descriptorUUID: String, pairingPath: String,
                                log: BackupLog = { _ in }) async throws -> ExportResult {
        let fm = FileManager.default
        let backupRoot = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("posterboard-export")

        // 1. 拿 UDID：取表目录按 UDID 分（与 RestoreTest 同一做法）。
        let info = try await BackupFFI.deviceInfo(
            pairingPath: pairingPath, log: log)
        let udid = info.udid

        // 2. 备好取表目录：旧目录先清掉，别让上次的残留混进来。
        try? fm.removeItem(at: backupRoot)
        try PosterBoardBackup.prepareFetchDirectory(
            backupRoot: backupRoot, udid: udid, log: log)

        // 3. 跑备份：只备 PosterBoard 一个容器。
        let fetch = try await BackupFFI.fetchPosterBoard(
            pairingPath: pairingPath, backupRoot: backupRoot, log: log)
        guard fetch.keptFiles > 0 else {
            throw BackupError("备份跑完了，但一个文件都没留下来（手机可能没发 PosterBoard 的文件）。")
        }

        // 4. 从备份清单里挑出该描述符的载荷行。
        let manifest = ManifestStore(deviceDir: fetch.backupDir, log: log)
        let rows = try manifest.rows(relativePathLike: "%descriptors/\(descriptorUUID)%")
            .filter { $0.payload != nil }
        guard !rows.isEmpty else {
            throw BackupError("备份里没找到 \(descriptorUUID) 的载荷文件，可能尚未安装或已被清理。")
        }

        // 5. 按包内路径重打 zip。
        let zip = ZipFoundationAdapter()
        var entries: [(path: String, data: Data)] = []
        for row in rows {
            guard let pkgPath = packagePath(of: row.relativePath),
                  let data = try? Data(contentsOf: row.payload!) else { continue }
            entries.append((path: pkgPath, data: data))
        }
        guard !entries.isEmpty else {
            throw BackupError("载荷文件都读不出来，导出失败。")
        }
        let data = try zip.rebuild(entries: entries)
        log("export: \(descriptorUUID) 导出完成，\(entries.count) 个文件，\(data.count) 字节。")
        return ExportResult(descriptorUUID: descriptorUUID,
                            fileName: "wallpaper-\(String(descriptorUUID.prefix(8))).tendies",
                            data: data, fileCount: entries.count)
    }

    /// `…/PRBPosterExtensionDataStore/<版本>/descriptors/<UUID>/x` →
    /// `descriptors/<UUID>/x`。找不到 descriptors 段的行不进包。
    private static func packagePath(of relativePath: String) -> String? {
        guard let range = relativePath.range(of: "descriptors/") else { return nil }
        return "descriptors/" + relativePath[range.upperBound...]
    }
}
