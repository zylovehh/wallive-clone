import Foundation
import SQLite3

/// 只取 PosterBoard 商店数据库的那部分。
///
/// 备份本身走 Rust（`al_backup_fetch_posterboard`，`backup_from_path`
/// + 按 device_name 过滤的钩子）。这里只做 Rust 做不了的三件事：
/// 调 fetch 之前把目录备好、从取回来的备份里把商店数据库找出来、把
/// WAL 合并进去取出一份能用的拷贝。
///
/// 为什么取表要"满备份"：设备只在满备份里给 PosterBoard 的完整行。
/// 增量备份里没有的商店行，还原时没法当供体。
enum PosterBoardBackup {
    /// 取表结果。
    struct Fetch {
        /// 合并好 WAL 的商店拷贝（自包含、声明 WAL）。
        let database: URL
        /// 商店版本号（路径里的 `<版本>` 一段，61 / 62 之类）。
        let structureVersion: Int
        /// 商店里实际装了什么（`PosterBoardStore.summary`）。
        let summary: String
    }

    /// 调 `al_backup_fetch_posterboard` 之前必须先把目录备好。
    ///
    /// iOS 27 上设备备份开始后的第二个消息就是向主机要
    /// `<udid>/Manifest.db`，主机拿不出来备份立刻断——"0 个文件、
    /// 3 秒"就是这个症状。所以这里先写好三样东西：
    /// 占位 Manifest.db（空表）+ Status.plist（满备份）+
    /// 空 Manifest.plist。Rust 侧只写 Info.plist、只管跑备份；
    /// 目录里没有占位 Manifest.db 时 Rust 会直接报错，不硬跑。
    static func prepareFetchDirectory(backupRoot: URL, udid: String,
                                      log: BackupLog = { _ in }) throws {
        let deviceDir = backupRoot.appendingPathComponent(udid, isDirectory: true)
        try FileManager.default.createDirectory(at: deviceDir, withIntermediateDirectories: true)
        // Applications 是空字典：设备跳过所有 App 容器，只备 PosterBoard。
        try HostManifests.ensure(deviceDir: deviceDir, udid: udid, ios27: true,
                                 applications: nil, isFullBackup: true)
        try HostManifests.writeSQLiteManifest(deviceDir: deviceDir, ios27: true)
        log("取表目录已备好（\(deviceDir.path)）：占位 Manifest.db + "
            + "Status.plist（满备份）+ 空 Manifest.plist")
    }

    /// 商店版本号：相对路径里 `Library/Application Support/`
    /// `PRBPosterExtensionDataStore/<版本>/…` 的 `<版本>`。
    static func structureVersion(of relativePath: String) -> Int? {
        PosterBoardSnapshot.storeVersion(relativePath: relativePath)
    }

    /// 从 Rust fetch 回来的备份目录里取出商店数据库。
    ///
    /// 步骤：按 relativePath LIKE 在 Manifest.db 里找到商店主文件那行
    /// （和它的 `-wal` 行，如果有）；把载荷拼到工作目录里（主文件 +
    /// `-wal` 并排，`-shm` 绝不复制，会坏库）；再用 SQLite online-backup
    /// 把 WAL 里的帧合并进主文件，产出一份自包含、声明 WAL 的拷贝。
    ///
    /// 只读主文件是拿不到最新数据的：提交过的行可能还在 `-wal` 里，
    /// 主文件还是旧的。不合并就缝合，等于在旧商店上加行。
    static func extractStore(from deviceDir: URL, to workingDirectory: URL,
                             log: BackupLog = { _ in }) throws -> Fetch {
        let fm = FileManager.default
        let store = ManifestStore(deviceDir: deviceDir, log: log)

        var db: OpaquePointer?
        guard sqlite3_open_v2(deviceDir.appendingPathComponent("Manifest.db").path, &db,
                              SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw BackupError("打不开取回来的 Manifest.db，找不到 PosterBoard 商店。")
        }
        defer { sqlite3_close(db) }

        // 按文件名认，不按 domain 猜：iOS 27 上 domain 可能是原始路径形式。
        var stmt: OpaquePointer?
        let sql = "SELECT fileID, relativePath FROM Files WHERE relativePath LIKE ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BackupError("在 Manifest.db 里找 PosterBoard 商店失败："
                + String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let pattern = "%\(PosterBoard.databaseFileName)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, transient)

        var mainRow: (fileID: String, relativePath: String)?
        var walRow: (fileID: String, relativePath: String)?
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let pathText = sqlite3_column_text(stmt, 1) else { continue }
            let fileID = String(cString: idText)
            let path = String(cString: pathText)
            if path.hasSuffix("-wal") { walRow = (fileID, path) }
            else if path.hasSuffix("-shm") { continue } // -shm 绝不复制，会坏库
            else if path.hasSuffix(PosterBoard.databaseFileName) { mainRow = (fileID, path) }
        }
        guard let mainRow else {
            throw BackupError("取回来的备份里没有 PosterBoard 商店数据库"
                + "（\(PosterBoard.databaseFileName)）。可能是这次备份没备到它，再取一次。")
        }
        guard let version = structureVersion(of: mainRow.relativePath) else {
            throw BackupError("PosterBoard 商店的路径认不出来：\(mainRow.relativePath)。")
        }

        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        // 载荷按 fileID 分片放着，先拼到工作目录里、主文件和 -wal 并排，
        // SQLite 才能把 WAL 里的帧读出来。
        let stagedMain = workingDirectory.appendingPathComponent(PosterBoard.databaseFileName)
        let mainPayload = store.payloadURL(forFileID: mainRow.fileID)
        guard fm.fileExists(atPath: mainPayload.path) else {
            throw BackupError("PosterBoard 商店的载荷缺了（fileID \(mainRow.fileID)），备份不完整。")
        }
        try? fm.removeItem(at: stagedMain)
        try fm.copyItem(at: mainPayload, to: stagedMain)
        if let walRow {
            let walPayload = store.payloadURL(forFileID: walRow.fileID)
            if fm.fileExists(atPath: walPayload.path) {
                let stagedWAL = workingDirectory.appendingPathComponent(
                    PosterBoard.databaseFileName + "-wal")
                try? fm.removeItem(at: stagedWAL)
                try fm.copyItem(at: walPayload, to: stagedWAL)
                log("商店的 -wal 也取回来了，一起合并")
            } else {
                log("注意：清单里有 -wal 行但载荷缺了，只按主文件合并，商店可能是旧的")
            }
        }

