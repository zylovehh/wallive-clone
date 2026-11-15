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
                            log: @escaping BackupLog = { _ in }) async throws -> URL {
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
            if fetch.discardedFiles > 0 {
                // 手机发了文件，但都被过滤规则丢掉：多半是备份内容结构与
                // 预期的 PosterBoard 路径/命名对不上，需要诊断日志确认。
                throw BackupError("备份收到了 \(fetch.discardedFiles) 个文件，但都不符合 PosterBoard 的识别规则，所以没保留下来。请到「状态 → 诊断日志」查看本次 install 日志，把日志发给我以便排查。")
            }
            // 手机一个文件都没发：多半是备份会话没真正建立或列表为空。
            throw BackupError("备份跑完了，但手机一个文件都没发过来。请到「状态 → 诊断日志」查看本次 install 日志，把日志发给我以便排查。")
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

/// 直读导出：不走 mobilebackup2 备份协议，直接对壁纸库容器吃只读
/// 沙箱逃逸，现场枚举并读取描述符文件，重打 .tendies。
///
/// 背景：27.0.1 上定向备份反复「跑完 0 文件」（手机不通过备份协议
/// 吐文件），而实时扫商店同款的只读逃逸通道（V1.44 起）实测稳定
/// 可用——导出改以直读为正路，备份通道降级为兜底。
///
/// 用法：
///  1. `scanStore(log:)` 枚举商店全部在册描述符（含别的工具刷入的）；
///  2. `exportDescriptor(...)` 对选中那条直读重打 .tendies。
enum DirectStoreExporter {

    /// 直读扫到的一条描述符。
    struct DirectDescriptor {
        let uuid: String
        let extensionID: String
        let structureVersion: String
        let fullPath: String
        /// providerInfo.plist 里读到的展示名，读不到为 nil。
        let name: String?
    }

    /// 直读枚举商店全部版本/扩展下的描述符目录（只读逃逸）。
    /// 成功返回名单；定位不到容器或拿不到通行证返回 (nil, 一句原因)。
    static func scanStore(log: @escaping (String) -> Void = { _ in })
        -> (entries: [DirectDescriptor]?, failReason: String?) {
        let fm = FileManager.default
        guard let container = RestoreTest.containerForLiveScan() else {
            log("直读导出：定位不到壁纸库容器。")
            return (nil, "定位不到壁纸库容器。")
        }
        // 对容器整体吃只读扩展：进得去商店目录，才能翻 descriptors。
        let escape = WorseQueryEscape.consume(target: container, requireWrite: false, log: log)
        guard let handle = escape.handle else {
            log("直读导出：\(escape.failReason ?? "拿不到只读通行证")。")
            return (nil, escape.failReason ?? "拿不到只读通行证")
        }
        defer { WorseQueryEscape.release(handle) }
        let storeRoot = container + PosterBoard.storeRoot
        var results: [DirectDescriptor] = []
        // 版本目录（61、62……）挨个翻；每个版本下再翻 Extensions。
        let versionDirs = ((try? fm.contentsOfDirectory(atPath: storeRoot)) ?? []).sorted()
        for v in versionDirs {
            let extRoot = storeRoot + "/" + v + "/Extensions"
            let exts = ((try? fm.contentsOfDirectory(atPath: extRoot)) ?? []).sorted()
            for ext in exts {
                let descRoot = extRoot + "/" + ext + "/descriptors"
                let descs = ((try? fm.contentsOfDirectory(atPath: descRoot)) ?? []).sorted()
                for d in descs {
                    let full = descRoot + "/" + d
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
                    results.append(DirectDescriptor(uuid: d, extensionID: ext,
                                                    structureVersion: v, fullPath: full,
                                                    name: readDescriptorName(at: full)))
                }
            }
        }
        log("直读扫商店：\(versionDirs.count) 个版本目录，扫到 \(results.count) 个在册描述符。")
        return (results, nil)
    }

    /// 直读一个描述符目录，按 .tendies 目录结构（descriptors/<UUID>/…）
    /// 重打。逃逸通行证覆盖读取全程，读完才释放。
    static func exportDescriptor(_ entry: DirectDescriptor,
                                 log: @escaping (String) -> Void = { _ in }) throws -> InstalledWallpaperExporter.ExportResult {
        let fm = FileManager.default
        let escape = WorseQueryEscape.consume(target: entry.fullPath, requireWrite: false, log: log)
        guard let handle = escape.handle else {
            throw BackupError("直读导出没拿到通行证（\(escape.failReason ?? "原因见日志")）。")
        }
        defer { WorseQueryEscape.release(handle) }

        guard let enumerator = fm.enumerator(atPath: entry.fullPath) else {
            throw BackupError("直读导出：打不开这个描述符目录。")
        }
        var items: [(path: String, data: Data)] = []
        for case let sub as String in enumerator {
            let full = entry.fullPath + "/" + sub
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)) else {
                log("直读导出：读不了 \(sub)，跳过。")
                continue
            }
            items.append((path: "descriptors/\(entry.uuid)/" + sub, data: data))
        }
        guard !items.isEmpty else {
            throw BackupError("直读导出：这个描述符目录下读不到任何文件。")
        }
        let zip = ZipFoundationAdapter()
        let data = try zip.rebuild(entries: items)
        log("直读导出：\(entry.uuid) 共 \(items.count) 个文件，\(data.count) 字节。")
        return InstalledWallpaperExporter.ExportResult(
            descriptorUUID: entry.uuid,
            fileName: "wallpaper-\(String(entry.uuid.prefix(8))).tendies",
            data: data,
            fileCount: items.count)
    }

    /// 直读 providerInfo.plist 里的展示名，读不出返回 nil（和备份路径口径一致）。
    private static func readDescriptorName(at descriptorDir: String) -> String? {
        let url = URL(fileURLWithPath: descriptorDir + "/providerInfo.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        for key in ["displayName", "name"] {
            if let v = dict[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }
}
