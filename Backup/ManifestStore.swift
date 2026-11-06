import CryptoKit
import Foundation
import SQLite3

/// 备份 3.3 的清单结构，只定一次。
///
/// 以前是四处各写一份：`pruneManifestDb`、没用上的 `createEmptyManifestDb`、
/// `ingestFileRow`，还有死掉的 `Backup.generateManifestSQLite`，其中两份
/// 还各自重写了一遍 fileID 的规则。一份清单在两份拷贝之间悄悄走样，
/// 设备那边校验失败时连个声都没有，所以现在只有这一个定义。
enum ManifestSchema {
    /// SQLite 的析构哨兵值，表示"现在就拷一份这个 buffer"。
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static let insertOrReplaceRow =
        "INSERT OR REPLACE INTO Files (fileID, domain, relativePath, flags, file) VALUES (?, ?, ?, ?, ?)"
}

/// 一份备份的 `Manifest.db` 的唯一入口。
///
/// 清单的每次改动——按磁盘现状剪裁、插一个注入文件的行——都走这里。
/// 别处不再直接打开这个数据库，正因为 fileID 的规则和结构
/// 检查集中在一处才查得动。
struct ManifestStore: Sendable {
    /// `<backupRoot>/<udid>/`——放着 Manifest.db 和分片文件的目录。
    let deviceDir: URL
    /// 诊断日志。调用方传进来（安装页的日志）；不传就不写。
    let log: BackupLog

    init(deviceDir: URL, log: BackupLog = { _ in }) {
        self.deviceDir = deviceDir
        self.log = log
    }

    var dbPath: String {
        deviceDir.appendingPathComponent("Manifest.db").path
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    /// `Files` 表的行数。
    ///
    /// 数据库不在、或是宿主写的占位文件（没有 `Files` 表）时返回 0 而不是
    /// 抛错——调用方是在问"有没有值得保留或播种的东西"，"没有"本身
    /// 就是一个合法的 0。
    func rowCount() -> Int {
        guard let db = try? open() else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM Files", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// 删掉一个 domain 的所有行，返回删了多少。
    ///
    /// 用于给*合并式*拉取播种一份保留的清单：那种方式取回的容器，
    /// 行会被剪掉、载荷会在每次运行结束时当孤儿清掉，而保留的清单
    /// 还列着它们。把行删了就是告诉设备"这些文件我不认识"，
    /// 设备会重新上传，而不是回一句"没变，不用发"。
    func dropRows(domain: String) -> Int {
        guard let db = try? open() else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM Files WHERE domain = ?", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        sqlite3_bind_text(stmt, 1, domain, -1, ManifestSchema.transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// 一行清单的 fileID：`sha1("<domain>-<relativePath>")` 的十六进制。
    ///
    /// 注意是**短横**，不是斜杠。
    /// 这是数据库和载荷树之间的连接点——一行的载荷在
    /// `<deviceDir>/<fileID 前 2 字符>/<fileID>`——所以每个地方算出来
    /// 必须一字节不差。以前它存在两份（一份在死掉的 `BackupFile` 类上，
    /// 一份是这里的文件内函数）。
    static func fileID(domain: String, relativePath: String) -> String {
        sha1Hex("\(domain)-\(relativePath)")
    }

    /// 一行的载荷路径，就是设备认的那种分片布局。
    func payloadURL(forFileID fileID: String) -> URL {
        deviceDir.appendingPathComponent(String(fileID.prefix(2)), isDirectory: true)
            .appendingPathComponent(fileID)
    }

    /// SHA-1 的小写十六进制。
    static func sha1Hex(_ value: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    // MARK: - 打开

    /// 打开清单；文件不在就抛错。
    private func open() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else {
            throw BackupError("打不开 Manifest.db：\(dbPath)")
        }
        return db
    }

    // MARK: - 写行

    /// 插入（或替换）一行。
    func upsert(fileID: String, domain: String, relativePath: String,
                flags: Int32, blob: Data) throws {
        let db = try open()
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, ManifestSchema.insertOrReplaceRow, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw BackupError("Manifest.db：给 \(domain)/\(relativePath) 写行时准备 INSERT 失败")
        }
        defer { sqlite3_finalize(stmt) }

        fileID.withCString { cID in
            domain.withCString { cDom in
                relativePath.withCString { cRel in
                    sqlite3_bind_text(stmt, 1, cID, -1, ManifestSchema.transient)
                    sqlite3_bind_text(stmt, 2, cDom, -1, ManifestSchema.transient)
                    sqlite3_bind_text(stmt, 3, cRel, -1, ManifestSchema.transient)
                    sqlite3_bind_int(stmt, 4, flags)
                    _ = blob.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(blob.count),
                                          ManifestSchema.transient)
                    }
                }
            }
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw BackupError("Manifest.db：给 \(domain)/\(relativePath) 写行失败，SQLite 代码 \(rc)")
        }
    }

