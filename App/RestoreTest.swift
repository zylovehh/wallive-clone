// RestoreTest.swift
// 备份还原（改表还原）的引擎：把一张壁纸真正装进图库。
// 原来是状态页上的还原测试按钮，正式版已接进 BackupInstallFlow；
// 探针按钮（探针 3、列出行、还原测试）已拿掉，引擎留在这里。
// 拿表走的还是探针 3 那条 AirTraffic 拷回通道（只读拷回 + 存盘），
// 按钮没了，通道还在用。
//
// 流程（一步断了就停，不继续往下走；步号和下面代码里的注释一致）：
//   1. 拿表：走探针 3 同一条 AirTraffic 拷回通道，把 v61 的表和 -wal
//      拷回来、存进 Documents/posterboard-table（原表先另存一份备份）。
//      拷不回来就改用已存的表（先找 merged.sqlite3，没有就找最新存
//      下来的那份），日志里写明用的是已存的表，不假装刚拷回来。
//   2. 合 -wal：只改一份副本，原表不动；合完验库。
//   3. 编包：复用备份路的 PosterBoardCompiler.compile，把选中包编成
//      configurations/<新 UUID> 的载荷。编包器只产 configurations 载荷，
//      描述符另外从暂存树注入（见第 4b 步）：编包器注释里那句“descriptors
//      双写会逼商店重建、壁纸全没”，在 27.0.1 上已被直装证伪——直装每次
//      都写 descriptors（两到三处），也没重建丢过；真正要防的只是身份重复，
//      新 UUID 已保证不撞。
//   4. 写文件：载荷按父目录分组，走直写那条 AirTraffic 写通道
//     （al_exploit_write_dir，偏好重写已证实它能覆盖已有文件）写进
//      PosterBoard 容器。
//   4b. 写描述符：暂存树里 stage/descriptors/<原 UUID>/ 拷一份副本，把
//      三个身份字段改成编包器给 configurations 用的同一个数字 id，再用
//      直装同一条 al_exploit_inject_folder 注入主扩展 + 现代扩展的
//      descriptors/<新 UUID>（图库描述符通道；直装每次都写，之前还原没写，
//      加新壁纸页面里就看不到）。Mercury 不改 id，原样注入。
//   5. 插行：复用备份路的 PosterBoardStore.stitch（照金块 update_sqlite
//      搬的：posterId 取 MAX+1，三张表先改后插，sqlite_sequence 同步，
//      0 字节 -wal/-shm 伴生），只改一份拷贝，原表不动。
//   6. 写回表：新 Rust FFI al_restore_posterboard_writeback 把改好的
//      表（+ 0 字节 -wal/-shm）写回商店目录。
//   7. 写偏好：照直装同一份 PosterBoard 偏好写一次（重载开关），
//      让系统重载描述符、重新索引。
//   8. 刷新：调一次 al_posterboard_refresh 杀 PosterBoard 重读；刷新失败
//      不算错，只是还得重启手机再看。
//   9. 提示用户去图库长按看有没有这张壁纸（刷新确认了不用重启也行）。
//
// 注意：
// - 正式版已接进 BackupInstallFlow（备份还原那条路）；直写、备份、探针 3
//   的通道都不动，只是探针按钮拿掉了，引擎留在这里。
// - SQL 插行不在 Rust 里做：Rust 那个包没有 SQLite 库（没 rusqlite，
//   离线锁定构建加不进去），插行走 Swift 自带的 SQLite3，和探针 3
//   合库那套一样；Rust 只做它才能做的事（隧道 + AirTraffic 写回）。
// - 写回是活机写：PosterBoard 进程还开着旧表，写完马上调刷新；刷新
//   确认了不用重启，没确认再重启手机看。重启前别去图库里划来划去。

import Foundation
import AirliftFFI
import SQLite3