        let folded = workingDirectory.appendingPathComponent(
            "FOLDED-" + PosterBoard.databaseFileName, conformingTo: .data)
        try foldStore(from: stagedMain, to: folded)
        log("商店数据库已取出（结构版本 \(version)，\(PosterBoardStore.summary(folded))）")

        guard PosterBoardStore.validate(folded, strict: false) else {
            throw BackupError("取回来的 PosterBoard 商店校验没过——"
                + "\(PosterBoardStore.diagnose(folded, strict: false) ?? "原因不明")"
                + "（有的表：\(PosterBoardStore.describeTables(folded))）。再取一次。")
        }
        return Fetch(database: folded, structureVersion: version,
                     summary: PosterBoardStore.summary(folded))
    }

    /// 把 WAL 合并进主文件（fold），产出一份自包含、声明 WAL 的拷贝。
    ///
    /// 用 SQLite online-backup：源库（含 `-wal` 里的帧）整库拷进目标，
    /// 目标再 `PRAGMA journal_mode=WAL` + `wal_checkpoint(TRUNCATE)`。
    /// 这样送走的这一个文件就带齐了整个数据库——见
    /// `PosterBoardStore.declareWAL` 里"为什么非要是 WAL"那段。
    static func foldStore(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        var src: OpaquePointer?
        guard sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let src else {
            sqlite3_close(src)
            throw BackupError("打不开要合并的 PosterBoard 商店：\(source.lastPathComponent)。")
        }
        defer { sqlite3_close(src) }
        var dst: OpaquePointer?
        guard sqlite3_open(destination.path, &dst) == SQLITE_OK, let dst else {
            sqlite3_close(dst)
            throw BackupError("建不出合并后的 PosterBoard 商店：\(destination.lastPathComponent)。")
        }
        defer { sqlite3_close(dst) }

        guard let backup = sqlite3_backup_init(dst, "main", src, "main") else {
            throw BackupError("SQLite online-backup 建不出来："
                + String(cString: sqlite3_errmsg(dst)))
        }
        defer { sqlite3_backup_finish(backup) }
        var rc = sqlite3_backup_step(backup, -1)
        while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
            rc = sqlite3_backup_step(backup, -1)
        }
        guard rc == SQLITE_DONE else {
            throw BackupError("SQLite online-backup 没跑完（\(rc)）："
                + String(cString: sqlite3_errmsg(dst)))
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_exec(dst, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK,
              sqlite3_prepare_v2(dst, "PRAGMA journal_mode", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW,
              let mode = sqlite3_column_text(stmt, 0),
              String(cString: mode).lowercased() == "wal" else {
            throw BackupError("合并后的 PosterBoard 商店切不到 WAL 模式。")
        }
        guard sqlite3_exec(dst, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK else {
            throw BackupError("合并后的 PosterBoard 商店 checkpoint 做不出来。")
        }
    }
}
