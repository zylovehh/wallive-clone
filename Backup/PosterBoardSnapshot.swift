import Foundation
import SQLite3

/// 一份针对性备份也可能带上别的 App。只认真正的 PosterBoard 容器，
//  绝不按数据库的文件名去猜——那个名字也可能属于我们自己缓存的副本。
enum PosterBoardSnapshot {
    /// 把设备报上来的名字换算成容器里的相对路径。
    ///
    /// 设备会用两种名字报同一个文件：`AppDomain-com.apple.PosterBoard/…`
    /// 或 iOS 27 的原始路径树（`/.b/<n>/Containers/…`）。两种都认，
    /// 按 `container`（设备自己的容器路径）或 domain 前缀剥掉，
    /// 剩下的就是相对路径。认不出来的返回 nil。
    static func relativePath(deviceName: String, container: String) -> String? {
        func normalized(_ path: String) -> String {
            var value = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if value.hasPrefix("private/") { value.removeFirst("private/".count) }
            if value.hasPrefix("var/mobile/") { value.removeFirst("var/mobile/".count) }
            for prefix in [".b/", "b/"] where value.hasPrefix(prefix) {
                let rest = value.dropFirst(prefix.count)
                if let slash = rest.firstIndex(of: "/"), Int(rest[..<slash]) != nil {
                    value = String(rest[rest.index(after: slash)...])
                }
            }
            return value
        }
        let name = normalized(deviceName)
        let domainPrefix = PosterBoard.domain + "/"
        let root = normalized(container)
        let path: String
        if name.hasPrefix(domainPrefix) {
            path = String(name.dropFirst(domainPrefix.count))
        } else if !root.isEmpty, name.hasPrefix(root + "/") {
            path = String(name.dropFirst(root.count + 1))
        } else { return nil }
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return path
    }

    /// 一条相对路径里的商店版本号：`Library/Application Support/`
    /// `PRBPosterExtensionDataStore/<版本>/…/<数据库文件名>` 里的 `<版本>`。
    /// 五段、第三段是商店目录名、第五段是数据库文件名时才认。
    static func storeVersion(relativePath: String) -> Int? {
        let parts = relativePath.split(separator: "/")
        guard parts.count == 5, parts[0] == "Library", parts[1] == "Application Support",
              parts[2] == PosterBoard.storeDirectoryName,
              parts[4] == PosterBoard.databaseFileName, let version = Int(parts[3]), version > 0 else { return nil }
        return version
    }

    /// 是不是商店数据库本身（带 `-wal` / `-shm` 后缀也算）。
    static func isStoreFile(relativePath: String) -> Bool {
        var path = relativePath
        for suffix in ["-wal", "-shm"] where path.hasSuffix(suffix) { path.removeLast(suffix.count) }
        return storeVersion(relativePath: path) != nil
    }
}

// 一份备份容器是一张清单图，不只是一串常规文件。
// 设备的目录/符号链接记录和 MBFile 归档原样保留；
// 按文件路径重建会丢掉空的 provider 目录和元数据。
extension PosterBoardSnapshot {
    struct Record {
        let fileID: String
        let path: String
        let flags: Int32
        let blob: Data
        let source: URL?
    }

