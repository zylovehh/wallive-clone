import Foundation

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