/// 备份还原一次跑完的结果（页面只显示 summary 这一行，完整 JSON 进日志框）。
/// 原来是状态页上的还原测试按钮用的，正式版已接进 BackupInstallFlow；
/// 探针按钮已拿掉，引擎留在这里，正式备份路调 runRestore。
struct RestoreOutcome {
    let success: Bool
    let summary: String
    let descriptorUUID: String?
    let posterId: Int?
    /// 正式备份路要用的字段（状态页只看 summary，这些是给 BackupInstallFlow 的）。
    let extensionID: String?
    /// configurations 写了几个文件。
    let payloadCount: Int?
    /// 插行后的商店摘要。
    let storeSummary: String?
    /// 成功时一定是 true（写偏好是必经步骤，失败就停了）。
    let preferencesWritten: Bool
    let refreshConfirmed: Bool
    /// 描述符注入逐目标结果（主扩展 + 现代扩展）。
    let injectResults: [InjectResult]
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

    /// 拿表加 30 秒超时：拷回通道等手机回表可能死等（00:37 那次就卡在
    /// 10% 不动），30 秒没回来就是卡住了，当这次拷回失败——外层会改用
    /// 已存的表接着做，没已存的表才停下来报。成功的拷回都是很快回来的，
    /// 超时短一点不影响成功，只是不让用户干等。超时的那次调用还在后台
    /// 跑，结果丢弃，不阻塞后面的步骤。
    private static func exportAndSaveTimed(pairingPath: String, stamp: String,
                                           report: inout [String: Any],
                                           timeout: TimeInterval = 30) throws
        -> (savedDB: URL, savedWAL: URL?, container: String) {
        let box = ExportResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var workerReport: [String: Any] = ["channel": "restore_test"]
            do {
                let fresh = try exportAndSave(pairingPath: pairingPath, stamp: stamp, report: &workerReport)
                box.set(.success((fresh.savedDB, fresh.savedWAL, fresh.container)), report: workerReport)
            } catch {
                box.set(.failure(error), report: workerReport)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw StepError(step: "拿表", detail: "取表超时（\(Int(timeout)) 秒没等到手机回表）。重启手机一次再试。")
        }
        // 没超时：把 worker 那边记进 report 的键合回来（失败时也要合，
        // 兜底要从 report["export"] 里拿容器路径）。
        for (key, value) in box.report { report[key] = value }
        guard let result = box.result else {
            throw StepError(step: "拿表", detail: "取表没回结果。")
        }
        switch result {
        case .success(let fresh): return fresh
        case .failure(let error): throw error
        }
    }