    /// 读一份备份里 PosterBoard domain 的所有记录。
    ///
    /// - 注意：打开时允许读写。设备上传的清单是 WAL 模式的，哪怕它的页
    ///   已经 checkpoint 过了；iOS 上的 SQLite 在读之前必须能初始化它
    ///   的 WAL/SHM bookkeeping。这是我们本地的工作备份，所以允许它做
    ///   这个恢复，但绝不因此凭空建一个没有的清单。
    static func records(in deviceDir: URL) throws -> [Record] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(deviceDir.appendingPathComponent("Manifest.db").path, &db,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no SQLite handle"
            sqlite3_close(db)
            throw BackupError("打不开 PosterBoard 快照的 Manifest.db：\(detail)。")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT fileID, relativePath, flags, file FROM Files WHERE domain = ? ORDER BY relativePath", -1, &stmt, nil) == SQLITE_OK else {
            let detail = String(cString: sqlite3_errmsg(db))
            throw BackupError("读不了 PosterBoard 快照的清单（SQLite \(sqlite3_extended_errcode(db))）：\(detail)。")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, PosterBoard.domain, -1, transient)
        var result: [Record] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let idText = sqlite3_column_text(stmt, 0),
                  let pathText = sqlite3_column_text(stmt, 1), let bytes = sqlite3_column_blob(stmt, 3) else {
                throw BackupError("PosterBoard 快照里有一行读不出来的文件记录。")
            }
            let id = String(cString: idText)
            let path = String(cString: pathText)
            let flags = sqlite3_column_int(stmt, 2)
            guard id.count == 40, id.allSatisfy(\.isHexDigit), [1, 2, 4].contains(flags),
                  path.isEmpty || relativePath(deviceName: PosterBoard.domain + "/" + path, container: "") == path else {
                throw BackupError("PosterBoard 快照里有非法的路径或文件类型。")
            }
            var source: URL?
            if flags == 1 {
                let candidates = [deviceDir.appendingPathComponent("\(id.prefix(2))/\(id)"),
                                  deviceDir.appendingPathComponent(id)]
                source = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
                guard source != nil else {
                    throw BackupError("PosterBoard 快照不完整：缺了 \(path)。还原已停，保护设备上现有的壁纸。")
                }
            }
            result.append(Record(fileID: id, path: path, flags: flags,
                                 blob: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 3))), source: source))
        }
        guard result.contains(where: { storeVersion(relativePath: $0.path) != nil && $0.flags == 1 }) else {
            throw BackupError("PosterBoard 快照里没有 live 数据库。")
        }
        return result
    }

    /// 把第一次完整的 apply 前容器单独留一份，不依赖取表用的临时空间。
    /// 之后重试不能把唯一的恢复副本擦掉。
    static func retainBaseline(from sourceDir: URL, at destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".snapshot-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var db: OpaquePointer?
        guard sqlite3_open(staging.appendingPathComponent("Manifest.db").path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw BackupError("准备 PosterBoard 恢复快照失败。")
        }
        let status = sqlite3_exec(db, "CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB)", nil, nil, nil)
        sqlite3_close(db)
        guard status == SQLITE_OK else { throw BackupError("建 PosterBoard 恢复清单失败。") }
        _ = try merge(from: sourceDir, into: staging)
        try fm.moveItem(at: staging, to: destination)
    }

    /// 保护性剪裁之后，快照里原生 domain 的记录导进还原备份。
    struct RestoredSnapshot {
        /// 还原实际会带上的目录行，键是 `domain/relativePath`；
        /// `BackupInjector` 会跳过合成这些。
        let directories: Set<String>
        /// 原生文件行，键一样；同路径替换时拿来当元数据供体。
        let fileMetadata: [String: Data]
        /// 还原实际会带上的常规文件。`delivering` 有值时只是增量，
        /// 不是整个取回的容器。
        let delivered: Int
    }

    /// 把快照的记录导进还原备份。
    ///
    /// - Parameter delivering: 有值时，只拷键在里面的常规文件并给行。
    ///   快照里其余的文件不动，每个目录也一样——目录记录本身不是免费的。
    ///   还原代理把一条目录行当成"放下这个目录"的指令，所以给一个装满了
    ///   清单没带的文件的目录写记录，就是商店丢壁纸配置的原因：设备重建
    ///   了父目录，内容（只在那里有）留在了后面
    ///   （见 `docs/posterboard-rewrite-2026-10-21.md`）。只导要送的文件
    ///   的祖先目录，增量自己的父目录才是原生的。
    ///
    ///   apply 把这次的增量传进来，因为其余容器重写一遍是这款 App
    ///   绝不能做的。那些文件设备上已经有了，一个字节不差；还原时再导
    ///   一遍什么都买不到，只会把 live 商店的整棵树交给还原代理重建。
    ///   参考实现就是只还原增量，这里也一样。
    ///
    ///   `nil` 就是全导，恢复基线要的就是这个：恢复副本不完整就没有意义。
    static func merge(from sourceDir: URL, into targetDir: URL,
                      delivering: Set<String>? = nil) throws -> RestoredSnapshot {
        let rows = try records(in: sourceDir) // 改动之前先校验所有载荷
        let fm = FileManager.default
        let domainPrefix = PosterBoard.domain + "/"
        // 这次导入允许放的目录行：domain 根和每个要送的文件的祖先，
        // 再多没有。`nil` 是"整棵树"，恢复基线用的就是这个。
        var neededDirectories: Set<String>?
        if let delivering {
            var needed: Set<String> = [""]
            for key in delivering where key.hasPrefix(domainPrefix) {
                var accumulated = ""
                for component in key.dropFirst(domainPrefix.count).split(separator: "/").dropLast() {
                    accumulated = accumulated.isEmpty ? String(component) : "\(accumulated)/\(component)"
                    needed.insert(accumulated)
                }
            }
            neededDirectories = needed
        }
        var delivered = 0
        for row in rows {
            guard let source = row.source else { continue }
            if let delivering, !delivering.contains(domainPrefix + row.path) { continue }
            let target = targetDir.appendingPathComponent("\(row.fileID.prefix(2))/\(row.fileID)")
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: source, options: .mappedIfSafe).write(to: target, options: .atomic)
            delivered += 1
        }
        var db: OpaquePointer?
        guard sqlite3_open(targetDir.appendingPathComponent("Manifest.db").path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw BackupError("打不开还原用的 PosterBoard 清单。")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw BackupError("开始 PosterBoard 快照合并失败。")
        }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO Files (fileID, domain, relativePath, flags, file) VALUES (?, ?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else {
            throw BackupError("准备 PosterBoard 清单合并失败。")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var importedDirectories: Set<String> = []
        for row in rows {
            // 没有载荷的文件行到还原时会是 MBErrorDomain/205，
            // 所以这次导入故意留下的文件一定不能给行。目录和符号链接
            // 按定义没有载荷，但放下一个目录本身就是设备会执行的写操作——
            // 见上面 `delivering` 的说明——所以增量不需要的目录也留下来。
            if row.flags != 1, let neededDirectories,
               !neededDirectories.contains(row.path) { continue }
            if row.flags == 1, let delivering,
               !delivering.contains(domainPrefix + row.path) { continue }
            if row.flags == 2 { importedDirectories.insert(PosterBoard.domain + "/" + row.path) }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, row.fileID, -1, transient)
            sqlite3_bind_text(stmt, 2, PosterBoard.domain, -1, transient)
            sqlite3_bind_text(stmt, 3, row.path, -1, transient)
            sqlite3_bind_int(stmt, 4, row.flags)
            _ = row.blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 5, $0.baseAddress, Int32($0.count), transient) }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw BackupError("保留 PosterBoard 清单条目 \(row.path) 失败。")
            }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw BackupError("提交 PosterBoard 快照合并失败。")
        }
        committed = true
        return RestoredSnapshot(
            directories: importedDirectories,
            fileMetadata: Dictionary(uniqueKeysWithValues: rows.filter { $0.flags == 1 }
                .map { (PosterBoard.domain + "/" + $0.path, $0.blob) }),
            delivered: delivered)
    }
}
