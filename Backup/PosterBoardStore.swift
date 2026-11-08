import Foundation
import SQLite3

/// PosterBoard 商店的 SQLite 数据库：校验它、造一个空的、
/// 再把新壁纸缝进一份拷贝。
///
/// 桌面版 `src/tweaks/posterboard/pb_config_manager.py` 的移植。
/// 只有这个文件碰那个数据库，和 `ManifestStore` 是唯一碰
/// `Manifest.db` 的东西是同一个道理：下面的行形状是设备的约定，
/// 只有一份拷贝才查得动。
///
/// 为什么非要设备自己的数据库，而不是合成一个：一张壁纸是数据库里
/// 的三行加上它的描述符目录。这几行带着设备自己的 provider 注册、
/// 角色归属和选择器排序用的元数据，没法凭空编——`posterAttributes`
/// 有 `UNIQUE(posterUUID, roleId, attributeIdentifier)` 约束，
/// 猜出来的行集合会撞。所以 apply 是读设备的数据库，在它的拷贝上
/// 加行，再把拷贝送回去。
enum PosterBoardStore {
    /// v61（db5+）的表集合：真机 27.0.1 / 27.2 的 PosterBoard 商店实测有这 6 张表
    ///（2026-11-08 探针从设备真表打出的 sqlite_master）。严格校验要求六个都有。
    static let requiredTables = ["poster", "posterAttributes", "posterMetadata",
                                 "posterRoleMembership", "posterRoles", "sqlite_sequence"]

    /// `SQLITE_TRANSIENT` 是 C 的宏，这个模块看不到它；`-1` 告诉 sqlite
    /// 把字节拷一份再存，不要留着指针——Swift 的临时量在 bind 返回
    /// 的那一刻就没了。
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - 校验

    /// `_validate_posterboard_db`。
    ///
    /// - Parameter strict: `true` 要求 v61 表集合；`false` 接受任何带着
    ///   poster 相关表的健康数据库，因为结构会在 iOS 版本之间变（db5+）。
    static func validate(_ url: URL, strict: Bool = true) -> Bool {
        diagnose(url, strict: strict) == nil
    }

    /// 是哪一步校验把数据库否了，健康时是 nil。
    ///
    /// 以前一次失败的取表只留下一个光秃秃的 `false`：流程停了，
    /// 日志停在上一行，原因只在手机的状态行里才有。`describeTables`
    /// 只会描述一个能打开的数据库，而恰恰是打不开、或者
    /// `integrity_check` 说了"ok"以外的东西时最需要解释。
    static func diagnose(_ url: URL, strict: Bool = true) -> String? {
        let path = url.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes?[.size] as? Int else {
            return "\(path) 没有这个文件"
        }
        guard size >= 100 else { return "\(size) 字节——太小了，不可能是数据库" }
        guard let db = open(path) else {
            return "SQLite 打不开它：\(openComplaint(path))"
        }
        defer { sqlite3_close(db) }

        guard exec(db, "SELECT 1 FROM sqlite_master LIMIT 1") else {
            return "sqlite_master 读不了：\(String(cString: sqlite3_errmsg(db)))"
        }
        if strict {
            let missing = requiredTables.filter { !tableExists(db, $0) }
            guard missing.isEmpty else {
                return "缺表：\(missing.joined(separator: ", "))"
            }
        } else {
            let tables = tableNames(db).map { $0.lowercased() }
            guard tables.contains(where: { $0.contains("poster") }) else {
                return "没有一张表的名字和 PosterBoard 有关（有的表："
                    + "\(tables.isEmpty ? "没有" : tables.joined(separator: ", "))）"
            }
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else {
            return "integrity_check 跑不起来：\(String(cString: sqlite3_errmsg(db)))"
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(statement, 0) else {
                return "integrity_check 什么都没说"
            }
            let verdict = String(cString: text)
            return verdict == "ok" ? nil : "integrity_check：\(verdict)"
        case SQLITE_DONE:
            return "integrity_check 没有返回行"
        default:
            return "integrity_check 失败：\(String(cString: sqlite3_errmsg(db)))"
        }
    }

    /// `open` 自己报不出来的抱怨，留给 `open` 打不开的情况：
    /// 只读连接建不出 WAL 数据库需要的 `-shm`，而这个失败表面上
    /// 什么都没有，不是一句错误。
    private static func openComplaint(_ path: String) -> String {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(db) }
        guard rc != SQLITE_OK else { return "只读打不开，读写能打开" }
        return String(cString: sqlite3_errmsg(db))
    }