    /// 跨线程传一次拿表结果：写的那边只写一次，读的那边在信号量之后读。
    private final class ExportResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _result: Result<(savedDB: URL, savedWAL: URL?, container: String), Error>?
        private var _report: [String: Any] = [:]
        var result: Result<(savedDB: URL, savedWAL: URL?, container: String), Error>? {
            lock.lock(); defer { lock.unlock() }
            return _result
        }
        var report: [String: Any] {
            lock.lock(); defer { lock.unlock() }
            return _report
        }
        func set(_ result: Result<(savedDB: URL, savedWAL: URL?, container: String), Error>,
                 report: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            _result = result
            _report = report
        }
    }

    /// 把刚写回的那张表存成已存表（merged.sqlite3），下次拿表失败时兜底用。
    /// 只在安装成功时调（写回已成，staged 就是手机上那张最新的表）。
    /// 拷失败不抛错、不拦安装，只记日志，下次兜底仍用旧表。
    private static func updateStoredTable(from staged: URL) {
        let fm = FileManager.default
        let dest = tableDir.appendingPathComponent("merged.sqlite3")
        do {
            try fm.createDirectory(at: tableDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: staged, to: dest)
            // staged 是自带完整数据的单文件（写回时配 0 字节 -wal），
            // 旁边要是有旧 -wal 残留会误导下次合库，一并清掉。
            try? fm.removeItem(at: URL(fileURLWithPath: dest.path + "-wal"))
            InstallLog.shared.append("restore: 已存表已更新成刚写回的那张（merged.sqlite3）。")
        } catch {
            InstallLog.shared.append("restore: 已存表更新失败（\(error.localizedDescription)），下次兜底仍用旧表。")
        }
    }

    /// 跑一次备份还原。调用方必须已经在后台线程（FFI 和 SQLite 都会阻塞）。
    /// packageData：导入页当前选中的那个包；没选中包就直接报，不编默认包。
    /// onProgress：步骤进度（拿表 30% → 写文件 50% → 插行 70% → 写回 85% →
    /// 刷新 100%），调用方在主线程更新 UI。isCancelled：步骤之间查取消，
    /// 用户点了停止就立刻停，不等整轮跑完。
    static func runRestore(packageData: Data, pairingPath: String,
                           onProgress: ((String, Double) -> Void)? = nil,
                           isCancelled: @escaping () -> Bool = { false }) -> RestoreOutcome {
        var report: [String: Any] = ["channel": "restore_test", "success": false]
        do {
            let outcome = try restore(packageData: packageData, pairingPath: pairingPath, report: &report,
                                      onProgress: onProgress, isCancelled: isCancelled)
            report["success"] = true
            InstallLog.shared.append("restore: json=\(jsonString(report))")
            return outcome
        } catch is CancellationError {
            // 用户点了停止：不当失败报，调用方按“已停止”关弹窗。
            InstallLog.shared.append("restore: 已停止（用户点了停止）。")
            return RestoreOutcome(
                success: false,
                summary: "已停止。",
                descriptorUUID: nil, posterId: nil, extensionID: nil, payloadCount: nil,
                storeSummary: nil, preferencesWritten: false, refreshConfirmed: false,
                injectResults: [], json: jsonString(report))
        } catch let e as StepError {
            report["step"] = e.step
            report["error"] = e.detail
            InstallLog.shared.append("restore: FAILED \(e.step)：\(e.detail) json=\(jsonString(report))")
            return RestoreOutcome(
                success: false,
                summary: "备份还原停在\(e.step)：\(e.detail)原来的表还在 Documents/posterboard-table 里，没动。完整结果见下面日志框。",
                descriptorUUID: nil, posterId: nil, extensionID: nil, payloadCount: nil,
                storeSummary: nil, preferencesWritten: false, refreshConfirmed: false,
                injectResults: [], json: jsonString(report))
        } catch {
            report["error"] = error.localizedDescription
            InstallLog.shared.append("restore: FAILED \(error.localizedDescription) json=\(jsonString(report))")
            return RestoreOutcome(
                success: false,
                summary: "备份还原失败：\(error.localizedDescription)完整结果见下面日志框。",
                descriptorUUID: nil, posterId: nil, extensionID: nil, payloadCount: nil,
                storeSummary: nil, preferencesWritten: false, refreshConfirmed: false,
                injectResults: [], json: jsonString(report))
        }
    }

    /// 步骤之间查取消：用户点了停止就立刻停，不等整轮跑完。
    private static func checkCancelled(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }

    private static func restore(packageData: Data, pairingPath: String,
                                report: inout [String: Any],
                                onProgress: ((String, Double) -> Void)?,
                                isCancelled: @escaping () -> Bool) throws -> RestoreOutcome {
        try checkCancelled(isCancelled)
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
            let fresh = try exportAndSaveTimed(
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
        try checkCancelled(isCancelled)
        onProgress?("正在写文件…", 0.30)

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
        //    原描述符 UUID 要留住：描述符注入那步要从暂存树里拿
        //    stage/descriptors/<原UUID>/。
        let installer = DescriptorInstaller(zip: ZipFoundationAdapter())
        let stage: URL
        let descriptorUUID: String
        do {
            (stage, descriptorUUID) = try installer.stage(packageData)
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

        // 4b. 写描述符：直装每次都写、之前还原没写的那一步（图库描述符通道）。
        //     暂存树里现成的 stage/descriptors/<原UUID>/ 拷一份副本，把三个
        //     身份字段改成编包器给 configurations 用的同一个数字 id，再用直装
        //     同一条 al_exploit_inject_folder 注入主扩展 + 现代扩展的
        //     descriptors/<新UUID>。主目标失败就停，别的目标只记进报告。
        let descriptorResults = try injectDescriptors(
            stage: stage, descriptorUUID: descriptorUUID, config: firstConfig,
            container: container, pairingPath: pairingPath)
        report["descriptors"] = descriptorResults
        try checkCancelled(isCancelled)
        onProgress?("正在插行…", 0.50)

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
        try checkCancelled(isCancelled)
        onProgress?("正在写回表…", 0.70)

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

        // 7. 写偏好：照直装同一份 PosterBoard 偏好写一次（重载开关），
        //    让系统重载描述符、重新索引。容器内那份失败就停，全局那份尽力写。
        try writePosterBoardPreferences(container: container, pairingPath: pairingPath)
        report["preferences_written"] = true
        try checkCancelled(isCancelled)
        onProgress?("正在刷新…", 0.85)

        // 8. 刷新：调一次 al_posterboard_refresh（杀 PosterBoard、等它重起重读），
        //    结果只记进报告、不抛错；没确认就还是得重启手机再看。
        let refresh = posterboardRefresh(pairingPath: pairingPath)
        report["refresh"] = refresh
        let refreshConfirmed = refresh["confirmed"] as? Bool ?? false
        onProgress?("刷新完成", 1.0)

        // 已存表更新成刚写回的那张：下次拿表万一拷不回来，兜底用的就是
        // 最新的表（带这次新插的行），不会拿旧表把上一张顶掉。
        // 走到这里写回已经成了；拷失败只记日志，不拦安装。
        updateStoredTable(from: staged)

        let usedStored = (report["table_source"] as? String) == "stored"
        let descriptorInjects = descriptorResults.map {
            InjectResult(targetParentDir: $0["target"] as? String ?? "",
                         ok: $0["ok"] as? Bool ?? false,
                         error: $0["error"] as? String)
        }
        let summary = "备份还原成功：新 posterId \(newPosterId)，描述符 \(firstConfig.uuid)，文件写了 \(filesWritten) 个、描述符已注入、偏好已写、表已写回\(usedStored ? "（这次用的是手机里已存的表，不是刚拷回来的）" : "")。\(refreshConfirmed ? "PosterBoard 已刷新，去图库长按看有没有这张壁纸。" : "刷新没确认，重启手机，再去图库长按看有没有这张壁纸。")完整结果见下面日志框."
        return RestoreOutcome(success: true, summary: summary,
                              descriptorUUID: firstConfig.uuid, posterId: newPosterId,
                              extensionID: firstConfig.extensionID, payloadCount: filesWritten,
                              storeSummary: report["store_after"] as? String,
                              preferencesWritten: true, refreshConfirmed: refreshConfirmed,
                              injectResults: descriptorInjects,
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

    // MARK: - 写描述符（图库描述符通道，直装每次都做）

    /// 暂存树里现成的 stage/descriptors/<原UUID>/ 拷一份副本，把三个身份字段
    /// 改成编包器给 configurations 用的同一个数字 id，再用直装同一条
    /// al_exploit_inject_folder 注入主扩展 + 现代扩展的 descriptors/<新UUID>。
    /// 目标清单照直装的 dualExtensions（Collections 双向、Mercury 双向）。
    /// 主目标失败就停（和直装一样）；别的目标只记进报告、继续。
    private static func injectDescriptors(stage: URL, descriptorUUID: String,
                                          config: PosterBoardConfigItem,
                                          container: String, pairingPath: String) throws -> [[String: Any]] {
        let fm = FileManager.default
        let source = stage.appendingPathComponent("descriptors").appendingPathComponent(descriptorUUID)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw StepError(step: "写描述符", detail: "暂存树里找不到描述符目录：descriptors/\(descriptorUUID)")
        }
        // 拷一份副本再改 id，不动暂存原树。
        let copyDir = fm.temporaryDirectory
            .appendingPathComponent("wallive-clone-restore-desc-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: copyDir)
        } catch {
            throw StepError(step: "写描述符", detail: "描述符目录拷副本失败：\(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: copyDir) }
        // 身份对齐：和 configurations 载荷里编包器用的同一个数字 id。
        // Mercury 不改（编包器也没改它的 id，numericId 是 nil），原样注入。
        if let numericId = config.numericId {
            rewriteDescriptorIdentity(in: copyDir, identifier: numericId)
        }
        let storeBase = container + PosterBoard.storePath(storeVersion)
        let targets = AirliftInstaller.dualExtensions(for: config.extensionID).map {
            "\(storeBase)/Extensions/\($0)/descriptors"
        }
        var results: [[String: Any]] = []
        for (index, targetParent) in targets.enumerated() {
            do {
                try injectFolderFFI(folderURL: copyDir, targetParentDir: targetParent,
                                    destName: config.uuid, pairingPath: pairingPath)
                results.append(["target": targetParent, "ok": true])
                InstallLog.shared.append("restore: 描述符已注入 \(targetParent)/\(config.uuid)")
            } catch let e as StepError {
                results.append(["target": targetParent, "ok": false, "error": e.detail])
                if index == 0 {
                    throw StepError(step: "写描述符", detail: e.detail)
                }
                InstallLog.shared.append("restore: 描述符注入 \(targetParent) 没成（\(e.detail)），继续。")
            }
        }
        return results
    }

    /// al_exploit_inject_folder 的同步小包装（调用方已在后台线程）。
    private static func injectFolderFFI(folderURL: URL, targetParentDir: String,
                                        destName: String, pairingPath: String) throws {
        "10.7.0.1".withCString { _ = al_set_target_host($0) }
        var outError: UnsafeMutablePointer<CChar>? = nil
        let rc = pairingPath.withCString { pairC in
            folderURL.path.withCString { folderC in
                targetParentDir.withCString { parentC in
                    destName.withCString { destC in
                        al_exploit_inject_folder(pairC, folderC, parentC, destC,
                                                 airliftLogCallback, nil, &outError)
                    }
                }
            }
        }
        if rc != 0 {
            let detail: String
            if let p = outError { detail = String(cString: p); al_string_free(p) }
            else { detail = "未知错误" }
            throw StepError(step: "写描述符", detail: detail)
        }
    }

    /// 把描述符副本里的三个身份字段改成编包器给 configurations 用的那个数字 id，
    /// 照编包器同一套写法：sidecar 写文本、userInfo 的 wallpaperRepresentingIdentifier
    /// 写文本、Wallpaper.plist 的 identifier 写数字（直装 randomizeIdentifiers
    /// 那套只改纯数字处，这里也一样——sidecar 内容不是纯数字就不动，文本查找键不能动）。
    /// 编包器在 configurations 那边缺 sidecar 时会补一份，这里也一样：副本根目录
    /// 没有就补一个。
    private static func rewriteDescriptorIdentity(in folderURL: URL, identifier: Int) {
        let fm = FileManager.default
        let sidecarName = "com.apple.posterkit.provider.descriptor.identifier"
        guard let enumerator = fm.enumerator(at: folderURL,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return }
        while let fileURL = enumerator.nextObject() as? URL {
            let fileName = fileURL.lastPathComponent
            if fileName == sidecarName {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8),
                   Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                    try? String(identifier).data(using: .utf8)?.write(to: fileURL)
                }
            } else if fileName == "com.apple.posterkit.provider.contents.userInfo" {
                if let updated = try? PosterBoardPlist.set(
                    contentsOf: fileURL, key: "wallpaperRepresentingIdentifier",
                    value: String(identifier), recursive: false) {
                    try? updated.write(to: fileURL)
                }
            } else if fileName.hasSuffix("Wallpaper.plist") {
                if let updated = try? PosterBoardPlist.set(
                    contentsOf: fileURL, key: "identifier",
                    value: identifier, recursive: false) {
                    try? updated.write(to: fileURL)
                }
            }
        }
        let sidecar = folderURL.appendingPathComponent(sidecarName)
        if !fm.fileExists(atPath: sidecar.path) {
            try? String(identifier).data(using: .utf8)?.write(to: sidecar)
        }
    }

    // MARK: - 写偏好 + 刷新（照直装同一份内容）

    /// 写一次 PosterBoard 偏好（照直装 writePosterBoardPreferences 同一份内容：
    /// PBF_RESET_FILE_PROTECTIONS / PBF_LOCALE_DID_CHANGE + 两份 bundle 清单），
    /// 让系统重载描述符、重新索引。容器内那份失败就停；系统全局那份尽力写，
    /// 失败不算错（和直装一样）。
    /// 同步版：直装那个是 async（跑在 runBlocking 里），这里调用方已在后台线程，
    /// 直接调 writeDirFFI。
    private static func writePosterBoardPreferences(container: String, pairingPath: String) throws {
        let fm = FileManager.default
        let stageDir = fm.temporaryDirectory
            .appendingPathComponent("wallive-clone-restore-prefs-\(UUID().uuidString)")
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }
        let prefURL = stageDir.appendingPathComponent("com.apple.PosterBoard.unprotectedUserDefaults.plist")
        let prefDict: [String: Any] = [
            "PBF_RESET_FILE_PROTECTIONS": true,
            "PBF_LOCALE_DID_CHANGE": true,
            "PersistedPosterContainerBundleIdentifiers": [
                "com.apple.Posters.CollectionsPosterApp",
                "com.apple.WallpaperKit.CollectionsPoster",
                "com.apple.MercuryPoster",
                "com.apple.Posters.MercuryPosterApp",
                "com.apple.PhotosUIPrivate.PhotosPosterProvider",
            ],
            "CompletedPosterBundleIdentifierMigrations": [
                "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
                "com.apple.Posters.WeatherPosterApp.WeatherPoster",
                "com.apple.Posters.UnityPosterApp.Unity2025Poster",
                "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
                "com.apple.Posters.RhizomePoster",
                "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster",
            ],
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: prefDict, format: .binary, options: 0)
        try plistData.write(to: prefURL)
        do {
            try writeDirFFI(pairingPath: pairingPath, sourceDir: stageDir.path,
                            targetDir: container + "/Library/Preferences")
        } catch let e as StepError {
            throw StepError(step: "写偏好", detail: e.detail)
        }
        // 系统全局偏好也写一份（失败不算错，直装里同样是尽力写）。
        _ = try? writeDirFFI(pairingPath: pairingPath, sourceDir: stageDir.path,
                             targetDir: "/var/mobile/Library/Preferences")
    }

    /// 调一次 al_posterboard_refresh（杀 PosterBoard 进程、等它重起重读），
    /// 结果只记进报告和日志、不抛错：刷新只是事后触发，写盘和写回已经成了。
    private static func posterboardRefresh(pairingPath: String) -> [String: Any] {
        "10.7.0.1".withCString { _ = al_set_target_host($0) }
        var outJson: UnsafeMutablePointer<CChar>? = nil
        var outError: UnsafeMutablePointer<CChar>? = nil
        let rc = pairingPath.withCString { pairC in
            al_posterboard_refresh(pairC, airliftLogCallback, nil, &outJson, &outError)
        }
        var result: [String: Any] = ["attempted": true, "rc": rc, "confirmed": false]
        if let p = outJson {
            let json = String(cString: p)
            al_string_free(p)
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result["json"] = obj
                result["confirmed"] = obj["refresh_confirmed"] as? Bool ?? false
            }
            InstallLog.shared.append("restore: 刷新 PosterBoard：\(json)")
        }
        if let p = outError {
            let error = String(cString: p)
            al_string_free(p)
            result["error"] = error
            InstallLog.shared.append("restore: 刷新 PosterBoard 没回 JSON：\(error)")
        }
        return result
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
