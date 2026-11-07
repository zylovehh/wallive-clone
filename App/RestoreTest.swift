// RestoreTest.swift
// 还原测试：把一张壁纸真正装进图库，走“改表还原”这条路。
//
// 流程（一步断了就停，不继续往下走）：
//   1. 拿表：走探针 3 同一条 AirTraffic 拷回通道，把 v61 的表和 -wal
//      拷回来、存进 Documents/posterboard-table（原表先另存一份备份）。
//      拷不回来就改用已存的表（先找 merged.sqlite3，没有就找最新存
//      下来的那份），日志里写明用的是已存的表，不假装刚拷回来。
//   2. 编包：复用备份路的 PosterBoardCompiler.compile，把选中包编成
//      configurations/<新 UUID> 的载荷（只走 configurations，不写
//      descriptors——编包器自己写明了，27.0.1 上 descriptors 双写会逼
//      商店重建、壁纸全没）。
//   3. 写文件：载荷按父目录分组，走直写那条 AirTraffic 写通道
//     （al_exploit_write_dir，偏好重写已证实它能覆盖已有文件）写进
//      PosterBoard 容器。
//   4. 插行：复用备份路的 PosterBoardStore.stitch（照金块 update_sqlite
//      搬的：posterId 取 MAX+1，三张表先改后插，sqlite_sequence 同步，
//      0 字节 -wal/-shm 伴生），只改一份拷贝，原表不动。
//   5. 写回表：新 Rust FFI al_restore_posterboard_writeback 把改好的
//      表（+ 0 字节 -wal/-shm）写回商店目录。
//   6. 提示用户重启手机，再去图库长按看有没有这张壁纸。
//
// 注意：
// - 不走 BackupInstallFlow 的 iOS 27 门控（那是给 27.2 备份路准备的，
//   这次就是要在 27.0.1 上试改表还原）；直写、备份、探针 3 都不动。
// - SQL 插行不在 Rust 里做：Rust 那个包没有 SQLite 库（没 rusqlite，
//   离线锁定构建加不进去），插行走 Swift 自带的 SQLite3，和探针 3
//   合库那套一样；Rust 只做它才能做的事（隧道 + AirTraffic 写回）。
// - 写回是活机写：PosterBoard 进程还开着旧表，写完请用户尽快重启，
//   别在重启前又去图库里划来划去；重启后进程重读新表。
// - 探针 3 之后表里只剩 10 行系统自带的，现在图库本来就是空的，
//   这次试坏了也不会再丢东西。

import Foundation
import AirliftFFI
import SQLite3

/// 还原测试一次跑完的结果（页面只显示 summary 这一行，完整 JSON 进日志框）。
struct RestoreOutcome {
    let success: Bool
    let summary: String
    let descriptorUUID: String?
    let posterId: Int?
    let json: String
}

enum RestoreTest {
    static let storeVersion = 61