    // MARK: - 读行

    /// 清单的一行，供需要在一份备份里找文件的调用方用。
    struct Row: Sendable {
        let fileID: String
        let domain: String
        let relativePath: String
        /// 载荷在哪——磁盘上没有时是 nil；这种状态设备会回
        /// `MBErrorDomain/205`。
        let payload: URL?
    }

    /// 这份清单实际有的表。
    ///
    /// 放在这里是因为 `Manifest.db` 这个文件**不总是**读者以为的那个结构。
    /// iOS 27 上*宿主*写的是 libimobiledevice 形状的占位文件
    /// （`ManifestEntry` + `Properties`，见 `HostManifests.writeSQLiteManifest`），
    /// 设备自己的 `Files` 形状数据库只有在设备上传了它时才会替换掉占位文件。
    /// 一个只会报 "no such table: Files" 的读者，除了这个什么都不说，
    /// 操作者就猜不到自己手里是哪一个——`PosterBoardBackup` 第一次跑起来
    /// 时就是这么回事。
    var tableNames: [String] {
        guard let db = try? open() else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table'",
                                 -1, &stmt, nil) == SQLITE_OK else { return [] }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) { names.append(String(cString: text)) }
        }
        return names.sorted()
    }

    /// `relativePath` 符合 SQL `LIKE` 模板的行，路径最长的在前。
    ///
    /// 最长的在前，是因为参照实现解析 PosterBoard 商店时取的是匹配到的
    /// 最高那条路径：商店目录带一个数字结构版本，设备万一有不止一个
    /// 布局时，按路径排就是取最新的那一个。
    func rows(relativePathLike pattern: String) throws -> [Row] {
        let db = try open()
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT fileID, domain, relativePath FROM Files "
                                     + "WHERE relativePath LIKE ? ORDER BY relativePath DESC",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw BackupError("Manifest.db 里没有能读的 Files 表（现有的表："
                + "\(tableNames.isEmpty ? "没有" : tableNames.joined(separator: ", "))）。"
                + "这说明手里是宿主写的占位文件，不是设备上传的数据库。")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pattern, -1, ManifestSchema.transient)

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let domainText = sqlite3_column_text(stmt, 1),
                  let pathText = sqlite3_column_text(stmt, 2) else { continue }
            let fileID = String(cString: idText)
            let url = payloadURL(forFileID: fileID)
            rows.append(Row(fileID: fileID,
                            domain: String(cString: domainText),
                            relativePath: String(cString: pathText),
                            payload: FileManager.default.fileExists(atPath: url.path) ? url : nil))
        }
        return rows
    }

    /// 这份备份里的所有载荷，不管清单怎么说。
    ///
    /// 两种布局都算，因为两种清单格式放载荷的方式不同：sqlite 那种
    /// （iOS 27）用 `fileID` 分片树——`<deviceDir>/<fileID 前 2 字符>/<fileID>`——
    /// 而老 MBDB 那种（iOS 26）把载荷平铺在 `deviceDir` 里。
    /// 一份*筛过*的备份还可能留着清单已经不管的载荷，清单本身也可能
    /// 是宿主的占位文件，所以这份才是所有情况下都站得住的清单。
    ///
    /// 宿主写的三个元数据文件跳过：它们和载荷在同一个目录里，
    /// 但不是载荷。
    func payloadFiles() -> [URL] {
        let fm = FileManager.default
        let metadata = Set(["Info.plist", "Manifest.plist", "Manifest.db", "Manifest.db-shm",
                            "Manifest.db-wal", "Status.plist", "Manifest.mbdb"])
        guard let entries = try? fm.contentsOfDirectory(at: deviceDir,
                                                        includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var files: [URL] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if entry.hasDirectoryPath {
                if name.count == 2 {
                    let contents = (try? fm.contentsOfDirectory(
                        at: entry, includingPropertiesForKeys: nil)) ?? []
                    files.append(contentsOf: contents.filter { !$0.hasDirectoryPath })
                }
            } else if !metadata.contains(name) {
                files.append(entry)
            }
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - 剪裁
    /// `pruneToDiskState()` 干了什么，供日志和想对缺口作出反应的调用方看。
    struct PruneReport: Sendable {
        /// 重写之前表里的总行数。
        let rows: Int
        /// keep 集点名了、并且有载荷（或不需要载荷）的行。
        let kept: Int
        /// keep 集点名了、但磁盘上没有载荷的行。删掉，和 GoldenNugget
        /// 一样——没有载荷的文件行，正是设备报 `MBErrorDomain/205` 的东西。
        let missingPayloads: Int
        let orphansRemoved: Int
        /// 留下的行的 flags 直方图，比如 `1×471 2×16695`。
        /// `flags` 是设备从中读"文件类型"的值，所以留下了什么和删了什么
        /// 一样重要。
        let keptFlags: String

        /// 完全在 keep 集之外的行。
        var outsideKeepSet: Int { rows - kept - missingPayloads }

        var logLine: String {
            var line = "剪裁 Manifest.db：\(rows) 行里留了 \(kept) 行"
                + "（\(missingPayloads) 行被 keep 集点名但磁盘上没有载荷，"
                + "\(outsideKeepSet) 行在 keep 集之外），"
                + "清掉 \(orphansRemoved) 个孤儿载荷文件。"
            line += " 留下的行按 flags 分：\(keptFlags)。"
            if missingPayloads > 0 {
                line += " 没有载荷的行，设备会报 MBErrorDomain/205。"
            }
            return line
        }
    }

    /// 就地剪裁清单：删掉磁盘上没有对应文件的行，清掉孤儿载荷文件，
    /// 清掉空的分片目录。
    ///
    /// 这是"筛过的备份"约定的后一半。设备会把每个上传过的载荷都记在
    /// 它发来的 Manifest.db 里——包括宿主筛掉的那些——而 GoldenNugget
    /// 的 mobilebackup2 代理在备份交换期间会给每个筛掉的文件在磁盘上
    /// 留一个 0 字节的占位，交换结束后再清掉（见
    /// `MobileBackup2BackupContext.cleanupPlaceholders`）。
    /// **我们 Rust 这边筛掉的文件直接不写盘，不留占位**，所以占位清完
    /// 之后，那些行正好就是"载荷不在磁盘上"的集合，剪裁时删掉它们，
    /// 清单和文件树就又对上了，还原之前不会再有分歧。
    ///
    /// - Parameter keeping: 哪些行要留，`(domain, relativePath) -> Bool`。
    ///   原版在这里调的是 GoldenNugget 保护性备份自己的 keep 集
    ///   （`ProtectiveBackup.keepsRow`，只留它那几个 domain）；我们这边
    ///   只备 PosterBoard 一个容器，调用方传自己的谓词（一般是
    ///   "domain 是 PosterBoard 就留"），不要把 GoldenNugget 的整套
    ///   保护性备份规则搬过来。
    /// - Returns: 没有 Manifest.db 可剪时是 nil。
    @discardableResult
    func pruneToDiskState(keeping: (String, String) -> Bool) -> PruneReport? {
        guard exists else {
            log("剪裁 Manifest.db：\(dbPath) 不存在，跳过")
            return nil
        }
        guard let db = try? open() else {
            log("剪裁 Manifest.db：打不开 \(dbPath)，跳过")
            return nil
        }
        defer { sqlite3_close(db) }

        // 任何一步失败就整个回滚：剪了一半的清单比没剪的更糟，因为
        // 设备会看到载荷已经没了的行（MBErrorDomain/205），
        // 却没法知道是哪一步失败造成的。
        var stmt: OpaquePointer?
        var keepIDs: [String] = []
        var rowCount = 0
        var payloadLess = 0
        var payloadLessSample: [String] = []
        var keptFlags: [Int32: Int] = [:]

        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            log("剪裁 Manifest.db：开不了事务，跳过")
            return nil
        }
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                log("剪裁 Manifest.db：已回滚，清单原样未动")
            }
        }

        // 第一阶段：把 keep 集用到每一行。
        //
        // keep 集是 GoldenNugget 在 `(domain, relativePath)` 上的谓词——
        // 见 `ProtectiveBackup.keepsRow`。它以前是"载荷在磁盘上存在"，
        // 回答的是*另一个*问题：只要有东西上传过，它就把 keep 集排除
        // 的行也留下来，同时又把符号链接行（载荷本来就不存在）删掉。
        // 参照实现按谓词解决这两个问题，这里也一样。
        if sqlite3_prepare_v2(db, "SELECT fileID, domain, relativePath, flags FROM Files",
                              -1, &stmt, nil) == SQLITE_OK, let stmt {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cID = sqlite3_column_text(stmt, 0) else { continue }
                rowCount += 1
                let fileID = String(cString: cID)
                let domain = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let relPath = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let flags = sqlite3_column_int(stmt, 3)

                guard keeping(domain, relPath) else {
                    continue
                }

                // 只有常规文件才有 `<aa>/<fileID>` 载荷，所以只有它们要过
                // 载荷测试。GoldenNugget 的规则写的是 `flags == 1 and not
                // payload_exists`，它*没*点名的 flags 才是原因：目录行（2）
                // 没有载荷也必须活下来——"删了它们，还原代理会报
                // renameatx ENOENT"——符号链接行（4）按定义就没有载荷，
                // 同样必须活下来。
                if flags == 1,
                   !FileManager.default.fileExists(atPath: payloadURL(forFileID: fileID).path) {
                    payloadLess += 1
                    if payloadLessSample.count < 5 {
                        payloadLessSample.append("\(domain)/\(relPath)")
                    }
                    continue
                }
                keepIDs.append(fileID)
                keptFlags[flags, default: 0] += 1
            }
        }

        if payloadLess > 0 {
            log("剪裁：删掉 \(payloadLess) 行——keep 集点名了但磁盘上没有载荷"
                + "（比如 \(payloadLessSample.joined(separator: ", "))）——没有载荷"
                + "的文件行正是设备报 MBErrorDomain/205 的东西")
        }

        // 第二阶段：按 keep 集重写表。
        guard sqlite3_exec(db,
                           "CREATE TEMP TABLE IF NOT EXISTS _keep (fileID TEXT)",
                           nil, nil, nil) == SQLITE_OK else {
            log("剪裁 Manifest.db：建不了 keep 临时表，跳过")
            return nil
        }

        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO _keep (fileID) VALUES (?)", -1, &insert, nil) == SQLITE_OK,
              let insert else {
            log("剪裁 Manifest.db：准备不了 keep 插入语句，跳过")
            return nil
        }
        // 只准备一次，在循环外面：原来每个留下的行都重新准备一次语句，
        // 筛过一整台设备的备份时等于每个文件都完整编译一次 INSERT
        // （几万行）。
        for fid in keepIDs {
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            _ = fid.withCString { sqlite3_bind_text(insert, 1, $0, -1, ManifestSchema.transient) }
            sqlite3_step(insert)
        }
        sqlite3_finalize(insert)

        guard sqlite3_exec(db, "DELETE FROM Files WHERE fileID NOT IN (SELECT fileID FROM _keep)",
                           nil, nil, nil) == SQLITE_OK else {
            log("剪裁 Manifest.db：重写行失败，跳过")
            return nil
        }
        sqlite3_exec(db, "DROP TABLE _keep", nil, nil, nil)

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            log("剪裁 Manifest.db：提交失败，跳过")
            return nil
        }
        committed = true

        let orphansRemoved = removeOrphanPayloads(keepIDs: Set(keepIDs))

        let histogram = keptFlags.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        let report = PruneReport(rows: rowCount, kept: keepIDs.count,
                                 missingPayloads: payloadLess,
                                 orphansRemoved: orphansRemoved,
                                 keptFlags: histogram.isEmpty ? "(none)" : histogram)
        log(report.logLine)
        return report
    }

    /// 一句话说清楚宿主要交给设备的到底是什么。
    ///
    /// 设备按 `Manifest.db` 说的还原，清单和文件树对不上就失败
    /// （"Manifest references files not in backup"），但宿主自己从来
    /// 没有一张总表——细节散在剪裁、注入和占位那几行日志里，每处数的
    /// 都不一样。这就是那张总表，在还原之前立刻取一次。
    ///
    /// `missingPayloads` 是要紧的那个数。非零就是宿主把没有办法兑现
    /// 的行递给了设备，也就是一次"还没开始就注定半截"还原的宿主侧形状：
    /// 设备规划了永远拿不到字节的工作。目录行（`flags == 2`）**和**
    /// 符号链接行（`flags == 4`）按定义就没有载荷，单独计数，
    /// 这样它们既不会掩盖真正的缺口，也不会*看起来*像缺口。
    ///
    /// 符号链接那一半不是装饰：`pruneToDiskState` 故意让 `flags == 4`
    /// 的行没载荷也留下来（和 GoldenNugget 一致），所以把它们算成缺失
    /// 会让这行话在一份完全一致的备份上也报 `INCONSISTENT`。
    /// 2026-09-21 那次跑出来的 "2 个缺载荷"，两个都是活下来的符号链接行
    /// （比如 `ba6b3d08…` = `HomeDomain/Library/Shortcuts/ToolKit/Tools-active`，
    /// 设备自己的清单里 `flags = 4`）。一个永远是红色的结论等于没有信号。
    func auditAgainstDisk() -> String {
        guard exists, let db = try? open() else {
            return "还原前自查：\(dbPath) 没有能读的 Manifest.db"
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        // `file IS NULL OR length(file) = 0` 是设备能从中读出"类型"的
        // 第三样东西：一行 blob 是空的，就完全没有 `Mode`。
        guard sqlite3_prepare_v2(
            db, "SELECT fileID, flags, (file IS NULL OR length(file) = 0), file FROM Files",
            -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return "还原前自查：读不了 Manifest.db"
        }
        defer { sqlite3_finalize(stmt) }

        var fileRows = 0
        var dirRows = 0
        var symlinkRows = 0
        var missingPayloads = 0
        var bloblessRows = 0
        var unreadableModes = 0
        var firstMissing: String?
        var firstBlobless: String?
        var firstUnreadable: String?
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cID = sqlite3_column_text(stmt, 0) else { continue }
            let fileID = String(cString: cID)
            let flags = sqlite3_column_int(stmt, 1)
            if sqlite3_column_int(stmt, 2) != 0 {
                bloblessRows += 1
                if firstBlobless == nil { firstBlobless = fileID }
                continue
            }
            let count = sqlite3_column_bytes(stmt, 3)
            guard count > 0, let raw = sqlite3_column_blob(stmt, 3) else { continue }
            // 设备能读出"类型"的第四样东西，也是真正咬过人的那一个：
            // `Mode` 是对象引用而不是内联数字时，设备 `decodeInteger`
            // 那家人读到会抛，于是回 "Invalid file type: 00"。
            // 在这里查，日志里就能点名，而不是留一个 205 让人猜。
            if mbFileBlobMode(Data(bytes: raw, count: Int(count))) == nil {
                unreadableModes += 1
                if firstUnreadable == nil { firstUnreadable = fileID }
            }
            if flags == 2 {
                dirRows += 1
                continue
            }
            if flags == 4 {
                symlinkRows += 1
                continue
            }
            fileRows += 1
            if !FileManager.default.fileExists(atPath: payloadURL(forFileID: fileID).path) {
                missingPayloads += 1
                if firstMissing == nil { firstMissing = fileID }
            }
        }

        // 两半都报：有载荷没 blob 的行，和反过来一样没法给设备用，
        // 以前只数了载荷那一半。
        let verdict = (missingPayloads == 0 && bloblessRows == 0 && unreadableModes == 0)
            ? "一致"
            : "不一致——设备还原不了这些行"
        var line = "还原前自查：\(fileRows) 个文件行，\(dirRows) 个目录行，"
            + "\(symlinkRows) 个符号链接行，\(missingPayloads) 个缺载荷，"
            + "\(bloblessRows) 个 blob 是空的，\(unreadableModes) 个 Mode 读不出来"
            + "——\(verdict)"
        if let firstMissing { line += "（第一个缺载荷的：\(firstMissing)）" }
        if let firstBlobless { line += "（第一个没 blob 的：\(firstBlobless)）" }
        if let firstUnreadable { line += "（第一个 Mode 读不出来的：\(firstUnreadable)）" }
        return line
    }

    /// 我们注入那行的 `MBFile` 形状，和设备自己的并排放。
    ///
    /// `MBErrorDomain/205 — "Invalid file type: 00"`（2026-09-20）是在
    /// 设备拉了 471 个载荷里的 7 个之后回来的。`205` 是一类错，
    /// 不是原因，描述是唯一的区分线索——"file type"指向设备从
    /// Files 行的 `file` blob 里解出来的元数据。我们没写过的行还带着
    /// 设备上传的 blob，正好当参照。每一边各取一个样本就够了：
    /// 要比的是键的集合，而每一边都只由一条代码路径生产。
    ///
    /// 光比键的集合不够：曾经有两轮诊断里键完全对上，但归档的 `Mode`
    /// 是对象引用，导致设备上所有 `decodeInteger` 读法都抛
    /// "not an integer number"。所以*形状*也印在键旁边——见
    /// `mbFileBlobShape`。
    ///
    /// 返回一行日志；注入完马上调一次。
    func blobKeySample(ours: String) -> String {
        guard exists, let db = try? open() else {
            return "blob 键：\(dbPath) 没有能读的 Manifest.db"
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT fileID, file FROM Files WHERE file IS NOT NULL",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return "blob 键：读不了 Manifest.db"
        }
        defer { sqlite3_finalize(stmt) }

        var oursKeys: String?
        var deviceKeys: String?
        var oursShape: String?
        var deviceShape: String?
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cID = sqlite3_column_text(stmt, 0) else { continue }
            let fileID = String(cString: cID)
            let count = sqlite3_column_bytes(stmt, 1)
            guard count > 0, let raw = sqlite3_column_blob(stmt, 1) else { continue }
            let blob = Data(bytes: raw, count: Int(count))
            let keys = mbFileBlobKeys(blob)
            let shape = mbFileBlobShape(blob)
            if fileID == ours {
                oursKeys = keys
                oursShape = shape
            } else if deviceKeys == nil {
                deviceKeys = keys
                deviceShape = shape
            }
            if oursKeys != nil, deviceKeys != nil { break }
        }
        return "blob 键：我们的是 [\(oursKeys ?? "没找到那行")] "
            + "设备的是 [\(deviceKeys ?? "没有可比的行")]"
            + " | 我们的形状：\(oursShape ?? "-")"
            + " | 设备的形状：\(deviceShape ?? "-")"
    }

    /// 清单里任何一行声称的最大的 `InodeNumber`，没有是 0。
    ///
    /// 还原代理按 inode 去重，所以合成的行绝不能复用清单里已经占了的
    /// inode——GoldenNugget 的注入器就是从这个值往上数的
    /// （"代理按 inode 去重，共用供体 inode 的克隆会被按供体的内容还原"，
    /// `src/restore/inject.py:254-266`）。这个字段在每行的 blob 里，
    /// 不在列里，所以要算它只能把每个 blob 都解出来。
    func maxInode() -> Int {
        guard exists, let db = try? open() else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT file FROM Files WHERE file IS NOT NULL",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        var highest = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_bytes(stmt, 0)
            guard count > 0, let raw = sqlite3_column_blob(stmt, 0) else { continue }
            if let inode = mbFileBlobInode(Data(bytes: raw, count: Int(count))) {
                highest = max(highest, inode)
            }
        }
        return highest
    }

    /// 第三阶段：删掉没有 keep 行引用的载荷文件。
    ///
    /// 归属用 Set 查，不用数组扫：一份筛过的一整台设备备份里，每个存着
    /// 的文件都是一条，参照实现就修过这个平方级遍历
    /// （https://github.com/doronz88/pymobiledevice3/issues/1833）。
    private func removeOrphanPayloads(keepIDs: Set<String>) -> Int {
        let fm = FileManager.default
        var removed = 0
        guard let shards = try? fm.contentsOfDirectory(atPath: deviceDir.path) else { return 0 }
        for shard in shards {
            let shardDir = deviceDir.appendingPathComponent(shard)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: shardDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if let payloads = try? fm.contentsOfDirectory(atPath: shardDir.path) {
                for payload in payloads where !keepIDs.contains(payload) {
                    try? fm.removeItem(at: shardDir.appendingPathComponent(payload))
                    removed += 1
                }
            }
            // 清掉已经空了的分片目录。
            if let remaining = try? fm.contentsOfDirectory(atPath: shardDir.path), remaining.isEmpty {
                try? fm.removeItem(at: shardDir)
            }
        }
        return removed
    }
}