    /// `_is_encrypted_database`：一个打不开的普通 SQLite 数据库，
    /// 要么是加密的、要么根本不是数据库，两种情况答案一样。
    static func isEncrypted(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int, size >= 100 else { return false }
        guard let db = openReadOnly(url.path) else { return false }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &statement, nil)
        if status == SQLITE_OK { return false }
        let message = String(cString: sqlite3_errmsg(db)).lowercased()
        return message.contains("encrypted") || message.contains("not a database")
    }

    /// 一份被否的文件到底带哪些表，给日志里那句"为什么"用。
    static func describeTables(_ url: URL) -> String {
        guard let db = open(url.path) else { return "读不出来" }
        defer { sqlite3_close(db) }
        let tables = tableNames(db)
        return tables.isEmpty ? "没有表" : tables.sorted().joined(separator: ", ")
    }

    /// 一份商店实际装了什么，一句话。
    ///
    /// 行数是取表两边留下的唯一证据，能分清"设备给了个 live 商店"
    /// 还是"给了个空的"：一个结构完整、`poster` 表里什么都没有的
    /// 商店，校验起来和满的一模一样，所以把它送回去会把设备上
    /// 每一张壁纸都清掉，日志里还没话说为什么。取回来的商店记一次，
    ///  staging 的拷贝记一次，"设备什么都没给"和"缝合时把行弄丢了"
    /// 就不会再被认错。
    static func summary(_ url: URL) -> String {
        guard let db = open(url.path) else { return "读不出来" }
        defer { sqlite3_close(db) }
        func count(_ table: String) -> String {
            guard let rows = try? scalarInt(db, "SELECT COUNT(*) FROM \(table)") else { return "?" }
            return String(rows)
        }
        var parts = ["\(count("poster")) 张 poster",
                     "\(count("posterRoleMembership")) 条归属记录"]
        if tableExists(db, "posterAttributes") {
            parts.append("\(count("posterAttributes")) 条属性记录")
        }
        if tableExists(db, "posterRoles") {
            parts.append("\(count("posterRoles")) 个角色")
        }
        if tableExists(db, "posterMetadata") {
            parts.append("\(count("posterMetadata")) 条元数据")
        }
        return parts.joined(separator: "，")
    }

    // MARK: - 空数据库

    /// `create_empty_posterboard_db`：商店的结构、不带数据，
    /// 也就是一次完整重置后留下的东西。
    ///
    /// 建表语句照抄设备真表（v61，2026-11-08 探针从 27.0.1 真机打出的
    /// sqlite_master），包括以前漏掉的 posterRoles / posterMetadata。
    /// 顺序上 posterRoles 在前，因为 posterAttributes 和
    /// posterRoleMembership 的外键指着它。
    static func createEmptyDatabase(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw BackupError("空的 PosterBoard 数据库建不出来：\(url.lastPathComponent)。")
        }
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE IF NOT EXISTS "poster" (
              "posterId" INTEGER PRIMARY KEY AUTOINCREMENT,
              "UUID" TEXT UNIQUE ON CONFLICT ROLLBACK,
              "providerId" TEXT NOT NULL ON CONFLICT ROLLBACK
            );
            CREATE TABLE IF NOT EXISTS "posterRoles" (
              "roleIdentifier" TEXT PRIMARY KEY ON CONFLICT ROLLBACK UNIQUE ON CONFLICT ROLLBACK NOT NULL ON CONFLICT ROLLBACK,
              "displayName" NOT NULL ON CONFLICT ROLLBACK UNIQUE ON CONFLICT ROLLBACK
            );
            CREATE TABLE IF NOT EXISTS "posterMetadata" (
              "key" TEXT NOT NULL ON CONFLICT ROLLBACK UNIQUE ON CONFLICT ROLLBACK PRIMARY KEY,
              "value" TEXT NOT NULL ON CONFLICT ROLLBACK
            );
            CREATE TABLE IF NOT EXISTS "posterAttributes" (
              "posterUUID" TEXT NOT NULL ON CONFLICT ROLLBACK,
              "roleId" TEXT NOT NULL ON CONFLICT ROLLBACK,
              "attributeIdentifier" TEXT NOT NULL ON CONFLICT ROLLBACK,
              "attributePayload" TEXT NOT NULL ON CONFLICT ROLLBACK,
              CONSTRAINT posters FOREIGN KEY (posterUUID) REFERENCES poster(UUID) ON DELETE CASCADE,
              CONSTRAINT roles FOREIGN KEY (roleId) REFERENCES posterRoles(roleIdentifier) ON DELETE CASCADE,
              UNIQUE (posterUUID, roleID, attributeIdentifier)
            );
            CREATE TABLE IF NOT EXISTS "posterRoleMembership" (
              "posterUUID" TEXT NOT NULL ON CONFLICT ROLLBACK,
              "roleId" TEXT NOT NULL ON CONFLICT ROLLBACK,
              "roleSortKey" INTEGER NOT NULL,
              CONSTRAINT posters FOREIGN KEY (posterUUID) REFERENCES poster(UUID) ON DELETE CASCADE,
              CONSTRAINT roles FOREIGN KEY (roleId) REFERENCES posterRoles(roleIdentifier) ON DELETE CASCADE
            );
            """
        guard exec(db, schema) else {
            throw BackupError("空的 PosterBoard 数据库结构建不出来："
                + String(cString: sqlite3_errmsg(db)))
        }
        // 和缝好的商店一样的发货要求：重置送的也是这个文件，而
        // PosterBoard 的只读打开没法把一个回滚日志数据库切到 WAL
        // （见 `declareWAL`）。
        try declareWAL(db, describing: "空的 PosterBoard 数据库")
        guard validate(url) else {
            throw BackupError("空的 PosterBoard 数据库校验没过。重置已在写进设备之前停下。")
        }
    }

    // MARK: - 缝合

    /// `PBConfigManager.update_sqlite`，作用在设备数据库的一份拷贝上。
    ///
    /// 返回要送走的文件。源文件永远不动：这步之后失败的流程，
    /// 绝不能动了商店唯一的副本。
    static func stitch(database: URL,
                       items: [PosterBoardConfigItem],
                       workingDirectory: URL) throws -> URL {
        if isEncrypted(database) {
            throw BackupError(
                "这个 PosterBoard 数据库是加密的。先去 Finder / iTunes 里取消"
                + "勾选「加密本地备份」，重新备一份再取一次——明文载荷塞进加密的"
                + "商店，还原代理解不出来（MBErrorDomain/205）。")
        }
        if let complaint = diagnose(database, strict: false) {
            throw BackupError(
                "这个 PosterBoard 数据库用不了——\(complaint)（有的表："
                + "\(describeTables(database))）。可能是取表时断了，再取一次。")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let staged = workingDirectory.appendingPathComponent(
            "STAGED-" + PosterBoard.databaseFileName, conformingTo: .data)
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: database, to: staged)
        guard validate(staged) else {
            throw BackupError("PosterBoard 数据库的 staging 拷贝校验没过——"
                + "源文件可能坏了，再取一次。")
        }

        var db: OpaquePointer?
        guard sqlite3_open(staged.path, &db) == SQLITE_OK, let db else {
            throw BackupError("打不开 staging 的 PosterBoard 数据库。")
        }
        defer { sqlite3_close(db) }
        guard exec(db, "PRAGMA busy_timeout = 10000") else {
            throw BackupError("给 staging 数据库设 busy 超时失败。")
        }
        guard exec(db, "BEGIN IMMEDIATE") else {
            throw BackupError("在 staging 的 PosterBoard 数据库上开不了事务："
                + String(cString: sqlite3_errmsg(db)))
        }
        do {
            try write(db, items: items)
            guard exec(db, "COMMIT") else {
                throw BackupError("提交 PosterBoard 的行失败："
                    + String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            _ = exec(db, "ROLLBACK")
            throw error
        }
        // 上面的行是经过 `-wal` 写进去的，而 apply 送走的是这一个文件——
        // 所以它必须是设备自己的商店那个形状（见 `declareWAL`）。
        try declareWAL(db, describing: "staging 的 PosterBoard 数据库")
        return staged
    }

    /// 让数据库声明 WAL、且所有已提交的页都在主文件里——
    /// 还原能送的唯一形状。
    ///
    /// PosterBoard 以只读打开商店（`opening database … w/ flags 1`），
    /// 马上跑 `PRAGMA journal_mode=WAL`。一个本来就声明 WAL 的数据库，
    /// 这个 pragma 是个没-op，能过；一个回滚日志的数据库，这个 pragma
    /// 是*一次写*，只读连接会回 "attempt to write a readonly database"。
    /// 然后商店记一句 "data store never ever initialized; skipping
    /// migration"，再从图库里重建自己：每张海报都换一个新身份，
    /// 内容只在商店里的东西——每张自定义壁纸——全没了。这就是这个
    /// 功能一直反复造出来的清空，就差这一行 SQL。
    ///
    /// 文件还是自包含的：checkpoint 会把每一帧都挪进主文件，
    /// 再把 `-wal` 截成 0，所以我们送的这一个文件就带齐了整个数据库。
    /// 还原一起送的 0 字节 `-wal` / `-shm` 伴生文件，正好就是
    /// 设备自己的商店那个状态。
    private static func declareWAL(_ db: OpaquePointer, describing what: String) throws {
        guard exec(db, "PRAGMA journal_mode=WAL"),
              try scalarText(db, "PRAGMA journal_mode")?.lowercased() == "wal" else {
            throw BackupError("\(what)切不到 WAL 模式（"
                + String(cString: sqlite3_errmsg(db)) + "）。PosterBoard 以只读打开商店并要 WAL，"
                + "一个回滚日志的数据库会让这步失败——然后它会重建商店，丢掉每张壁纸。")
        }
        guard exec(db, "PRAGMA wal_checkpoint(TRUNCATE)") else {
            throw BackupError("\(what) checkpoint 做不出来——送走它会把行留在还原"
                + "不带走的文件里："
                + String(cString: sqlite3_errmsg(db)))
        }
    }

    /// 真正的插入。每次都是先改、改不到才插，因为刚取回来的数据库
    /// 可能已经有这次名单里提到的行（同一包重装），而属性表和归属表
    /// 里还可能有上一次失败的 apply 留下的孤儿。
    ///
    /// `posterId` 从 **`MAX(posterId)` 之上**开始，而不是从
    /// `sqlite_sequence.seq + 1`：旧办法会和一个活着的行撞号
    /// （那行的 id 在 sequence 漂移之后，删过行就会这样），
    /// 主键一撞就是一次失败的 apply，或者设备上一个坏掉的商店。
    private static func write(_ db: OpaquePointer, items: [PosterBoardConfigItem]) throws {
        var sequence = try scalarInt(db, "SELECT MAX(posterId) FROM poster") ?? 0
        var sortKey = try scalarInt(db,
            "SELECT MAX(roleSortKey) FROM posterRoleMembership WHERE roleId = ?",
            [.text("PRPosterRoleLockScreen")]) ?? sequence

        // 角色行：归属和属性的外键都指着 posterRoles，空表里必须先有
        // 锁屏角色这一行，PosterBoard 查角色时才能找到，图库才认这张
        // 壁纸。displayName 和 metadata 的值抄自 Vellum PC 自带的空白
        // 底座表 builtin_base.sqlite3（证据：~/workspace/vellum-pc-re/
        // analysis/builtin_base_rows.txt）：锁屏角色显示名是 "Lock Screen"，
        // posterMetadata 是 version=2、deviceClass=0。
        try run(db, "UPDATE posterRoles SET displayName = ? WHERE roleIdentifier = ?",
                [.text("Lock Screen"), .text("PRPosterRoleLockScreen")])
        if changes(db) == 0 {
            try run(db, "INSERT INTO posterRoles (roleIdentifier, displayName) VALUES (?, ?)",
                    [.text("PRPosterRoleLockScreen"), .text("Lock Screen")])
        }

        // 元数据行：真表里有 version=2、deviceClass=0 两行（同上，Vellum PC
        // builtin_base.sqlite3）。空表里没有这两行时也补上。
        try run(db, "UPDATE posterMetadata SET value = ? WHERE key = ?",
                [.text("2"), .text("version")])
        if changes(db) == 0 {
            try run(db, "INSERT INTO posterMetadata (key, value) VALUES (?, ?)",
                    [.text("version"), .text("2")])
        }
        try run(db, "UPDATE posterMetadata SET value = ? WHERE key = ?",
                [.text("0"), .text("deviceClass")])
        if changes(db) == 0 {
            try run(db, "INSERT INTO posterMetadata (key, value) VALUES (?, ?)",
                    [.text("deviceClass"), .text("0")])
        }

        // 选中的壁纸只能有一张。没有新条目要求当选时（包括只动容器的
        // 流程），保留当前选中的那张。
        let selectedUUID = items.last(where: { $0.setSelected })?.uuid
        if selectedUUID != nil {
            try run(db, "DELETE FROM posterAttributes WHERE roleId = ? AND attributeIdentifier = ?",
                    [.text("PRPosterRoleLockScreen"), .text("SELECTED")])
        }

        for item in items {
            let payload = usageMetadataJSON()
            let existing = try scalarInt(db, "SELECT posterId FROM poster WHERE UUID = ?",
                                         [.text(item.uuid)])
            if let existing {
                try run(db, "UPDATE poster SET providerId = ? WHERE posterId = ?",
                        [.text(item.extensionID), .integer(existing)])
            } else {
                sequence += 1
                try run(db, "INSERT INTO poster (posterId, UUID, providerId) VALUES (?, ?, ?)",
                        [.integer(sequence), .text(item.uuid), .text(item.extensionID)])
            }

            try run(db,
                "UPDATE posterAttributes SET attributePayload = ? WHERE posterUUID = ? "
                + "AND roleId = ? AND attributeIdentifier = ?",
                [.text(payload), .text(item.uuid), .text("PRPosterRoleLockScreen"),
                 .text("PRPosterRoleAttributeTypeUsageMetadata")])
            if changes(db) == 0 {
                try run(db,
                    "INSERT INTO posterAttributes (posterUUID, roleId, attributeIdentifier, "
                    + "attributePayload) VALUES (?, ?, ?, ?)",
                    [.text(item.uuid), .text("PRPosterRoleLockScreen"),
                     .text("PRPosterRoleAttributeTypeUsageMetadata"), .text(payload)])
            }

            if item.uuid == selectedUUID {
                try run(db,
                    "DELETE FROM posterAttributes WHERE posterUUID = ? AND roleId = ? "
                    + "AND attributeIdentifier = ?",
                    [.text(item.uuid), .text("PRPosterRoleLockScreen"), .text("SELECTED")])
                try run(db,
                    "INSERT INTO posterAttributes (posterUUID, roleId, attributeIdentifier, "
                    + "attributePayload) VALUES (?, ?, ?, ?)",
                    [.text(item.uuid), .text("PRPosterRoleLockScreen"), .text("SELECTED"),
                     .integer(1)])
            }

            try run(db,
                "UPDATE posterRoleMembership SET roleSortKey = ? WHERE posterUUID = ? "
                + "AND roleId = ?",
                [.integer(sortKey + 1), .text(item.uuid), .text("PRPosterRoleLockScreen")])
            if changes(db) == 0 {
                try run(db,
                    "INSERT INTO posterRoleMembership (posterUUID, roleId, roleSortKey) "
                    + "VALUES (?, ?, ?)",
                    [.text(item.uuid), .text("PRPosterRoleLockScreen"), .integer(sortKey + 1)])
            }
            sortKey += 1
        }

        try run(db, "UPDATE sqlite_sequence SET seq = ? WHERE name = ?",
                [.integer(sequence), .text("poster")])
        if changes(db) == 0 {
            try run(db, "INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)",
                    [.text("poster"), .integer(sequence)])
        }
    }

    /// 设备给一张壁纸写的 `attributePayload` JSON。
    ///
    /// 手写，不走 `JSONSerialization`，只有一个原因：键的顺序。
    /// 参考实现用 `json.dumps(..., separators=(",", ":"))`，保留插入顺序，
    /// 我们写的一行要和上游会写的那行比得上。
    ///
    /// 三个时间戳是参考实现里三次各自的 `time.time()` 调用——
    /// 不是一次读表再加偏移——所以这里也是三次各自读表。
    private static func usageMetadataJSON() -> String {
        let now = Date().timeIntervalSince1970
        return "{\"creationDate\":\(now),"
            + "\"extensionAvailable\":true,"
            + "\"attributeType\":\"PRPosterRoleAttributeTypeUsageMetadata\","
            + "\"lastActivatedDate\":\(Date().timeIntervalSince1970 + 0.0001),"
            + "\"lastSelectedDate\":\(Date().timeIntervalSince1970 + 0.00001)}"
    }

    // MARK: - SQLite 管道

    private enum Binding {
        case text(String)
        case integer(Int)
    }

    /// 一个读句柄，不管它的日志 sidecar 在不在。
    ///
    /// 先只读，因为下面每个读都是这么读的。但一个 WAL 模式的数据库，
    /// 旁边没有 `-wal` / `-shm` 这一对是没法这么读的：SQLite 要共享内存
    /// 文件来取读标记，而它不会给一个读者去建，所以第一条语句就以
    /// SQLITE_CANTOPEN 失败。句柄还是懒的——`sqlite3_open_v2` 在碰到
    /// 文件之前就返回 SQLITE_OK——所以这个失败只在第一条语句上出现，
    /// 打开时永远看不到。这正是我们刚为交付准备好的商店的形状：
    /// `fold` 把每一页 checkpoint 进主文件，sidecar 留作还原另外带的
    /// 0 字节伴生文件。先探一下，读不了就改读写重试，让 SQLite
    /// 把它需要的建出来。
    private static func open(_ path: String) -> OpaquePointer? {
        for flags in [SQLITE_OPEN_READONLY, SQLITE_OPEN_READWRITE] {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
                sqlite3_close(db)
                continue
            }
            var statement: OpaquePointer?
            let status = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1",
                                           -1, &statement, nil)
            sqlite3_finalize(statement)
            if status == SQLITE_OK { return db }
            sqlite3_close(db)
        }
        return nil
    }

    /// 一个只读句柄，*不带*上面那个探查，给 `isEncrypted` 用：
    /// 要把加密的和 WAL 模式的分开，就得读失败本身，而 `open`
    /// 把两种都报成"打不开"。
    private static func openReadOnly(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func tableNames(_ db: OpaquePointer) -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'",
                                 -1, &statement, nil) == SQLITE_OK else { return [] }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { names.append(String(cString: text)) }
        }
        return names
    }

    private static func tableExists(_ db: OpaquePointer, _ table: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                                 -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, table, -1, transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// 一行里一列整数，行或值没有时是 nil。
    private static func scalarInt(_ db: OpaquePointer, _ sql: String,
                                  _ bindings: [Binding] = []) throws -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BackupError("PosterBoard 查询失败：\(sql)——"
                + String(cString: sqlite3_errmsg(db)))
        }
        bind(statement, bindings)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// 一行里一列文本，行或值没有时是 nil。
    private static func scalarText(_ db: OpaquePointer, _ sql: String,
                                   _ bindings: [Binding] = []) throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BackupError("PosterBoard 查询失败：\(sql)——"
                + String(cString: sqlite3_errmsg(db)))
        }
        bind(statement, bindings)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL { return nil }
        guard let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private static func run(_ db: OpaquePointer, _ sql: String,
                            _ bindings: [Binding] = []) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BackupError("PosterBoard 写失败：\(sql)——"
                + String(cString: sqlite3_errmsg(db)))
        }
        bind(statement, bindings)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw BackupError("PosterBoard 写失败：\(sql)——"
                + String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func bind(_ statement: OpaquePointer?, _ bindings: [Binding]) {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
            case .integer(let value): sqlite3_bind_int64(statement, index, Int64(value))
            }
        }
    }

    /// `sqlite3_changes`，给上面"先改、改不到再插"的写法用。
    private static func changes(_ db: OpaquePointer) -> Int {
        Int(sqlite3_changes(db))
    }
}