    /// 表的存放处，和探针 3 同一个目录。
    static var tableDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("posterboard-table")
    }

    /// 哪一步停了、为什么。跑完如实报，不编原因。
    private struct StepError: Error {
        let step: String
        let detail: String
    }

    // MARK: - 还原测试

    /// 跑一次还原测试。调用方必须已经在后台线程（FFI 和 SQLite 都会阻塞）。
    /// packageData：导入页当前选中的那个包；没选中包就直接报，不编默认包。
    static func runRestore(packageData: Data, pairingPath: String) -> RestoreOutcome {
        var report: [String: Any] = ["channel": "restore_test", "success": false]
        do {
            let outcome = try restore(packageData: packageData, pairingPath: pairingPath, report: &report)
            report["success"] = true
            InstallLog.shared.append("restore: json=\(jsonString(report))")
            return outcome
        } catch let e as StepError {
            report["step"] = e.step
            report["error"] = e.detail
            InstallLog.shared.append("restore: FAILED \(e.step)：\(e.detail) json=\(jsonString(report))")
            return RestoreOutcome(
                success: false,
                summary: "还原测试停在\(e.step)：\(e.detail)原来的表还在 Documents/posterboard-table 里，没动。完整结果见下面日志框。",
                descriptorUUID: nil, posterId: nil, json: jsonString(report))
        } catch {
            report["error"] = error.localizedDescription
            InstallLog.shared.append("restore: FAILED \(error.localizedDescription) json=\(jsonString(report))")
            return RestoreOutcome(
                success: false,
                summary: "还原测试失败：\(error.localizedDescription)完整结果见下面日志框。",
                descriptorUUID: nil, posterId: nil, json: jsonString(report))
        }
    }

    private static func restore(packageData: Data, pairingPath: String,
                                report: inout [String: Any]) throws -> RestoreOutcome {
        let fm = FileManager.default
        let stamp = timeStamp()
        let workDir = fm.temporaryDirectory.appendingPathComponent("wallive-clone-restore-\(stamp)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // 1. 拿表：先试探针 3 同一条通道拷回 v61 的表 + -wal、存盘。
        //    拷不回来就改用手机里已存的那张表接着做，不死等重拷——
        //    拷回那条路重启后第一次能成，之后再跑就不成。
        let savedDB: URL
        let savedWAL: URL?
        let container: String
        do {
            let fresh = try exportAndSave(
                pairingPath: pairingPath, stamp: stamp, report: &report)
            savedDB = fresh.savedDB
            savedWAL = fresh.savedWAL
            container = fresh.container
            report["table_source"] = "fresh"
        } catch {
            let exportError = (error as? StepError)
                ?? StepError(step: "拿表", detail: "\(error.localizedDescription)")
            let fallback = try storedTableFallback(report: &report, exportError: exportError)
            savedDB = fallback.db
            savedWAL = fallback.wal
            container = fallback.container
            report["table_source"] = "stored"
            report["stored_db_path"] = fallback.db.path
            report["stored_db_kind"] = fallback.kind
            if let d = fallback.savedDate {
                report["stored_db_saved"] = isoDate(d)
            }
            InstallLog.shared.append(
                "restore: 拷回没成（\(exportError.detail)），这次用的是已存的表：\(fallback.db.lastPathComponent)"
                + (fallback.savedDate.map { "，存于 \(isoDate($0))" } ?? "")
                + "；不是刚拷回来的，接着往下做。")
        }

        // 原表备份：写回之前先把这次用的原表（刚拷回来的，或已存的那份）再存一份，坏了能回来。
        let backupDB = tableDir.appendingPathComponent("backup-原表-\(stamp).sqlite3")
        try? fm.removeItem(at: backupDB)
        try fm.copyItem(at: savedDB, to: backupDB)
        var backupWAL: URL?
        if let wal = savedWAL {
            let dst = tableDir.appendingPathComponent("backup-原表-\(stamp).sqlite3-wal")
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: wal, to: dst)
            backupWAL = dst
        }
        report["backup_db_path"] = backupDB.path
        if let backupWAL {
            report["backup_wal_path"] = backupWAL.path
        }

        // 2. 合 -wal：只改一份副本，原表不动；合完验库。
        let merged = try mergeStore(savedDB: savedDB, savedWAL: savedWAL, workDir: workDir)
        report["merged_db"] = merged.path
        report["store_before"] = PosterBoardStore.summary(merged)

        // 3. 编包：先暂存、再编成 configurations 载荷（复用备份路）。
        let installer = DescriptorInstaller(zip: ZipFoundationAdapter())
        let stage: URL
        do {
            (stage, _) = try installer.stage(packageData)
        } catch let error as TendiesPackage.Error {
            switch error {
            case .notATendiesPackage:
                throw StepError(step: "解包", detail: "这不是一个 .tendies / .wallive 包。")
            case .missingWallpaperDirectory:
                throw StepError(step: "解包", detail: "包里找不到壁纸目录，结构不对。")
            case .missingWallpaperPlist:
                throw StepError(step: "解包", detail: "包里找不到 Wallpaper.plist，结构不对。")
            }
        }
        let compiled: (payloads: [BackupPayload], configs: [PosterBoardConfigItem])
        do {
            compiled = try PosterBoardCompiler.compile(
                stageDirectory: stage, structureVersion: storeVersion,
                log: { InstallLog.shared.append($0) })
        } catch {
            throw StepError(step: "编包", detail: "\(error.localizedDescription)")
        }
        guard !compiled.configs.isEmpty else {
            throw StepError(step: "编包", detail: "包里没找到描述符，编不出还原包（老格式的包备份路不接）。")
        }
        let firstConfig = compiled.configs[0]
        report["descriptor_uuid"] = firstConfig.uuid
        report["extension_id"] = firstConfig.extensionID
        report["payload_count"] = compiled.payloads.count

        // 4. 写文件：载荷按父目录分组，走直写那条 AirTraffic 写通道。
        let filesWritten = try writePayloadFiles(
            payloads: compiled.payloads, container: container, pairingPath: pairingPath)
        report["files_written"] = filesWritten

        // 5. 插行：复用备份路的 stitch（金块 update_sqlite 的移植）。
        let stitchDir = workDir.appendingPathComponent("stitch")
        let staged: URL
        do {
            staged = try PosterBoardStore.stitch(
                database: merged, items: compiled.configs, workingDirectory: stitchDir)
        } catch {
            throw StepError(step: "插行", detail: "\(error.localizedDescription)")
        }
        // 验一下新行真的在：按 UUID 查 posterId。
        let newPosterId = try posterIdOfStitched(staged: staged, uuid: firstConfig.uuid)
        report["poster_id"] = newPosterId
        report["store_after"] = PosterBoardStore.summary(staged)

        // 6. 写回表：改好的表 + 0 字节 -wal/-shm，走新 FFI 写回商店目录。
        let writebackDir = workDir.appendingPathComponent("writeback")
        try fm.createDirectory(at: writebackDir, withIntermediateDirectories: true)
        let stagedName = PosterBoard.databaseFileName
        try fm.copyItem(at: staged,
                         to: writebackDir.appendingPathComponent(stagedName))
        fm.createFile(atPath: writebackDir.appendingPathComponent(stagedName + "-wal").path,
                      contents: Data())
        fm.createFile(atPath: writebackDir.appendingPathComponent(stagedName + "-shm").path,
                      contents: Data())
        let targetStoreDir = container + PosterBoard.storePath(storeVersion)
        let writebackJSON = try callWritebackFFI(
            pairingPath: pairingPath, stagedDir: writebackDir.path, targetDir: targetStoreDir)
        report["writeback"] = writebackJSON
        guard writebackJSON["success"] as? Bool == true else {
            throw StepError(step: "写回表",
                            detail: "写回没成（\(writebackJSON["error"] as? String ?? "原因见日志")）。文件已写进容器，表还是旧的。")
        }

        let usedStored = (report["table_source"] as? String) == "stored"
        let summary = "还原测试成功：新 posterId \(newPosterId)，描述符 \(firstConfig.uuid)，文件写了 \(filesWritten) 个、表已写回\(usedStored ? "（这次用的是手机里已存的表，不是刚拷回来的）" : "")。重启手机，再去图库长按看有没有这张壁纸。完整结果见下面日志框。"
        return RestoreOutcome(success: true, summary: summary,
                              descriptorUUID: firstConfig.uuid, posterId: newPosterId,
                              json: jsonString(report))
    }

    // MARK: - 拿表（探针 3 同一条 FFI）

    /// 调 al_probe_posterboard_save 拷回 v61 的表 + -wal，返回存盘路径和容器路径。
    private static func exportAndSave(pairingPath: String, stamp: String,
                                      report: inout [String: Any]) throws
        -> (savedDB: URL, savedWAL: URL?, container: String) {
        let destDir = tableDir.path
        let (rc, json, error) = callSaveFFI(
            pairingPath: pairingPath, destDir: destDir, stamp: stamp)
        guard rc == 0, let json,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StepError(step: "拿表", detail: "拷回通道没通：\(error ?? "未知错误")")
        }
        report["export"] = obj
        guard (obj["success"] as? Bool) == true,
              (obj["saved_db_ok"] as? Bool) == true,
              let dbPath = obj["saved_db_path"] as? String,
              let container = obj["container"] as? String else {
            throw StepError(step: "拿表", detail: "表没拷回来（v61 没成，或存盘校验没过）。")
        }
        let walPath = obj["saved_wal_path"] as? String
        return (URL(fileURLWithPath: dbPath),
                walPath.map { URL(fileURLWithPath: $0) },
                container)
    }

    /// 兜底：拷回失败时改用手机里已存的表接着做。先找 merged.sqlite3，
    /// 没有就找最新时间戳的那份 PBF...-*.sqlite3（配同名 -wal）。
    /// 容器路径从刚失败那次拷回的 JSON 里拿（失败的 JSON 里也有
    /// container）；表找不到、或者容器路径拿不到，就停下来报真实原因。
    /// 验库不在这里做，后面合库那步会验（integrity_check 不过就停）。
    /// 只给 restore() 用，列行按钮那套选表逻辑没动。
    private static func storedTableFallback(report: inout [String: Any],
                                            exportError: StepError)
        throws -> (db: URL, wal: URL?, container: String, kind: String, savedDate: Date?) {
        let fm = FileManager.default
        let dir = tableDir
        var dbURL: URL?
        var walURL: URL?
        var kind = ""
        var savedDate: Date?
        let merged = dir.appendingPathComponent("merged.sqlite3")
        if fm.fileExists(atPath: merged.path) {
            dbURL = merged
            kind = "merged.sqlite3"
            savedDate = (try? merged.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            // merged.sqlite3 的 -wal 已经合进主库了，不用再配 -wal。
        } else {
            let saved = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let candidates = saved
                .filter {
                    $0.lastPathComponent.hasPrefix("PBFPosterExtensionDataStoreSQLiteDatabase-")
                    && $0.pathExtension == "sqlite3"
                }
                .sorted {
                    let da = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    let db = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    return da > db
                }
            if let newest = candidates.first {
                dbURL = newest
                kind = newest.lastPathComponent
                savedDate = (try? newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                let wal = URL(fileURLWithPath: newest.path + "-wal")
                if fm.fileExists(atPath: wal.path) { walURL = wal }
            }
        }
        guard let db = dbURL else {
            throw StepError(step: "拿表",
                            detail: "拷回没成（\(exportError.detail)），手机里也没存下来的表：先点探针 3 存一张表，再来还原测试。")
        }
        var container: String?
        if let export = report["export"] as? [String: Any],
           let c = export["container"] as? String, !c.isEmpty {
            container = c
        }
        guard let container else {
            throw StepError(step: "拿表",
                            detail: "拷回没成（\(exportError.detail)），已存的表找到了（\(kind)），但拿不到 PosterBoard 容器路径，接着做不了。")
        }
        return (db, walURL, container, kind, savedDate)
    }

    private static func callSaveFFI(pairingPath: String, destDir: String, stamp: String)
        -> (rc: Int32, json: String?, error: String?) {
        "10.7.0.1".withCString { _ = al_set_target_host($0) }
        var outJson: UnsafeMutablePointer<CChar>? = nil
        var outError: UnsafeMutablePointer<CChar>? = nil
        let rc = pairingPath.withCString { pairC in
            destDir.withCString { destC in
                stamp.withCString { stampC in
                    al_probe_posterboard_save(pairC, destC, stampC,
                                              airliftLogCallback, nil, &outJson, &outError)
                }
            }
        }
        var json: String? = nil
        var error: String? = nil
        if let p = outJson { json = String(cString: p); al_string_free(p) }
        if let p = outError { error = String(cString: p); al_string_free(p) }
        return (rc, json, error)
    }

    // MARK: - 合 -wal（只改副本）

    /// 把存下来的表复制一份，把同名 -wal 拷到它旁边，checkpoint 合进主库。
    /// 返回合完的副本路径；合完验一下 integrity_check。
    private static func mergeStore(savedDB: URL, savedWAL: URL?, workDir: URL) throws -> URL {
        let fm = FileManager.default
        let merged = workDir.appendingPathComponent("merged.sqlite3")
        do {
            try fm.copyItem(at: savedDB, to: merged)
        } catch {
            throw StepError(step: "合库", detail: "复制表到工作区失败：\(error.localizedDescription)")
        }
        if let wal = savedWAL, fm.fileExists(atPath: wal.path) {
            try? fm.copyItem(at: wal, to: URL(fileURLWithPath: merged.path + "-wal"))
        }
        var db: OpaquePointer?
        guard sqlite3_open(merged.path, &db) == SQLITE_OK, let db else {
            throw StepError(step: "合库", detail: "打不开合库用的副本。")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) == SQLITE_OK else {
            throw StepError(step: "合库", detail: "checkpoint 没过：\(String(cString: sqlite3_errmsg(db)))")
        }
        var integrity = ""
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK,
           let stmt = stmt {
            if sqlite3_step(stmt) == SQLITE_ROW, let t = sqlite3_column_text(stmt, 0) {
                integrity = String(cString: t)
            }
            sqlite3_finalize(stmt)
        }
        guard integrity == "ok" else {
            throw StepError(step: "合库", detail: "integrity_check：\(integrity.isEmpty ? "没读到" : integrity)")
        }
        return merged
    }

    /// 在缝好的表里按 UUID 查新 posterId；查不到说明插行没落下去。
    private static func posterIdOfStitched(staged: URL, uuid: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(staged.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw StepError(step: "插行", detail: "缝好的表打不开，没法验新行。")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT posterId FROM poster WHERE UUID = ?;",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw StepError(step: "插行", detail: "查新行失败：\(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_bind_text(stmt, 1, uuid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw StepError(step: "插行", detail: "缝完在表里找不到新 UUID 的行。")
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - 写文件（直写那条 AirTraffic 写通道）

    /// 载荷按父目录分组，每组平铺进一个临时目录，调一次
    /// al_exploit_write_dir 写进容器里对应的目录。返回写了几个文件。
    private static func writePayloadFiles(payloads: [BackupPayload], container: String,
                                          pairingPath: String) throws -> Int {
        let fm = FileManager.default
        var groups: [String: [(leaf: String, data: Data)]] = [:]
        for payload in payloads {
            let parent = (payload.relativePath as NSString).deletingLastPathComponent
            let leaf = (payload.relativePath as NSString).lastPathComponent
            let data: Data
            do {
                data = try payload.bytes()
            } catch {
                throw StepError(step: "写文件", detail: "载荷 \(payload.label) 读不出来：\(error.localizedDescription)")
            }
            groups[parent, default: []].append((leaf: leaf, data: data))
        }
        var written = 0
        for (parent, files) in groups.sorted(by: { $0.key < $1.key }) {
            let groupDir = fm.temporaryDirectory
                .appendingPathComponent("wallive-clone-restore-group-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: groupDir, withIntermediateDirectories: true)
                for file in files {
                    try file.data.write(to: groupDir.appendingPathComponent(file.leaf))
                }
                try writeDirFFI(pairingPath: pairingPath, sourceDir: groupDir.path,
                                targetDir: container + "/" + parent)
                written += files.count
            } catch let e as StepError {
                try? fm.removeItem(at: groupDir)
                throw e
            } catch {
                try? fm.removeItem(at: groupDir)
                throw StepError(step: "写文件", detail: "写 \(parent) 失败：\(error.localizedDescription)")
            }
            try? fm.removeItem(at: groupDir)
        }
        return written
    }

    /// al_exploit_write_dir 的同步小包装（调用方已在后台线程）。
    private static func writeDirFFI(pairingPath: String, sourceDir: String,
                                    targetDir: String) throws {
        "10.7.0.1".withCString { _ = al_set_target_host($0) }
        var outError: UnsafeMutablePointer<CChar>? = nil
        let rc = pairingPath.withCString { pairC in
            sourceDir.withCString { srcC in
                targetDir.withCString { tgtC in
                    al_exploit_write_dir(pairC, srcC, tgtC, airliftLogCallback, nil, &outError)
                }
            }
        }
        if rc != 0 {
            let detail: String
            if let p = outError { detail = String(cString: p); al_string_free(p) }
            else { detail = "未知错误" }
            throw StepError(step: "写文件", detail: detail)
        }
    }

    // MARK: - 写回表（新 Rust FFI）

    private static func callWritebackFFI(pairingPath: String, stagedDir: String,
                                         targetDir: String) throws -> [String: Any] {
        "10.7.0.1".withCString { _ = al_set_target_host($0) }
        var outJson: UnsafeMutablePointer<CChar>? = nil
        var outError: UnsafeMutablePointer<CChar>? = nil
        let rc = pairingPath.withCString { pairC in
            stagedDir.withCString { stagedC in
                targetDir.withCString { tgtC in
                    al_restore_posterboard_writeback(pairC, stagedC, tgtC,
                                                     airliftLogCallback, nil, &outJson, &outError)
                }
            }
        }
        var json: String? = nil
        var error: String? = nil
        if let p = outJson { json = String(cString: p); al_string_free(p) }
        if let p = outError { error = String(cString: p); al_string_free(p) }
        guard rc == 0, let json,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StepError(step: "写回表", detail: "写回通道没通：\(error ?? "未知错误")")
        }
        return obj
    }

    // MARK: - 列出表里 poster 有哪几行（只读）

    /// 读手机里已存的那张表（merged.sqlite3，没有就拿最新存下来的那份），
    /// 不重新拷。只读：先只读打开，读不了就拷一份副本再读，原表一个字不动。
    /// 返回页面上一行结论 + 完整 JSON（写日志框）。
    static func listPosterRows() -> (summary: String, json: String) {
        var report: [String: Any] = ["channel": "restore_list_rows", "success": false]
        let fm = FileManager.default
        let dir = tableDir
        let merged = dir.appendingPathComponent("merged.sqlite3")
        var source: URL?
        var sourceKind = ""
        if fm.fileExists(atPath: merged.path) {
            source = merged
            sourceKind = "merged.sqlite3"
        } else {
            let saved = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let candidates = saved
                .filter { $0.lastPathComponent.hasPrefix("PBFPosterExtensionDataStoreSQLiteDatabase-")
                    && $0.pathExtension == "sqlite3" }
                .sorted { (a, b) in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    return da > db
                }
            if let newest = candidates.first {
                source = newest
                sourceKind = newest.lastPathComponent
            }
        }
        guard let dbURL = source else {
            let summary = "列不出来：表还没存下来，先点探针 3 存一张表，再来列。"
            report["error"] = summary
            return (summary, jsonString(report))
        }
        report["source"] = dbURL.path
        report["source_kind"] = sourceKind
        // 只读打开；WAL 库没 sidecar 时只读打不开，就拷一份副本再读。
        var db: OpaquePointer?
        var openedCopy: URL?
        var openMode = "readonly"
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let opened = db {
            db = opened
            var stmt: OpaquePointer?
            let ok = sqlite3_prepare_v2(opened, "SELECT 1 FROM sqlite_master LIMIT 1;",
                                        -1, &stmt, nil) == SQLITE_OK
            sqlite3_finalize(stmt)
            if !ok {
                sqlite3_close(opened)
                db = nil
            }
        } else if let opened = db {
            sqlite3_close(opened)
            db = nil
        }
        if db == nil {
            let copy = fm.temporaryDirectory
                .appendingPathComponent("wallive-clone-list-\(UUID().uuidString).sqlite3")
            do {
                try fm.copyItem(at: dbURL, to: copy)
            } catch {
                let summary = "列不出来：表拷一份副本失败：\(error.localizedDescription)"
                report["error"] = summary
                return (summary, jsonString(report))
            }
            openedCopy = copy
            openMode = "copy"
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                  let opened = db else {
                if let leaked = db { sqlite3_close(leaked) }
                let summary = "列不出来：表打不开（原表和副本都打不开）。"
                report["error"] = summary
                try? fm.removeItem(at: copy)
                return (summary, jsonString(report))
            }
            db = opened
        }
        guard let db else {
            let summary = "列不出来：表打不开。"
            report["error"] = summary
            return (summary, jsonString(report))
        }
        defer {
            sqlite3_close(db)
            if let copy = openedCopy { try? fm.removeItem(at: copy) }
        }
        report["open_mode"] = openMode
        // 表名列表（按实际查到的写）。
        var tables: [String] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;",
                              -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let t = sqlite3_column_text(stmt, 0) { tables.append(String(cString: t)) }
            }
            sqlite3_finalize(stmt)
        }
        report["tables"] = tables
        guard tables.contains("poster") else {
            let summary = "表里没有 poster 这张表（有的表：\(tables.isEmpty ? "没有" : tables.joined(separator: "、"))）。"
            report["error"] = summary
            return (summary, jsonString(report))
        }
        // poster 有哪些列就列哪些，不编没有的字段。
        var columns: [String] = []
        if sqlite3_prepare_v2(db, "PRAGMA table_info(poster);", -1, &stmt, nil) == SQLITE_OK,
           let stmt = stmt {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let t = sqlite3_column_text(stmt, 1) { columns.append(String(cString: t)) }
            }
            sqlite3_finalize(stmt)
        }
        report["columns"] = columns
        guard !columns.isEmpty else {
            let summary = "列不出来：poster 表的列读不出来。"
            report["error"] = summary
            return (summary, jsonString(report))
        }
        // 当前选中的是哪几张（SELECTED 行）。
        var selectedUUIDs: [String] = []
        if sqlite3_prepare_v2(db,
                              "SELECT posterUUID FROM posterAttributes WHERE roleId = 'PRPosterRoleLockScreen' AND attributeIdentifier = 'SELECTED';",
                              -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let t = sqlite3_column_text(stmt, 0) { selectedUUIDs.append(String(cString: t)) }
            }
            sqlite3_finalize(stmt)
        }
        report["selected_uuids"] = selectedUUIDs
        // 逐行读出来。
        let orderBy = columns.contains("posterId") ? " ORDER BY posterId" : ""
        let selectList = columns.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ", ")
        var rows: [[String: Any]] = []
        if sqlite3_prepare_v2(db, "SELECT \(selectList) FROM poster\(orderBy);",
                              -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: Any] = [:]
                for (index, column) in columns.enumerated() {
                    switch sqlite3_column_type(stmt, Int32(index)) {
                    case SQLITE_INTEGER:
                        row[column] = Int(sqlite3_column_int64(stmt, Int32(index)))
                    case SQLITE_NULL:
                        row[column] = NSNull()
                    default:
                        if let t = sqlite3_column_text(stmt, Int32(index)) {
                            row[column] = String(cString: t)
                        } else {
                            row[column] = NSNull()
                        }
                    }
                }
                if let uuid = row["UUID"] as? String {
                    row["selected"] = selectedUUIDs.contains(uuid)
                }
                rows.append(row)
            }
            sqlite3_finalize(stmt)
        }
        report["rows"] = rows
        report["row_count"] = rows.count
        report["success"] = true
        let summary = "表里共 \(rows.count) 行（来源：\(sourceKind)，\(openMode == "readonly" ? "只读打开" : "拷副本读")，当前选中的 \(selectedUUIDs.count) 张）。完整列表见下面日志框。"
        return (summary, jsonString(report))
    }

    // MARK: - 小工具

    private static func timeStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    /// 给日志看的日期（yyyy-MM-dd HH:mm），只给兜底那句日志用。
    private static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}
