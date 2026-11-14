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

    /// 容器里的一条描述符记录。
    struct DescriptorInfo {
        let uuid: String
        /// 尽力而为的显示名（来自 providerInfo.plist），读不到为 nil。
        let name: String?
    }

    /// 取一份新的 PosterBoard 备份，返回备份目录。
    ///
    /// 备份覆盖整个 PosterBoard 容器，拿到目录后可反复用于扫描和导出。
    static func fetchBackup(pairingPath: String,
                            log: BackupLog = { _ in }) async throws -> URL {
        let fm = FileManager.default
        let backupRoot = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("posterboard-export")

        // 拿 UDID：取表目录按 UDID 分（与 RestoreTest 同一做法）。
        let info = try await BackupFFI.deviceInfo(
            pairingPath: pairingPath, log: log)

        // 备好取表目录：旧目录先清掉，别让上次的残留混进来。
        try? fm.removeItem(at: backupRoot)
        try PosterBoardBackup.prepareFetchDirectory(
            backupRoot: backupRoot, udid: info.udid, log: log)

        let fetch = try await BackupFFI.fetchPosterBoard(
            pairingPath: pairingPath, backupRoot: backupRoot, log: log)
        guard fetch.keptFiles > 0 else {
            throw BackupError("备份跑完了，但一个文件都没留下来（手机可能没发 PosterBoard 的文件）。")
        }
        return fetch.backupDir
    }

    /// 扫描备份清单，列出容器里全部描述符——不限于本 App 装的。
    /// 其他 App（如 Walllive）装进系统容器的壁纸也在其中：装进容器后
    /// 系统要直接渲染，掏出来的是已可用的内容，与其原始下载包是否
    /// 加密无关。
    static func listAllDescriptors(backupDir: URL) throws -> [DescriptorInfo] {
        let manifest = ManifestStore(deviceDir: backupDir)
        let rows = try manifest.rows(relativePathLike: "%descriptors/%")

        var order: [String] = []
        var names: [String: String] = [:]
        for row in rows {
            guard let uuid = descriptorUUID(of: row.relativePath) else { continue }
            if !order.contains(uuid) { order.append(uuid) }
            if row.relativePath.lowercased().hasSuffix("descriptors/\(uuid)/providerinfo.plist"),
               let url = row.payload, names[uuid] == nil {
                names[uuid] = providerInfoName(url: url)
            }
        }
        return order.map { DescriptorInfo(uuid: $0, name: names[$0]) }
    }

    /// 重打指定描述符的 .tendies（明文 zip，调用方按需再加密）。
    static func exportWallpaper(descriptorUUID: String, backupDir: URL,
                                log: BackupLog = { _ in }) throws -> ExportResult {
        let manifest = ManifestStore(deviceDir: backupDir)
        let rows = try manifest.rows(relativePathLike: "%descriptors/\(descriptorUUID)%")
            .filter { $0.payload != nil }
        guard !rows.isEmpty else {
            throw BackupError("备份里没找到 \(descriptorUUID) 的载荷文件，可能尚未安装或已被清理。")
        }

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

extension InstalledWallpaperExporter {
    /// 从 relativePath 里抠出描述符 UUID（descriptors/ 后面那一段）。
    fileprivate static func descriptorUUID(of relativePath: String) -> String? {
        guard let range = relativePath.range(of: "descriptors/") else { return nil }
        let rest = relativePath[range.upperBound...]
        let first = rest.split(separator: "/").first.map(String.init) ?? ""
        guard first.count == 36 else { return nil }
        return first
    }

    /// 尽力而为：从 providerInfo.plist 里读展示名，读不出就返回 nil。
    private static func providerInfoName(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        for key in ["displayName", "name"] {
            if let v = dict[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }
}
