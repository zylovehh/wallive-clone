import Foundation
import UIKit

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
        /// 扩展标识（如 com.apple.ClockPoster…），系统壁纸翻成人话名字用；读不到为 nil。
        let extensionID: String?
        /// 尽力而为的显示名（来自 providerInfo.plist），读不到为 nil。
        let name: String?
        /// providerInfo 的 role 标明是环境类壁纸（如世界时钟）时为 true，
        /// 这类壁纸容器里本来就没有独立媒体，界面上单独标「系统」。
        let isAmbient: Bool
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
        var metas: [String: (name: String?, isAmbient: Bool, extensionID: String?)] = [:]
        for row in rows {
            guard let uuid = descriptorUUID(of: row.relativePath) else { continue }
            if !order.contains(uuid) { order.append(uuid) }
            if row.relativePath.lowercased().hasSuffix("descriptors/\(uuid)/providerinfo.plist"),
               let url = row.payload, metas[uuid] == nil {
                let meta = providerInfoMeta(url: url)
                metas[uuid] = (meta.name, meta.isAmbient, extensionID(of: row.relativePath))
            }
        }
        return order.map { DescriptorInfo(uuid: $0, extensionID: metas[$0]?.extensionID,
                                          name: metas[$0]?.name, isAmbient: metas[$0]?.isAmbient ?? false) }
    }

    /// 重打指定描述符的 .tendies（明文 zip，调用方按需再加密）。
    ///
    /// V1.8 同口径修：不只查 descriptors 段——媒体可能以 UUID 命名放在
    /// 扩展目录其他位置；打完包先验，没有壁纸内容就报错，别静默出一个
    /// 只有描述符、装不了的空包（和直读路径一致）。
    static func exportWallpaper(descriptorUUID: String, backupDir: URL,
                                log: BackupLog = { _ in }) throws -> ExportResult {
        let manifest = ManifestStore(deviceDir: backupDir)
        let rows = try manifest.rows(relativePathLike: "%\(descriptorUUID)%")
            .filter { $0.payload != nil }
        guard !rows.isEmpty else {
            throw BackupError("备份里没找到 \(descriptorUUID) 的载荷文件，可能尚未安装或已被清理。")
        }

        let zip = ZipFoundationAdapter()
        var entries: [(path: String, data: Data)] = []
        var outsideCount = 0
        for row in rows {
            guard let data = try? Data(contentsOf: row.payload!) else { continue }
            if let pkgPath = packagePath(of: row.relativePath) {
                entries.append((path: pkgPath, data: data))
            } else if let mediaPath = mediaPackagePath(of: row.relativePath, uuid: descriptorUUID) {
                // 描述符之外的媒体：按扩展根下的相对结构进包。
                entries.append((path: mediaPath, data: data))
                outsideCount += 1
            }
        }
        if outsideCount > 0 {
            log("export: 发现 \(outsideCount) 个描述符目录之外的关联文件，已按扩展根相对路径并入包。")
        }
        guard !entries.isEmpty else {
            throw BackupError("载荷文件都读不出来，导出失败。")
        }
        // 验包：必须有壁纸内容，没有就别出空包。
        guard entries.contains(where: { $0.path.hasSuffix(".wallpaper/Wallpaper.plist") }) else {
            throw BackupError("这个描述符下没有壁纸内容（可能是系统自带的环境壁纸），导出的包只有描述符、装不了。")
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

    /// 描述符之外的媒体路径：`…/Extensions/<ext>/Assets/<UUID>/x` →
    /// `Assets/<UUID>/x`（从 UUID 所在段的上一级起取相对路径）。
    /// UUID 不作为独立路径段出现的行不进包，避免误收同名巧合文件。
    private static func mediaPackagePath(of relativePath: String, uuid: String) -> String? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let idx = parts.firstIndex(of: uuid), idx > 0 else { return nil }
        return parts[(idx - 1)...].joined(separator: "/")
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

    /// 从 relativePath 里抠出扩展标识（Extensions/ 后面那一段）。
    fileprivate static func extensionID(of relativePath: String) -> String? {
        guard let range = relativePath.range(of: "Extensions/") else { return nil }
        let rest = relativePath[range.upperBound...]
        let first = rest.split(separator: "/").first.map(String.init) ?? ""
        return first.isEmpty ? nil : first
    }

    /// 尽力而为：从 providerInfo.plist 读展示名和环境类角色，读不到给默认值。
    fileprivate static func providerInfoMeta(url: URL) -> (name: String?, isAmbient: Bool) {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return (nil, false) }
        var name: String?
        for key in ["displayName", "name"] {
            if let v = dict[key] as? String, !v.isEmpty { name = v; break }
        }
        var isAmbient = false
        if let role = dict["role"] as? String, role.contains("Ambient") { isAmbient = true }
        return (name, isAmbient)
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
        /// providerInfo 的 role 标明是环境类壁纸时为 true（如世界时钟）。
        let isAmbient: Bool
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
                    let meta = readDescriptorMeta(at: full)
                    results.append(DirectDescriptor(uuid: d, extensionID: ext,
                                                    structureVersion: v, fullPath: full,
                                                    name: meta.name, isAmbient: meta.isAmbient))
                }
            }
        }
        log("直读扫商店：\(versionDirs.count) 个版本目录，扫到 \(results.count) 个在册描述符。")
        return (results, nil)
    }

    /// 直读一个描述符目录，按 .tendies 目录结构（descriptors/<UUID>/…）
    /// 重打。逃逸通行证覆盖读取全程，读完才释放。
    /// V1.8 修：只读描述符目录不够。Wallive 装的壁纸内容可能不在描述符目录里，
    /// 而是放在扩展目录下同名的 <UUID>.wallpaper/ 文件夹里，所以两个地方都翻，
    /// 通行证也改吃扩展目录（两级都盖住）。打完包先验：包里必须有
    /// .wallpaper/Wallpaper.plist，没有就报错，别静悄悄出一个只有描述符、
    /// 装不了的 3KB 空包（V1.7 的毛病）。
    static func exportDescriptor(_ entry: DirectDescriptor,
                                 log: @escaping (String) -> Void = { _ in }) throws -> InstalledWallpaperExporter.ExportResult {
        let fm = FileManager.default
        // 扩展目录：…/Extensions/<ext>（描述符目录往上两级），通行证吃这里，
        // 描述符目录和同名 .wallpaper 文件夹都在它下面，都盖得住。
        let extDir = ((entry.fullPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let escape = WorseQueryEscape.consume(target: extDir, requireWrite: false, log: log)
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
        // 内容可能在扩展目录下同名的 <UUID>.wallpaper/ 里（不在描述符目录内），
        // 翻出来一起打进包：包内按标准位置放
        // descriptors/<UUID>/versions/1/contents/<UUID>.wallpaper/。
        let siblingWallpaper = extDir + "/" + entry.uuid + ".wallpaper"
        var sibIsDir: ObjCBool = false
        if fm.fileExists(atPath: siblingWallpaper, isDirectory: &sibIsDir), sibIsDir.boolValue,
           let sibEnum = fm.enumerator(atPath: siblingWallpaper) {
            for case let sub as String in sibEnum {
                let full = siblingWallpaper + "/" + sub
                var subIsDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &subIsDir), subIsDir.boolValue { continue }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)) else {
                    log("直读导出：读不了 \(entry.uuid).wallpaper/\(sub)，跳过。")
                    continue
                }
                items.append((path: "descriptors/\(entry.uuid)/versions/1/contents/\(entry.uuid).wallpaper/" + sub, data: data))
            }
            log("直读导出：在扩展目录下找到同名内容文件夹 \(entry.uuid).wallpaper，已并进包。")
        }
        guard !items.isEmpty else {
            throw BackupError("直读导出：这个描述符目录下读不到任何文件。")
        }
        // 验包：必须有壁纸内容，没有就别出空包。
        guard items.contains(where: { $0.path.hasSuffix(".wallpaper/Wallpaper.plist") }) else {
            throw BackupError("这个描述符下没有壁纸内容（可能是系统自带壁纸），导出的包只有描述符、装不了。")
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

    /// 直读一张封面：从描述符目录 + 扩展目录下同名 .wallpaper 文件夹里挑一张图，
    /// 压成小图（最长边 240）当封面，只用于列表识别。系统自带的没有独立媒体，
    /// 调用方跳过这类条目、只给名字不给封面。
    static func coverData(for entry: DirectDescriptor,
                          log: @escaping (String) -> Void = { _ in }) -> Data? {
        let fm = FileManager.default
        // 扩展目录：…/Extensions/<ext>（描述符目录往上两级），通行证吃这里。
        let extDir = ((entry.fullPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let escape = WorseQueryEscape.consume(target: extDir, requireWrite: false, log: log)
        guard let handle = escape.handle else { return nil }
        defer { WorseQueryEscape.release(handle) }

        // 收集图片：优先路径里带 background 的背景图，没有就挑文件最大的。
        let imageExts = ["png", "jpg", "jpeg", "heic", "heif", "webp"]
        var candidates: [(path: String, size: Int)] = []
        func collect(dir: String) {
            guard let enumerator = fm.enumerator(atPath: dir) else { return }
            for case let sub as String in enumerator {
                guard imageExts.contains((sub as NSString).pathExtension.lowercased()) else { continue }
                let full = dir + "/" + sub
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue,
                      let size = try? fm.attributesOfItem(atPath: full)[.size] as? Int else { continue }
                candidates.append((full, size))
            }
        }
        collect(dir: entry.fullPath)
        let siblingWallpaper = extDir + "/" + entry.uuid + ".wallpaper"
        var sibIsDir: ObjCBool = false
        if fm.fileExists(atPath: siblingWallpaper, isDirectory: &sibIsDir), sibIsDir.boolValue {
            collect(dir: siblingWallpaper)
        }
        let best = candidates.first { $0.path.lowercased().contains("background") }
            ?? candidates.max { $0.size < $1.size }
        guard let best,
              let data = try? Data(contentsOf: URL(fileURLWithPath: best.path)),
              let image = UIImage(data: data) else { return nil }
        // 压成小图：最长边 240，JPEG 0.8，列表里只存小图。
        let maxSide: CGFloat = 240
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxSide / max(longest, 1))
        let scaled = UIGraphicsImageRenderer(
            size: CGSize(width: image.size.width * scale, height: image.size.height * scale)
        ).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale))
        }
        return scaled.jpegData(compressionQuality: 0.8)
    }

    /// 直读 providerInfo.plist 里的展示名和环境类角色（与备份路径口径一致）。
    private static func readDescriptorMeta(at descriptorDir: String) -> (name: String?, isAmbient: Bool) {
        InstalledWallpaperExporter.providerInfoMeta(url: URL(fileURLWithPath: descriptorDir + "/providerInfo.plist"))
    }
}
