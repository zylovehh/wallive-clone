// RestoreTest.swift
// 备份还原（改表还原）的引擎：把一张壁纸真正装进图库。
// 原来是状态页上的还原测试按钮，正式版已接进 BackupInstallFlow；
// 探针按钮（探针 3、列出行、还原测试）已拿掉，引擎留在这里。
// 拿表先走 Phase 0 备份（做一份带 PosterBoard 的备份、再从备份里把表
// 抽出来）；备份拿不到表再走探针 3 那条 AirTraffic 拷回通道；拷回
// 也不成改用已存的表；三级全断、且手机里一张存过的表都没有时，
// 现场造一张空名单接着装（第 4 级，27.2 第一次用的兜底）。
// 按钮没了，通道还在用。
//
// 流程（一步断了就停，不继续往下走；步号和下面代码里的注释一致）：
//   1. 拿表：先试 Phase 0 备份拿表（备份 → 抽表合 WAL），再试探针 3
//      同一条 AirTraffic 拷回通道（v61 的表 + -wal，存进
//      Documents/posterboard-table，原表先另存一份备份）。
//      都拷不回来就改用已存的表（先找 merged.sqlite3，没有就找最新存
//      下来的那份），日志里写明用的是已存的表，不假装刚拷回来。
//      三级全断、且确认手机里一张存过的表都没有时，现场造一张空名单
//      （第 4 级：先核包、再单拿容器路径、再造库验库），接着往下装。
//      存过的表还在时绝不造空名单——造空名单会把好端端的名单替掉。
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
    /// 刷新失败且 PosterBoard 杀掉后没回来时为 true：只有重启手机能让它
    /// 重读新表，导入页备份装完给用户一个“重启手机”按钮（用户亲手点才重启）。
    let rebootNeeded: Bool
    /// 这次走的是哪条路（默认备份还原，测试版是 `.test`）。报告 JSON 里
    /// 同样记 `mode` / `method`（"test" / "backup"）。
    let mode: PosterBoardApplyMode = .backup
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
                storeSummary: nil, preferencesWritten: false, refreshConfirmed: false, rebootNeeded: false,
                injectResults: [], json: jsonString(report))
        } catch let e as StepError {
            report["step"] = e.step
            report["error"] = e.detail
            InstallLog.shared.append("restore: FAILED \(e.step)：\(e.detail) json=\(jsonString(report))")
            return RestoreOutcome(
                success: false,
                summary: "备份还原停在\(e.step)：\(e.detail)原来的表还在 Documents/posterboard-table 里，没动。完整结果见下面日志框。",
                descriptorUUID: nil, posterId: nil, extensionID: nil, payloadCount: nil,
                storeSummary: nil, preferencesWritten: false, refreshConfirmed: false, rebootNeeded: false,
                injectResults: [], json: jsonString(report))
        } catch {
            report["error"] = error.localizedDescription
            InstallLog.shared.append("restore: FAILED \(error.localizedDescription) json=\(jsonString(report))")
            return RestoreOutcome(
                success: false,
                summary: "备份还原失败：\(error.localizedDescription)完整结果见下面日志框。",
                descriptorUUID: nil, posterId: nil, extensionID: nil, payloadCount: nil,
                storeSummary: nil, preferencesWritten: false, refreshConfirmed: false, rebootNeeded: false,
                injectResults: [], json: jsonString(report))
        }
    }


    // MARK: - 探针拿表（单独拿表存好，不装壁纸）

    /// 单独探针拿表的结果。summary 直接给页面显示。
    struct ProbeFetchOutcome {
        let success: Bool
        /// 成功：“表已存好（v61，282,624 字节）”；失败：原因；停止：“已停止。”
        let summary: String
        /// 成功时表的字节数。
        let dbSize: Int?
        /// 成功时表的版本（"61"）。
        let dbVersion: String?
        let json: String
    }

    /// 单独探针拿表：不装壁纸，只把表拿下来存好。
    /// 复用探针 3 那条拷回通道（exportAndSaveTimed，30 秒超时），快失败
    /// 多试 3 次（跟装壁纸时第 2 级一样的逻辑：超时不重试、两次之间等 5 秒），
    /// 拿到后校验（SQLite 头、版本 61、integrity_check），合 -wal，再存成
    /// 已存表（merged.sqlite3，跟成功安装后刷新存过的表一个做法）。
    /// 校验不过不存坏表，直接报。调用方必须已经在后台线程。
    /// isCancelled：步骤之间查取消，点了停止就直接停。
    static func probeFetchTable(pairingPath: String,
                                onProgress: ((String, Double) -> Void)? = nil,
                                isCancelled: @escaping () -> Bool = { false }) -> ProbeFetchOutcome {
        var report: [String: Any] = ["channel": "probe_fetch", "success": false]
        do {
            let outcome = try probeFetch(pairingPath: pairingPath, report: &report,
                                         onProgress: onProgress, isCancelled: isCancelled)
            report["success"] = true
            InstallLog.shared.append("probe: json=\(jsonString(report))")
            return outcome
        } catch is CancellationError {
            InstallLog.shared.append("probe: 已停止（用户点了停止）。")
            return ProbeFetchOutcome(success: false, summary: "已停止。", dbSize: nil, dbVersion: nil, json: jsonString(report))
        } catch let e as StepError {
            report["step"] = e.step
            report["error"] = e.detail
            InstallLog.shared.append("probe: FAILED \(e.step)：\(e.detail) json=\(jsonString(report))")
            return ProbeFetchOutcome(success: false, summary: e.detail, dbSize: nil, dbVersion: nil, json: jsonString(report))
        } catch {
            report["error"] = error.localizedDescription
            InstallLog.shared.append("probe: FAILED \(error.localizedDescription) json=\(jsonString(report))")
            return ProbeFetchOutcome(success: false, summary: "探针拿表失败：\(error.localizedDescription)", dbSize: nil, dbVersion: nil, json: jsonString(report))
        }
    }

    private static func probeFetch(pairingPath: String,
                                   report: inout [String: Any],
                                   onProgress: ((String, Double) -> Void)?,
                                   isCancelled: @escaping () -> Bool) throws -> ProbeFetchOutcome {
        try checkCancelled(isCancelled)
        let fm = FileManager.default
        let stamp = timeStamp()
        let workDir = fm.temporaryDirectory.appendingPathComponent("wallive-clone-probe-\(stamp)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // 1. 拷回：探针 3 同一条通道，快失败多试 3 次（跟装壁纸时第 2 级一样）。
        //    超时不重试：超时那次后台线程还在跑，再开一次会两路同时拷，互相干扰。
        onProgress?("正在拿表…", 0.1)
        var freshResult: (savedDB: URL, savedWAL: URL?, container: String)? = nil
        var lastExportError: StepError? = nil
        for attempt in 1...3 {
            try checkCancelled(isCancelled)
            onProgress?("正在拿表（第 \(attempt) 次）…", 0.1)
            do {
                freshResult = try exportAndSaveTimed(
                    pairingPath: pairingPath, stamp: stamp, report: &report)
                break
            } catch {
                lastExportError = (error as? StepError)
                    ?? StepError(step: "拿表", detail: "\(error.localizedDescription)")
                if let e = lastExportError, e.detail.hasPrefix("取表超时") { break }
                if attempt < 3 {
                    InstallLog.shared.append("probe: 拿表第 \(attempt) 次没成，等 5 秒再试一次。")
                    Thread.sleep(forTimeInterval: 5)
                    try checkCancelled(isCancelled)
                }
            }
        }
        guard let fresh = freshResult else {
            let exportError = lastExportError
                ?? StepError(step: "拿表", detail: "取表没回结果。")
            throw StepError(step: "拿表", detail: "拷回没成（\(exportError.detail)）。重启手机一次再试（拿表只有重启后第一次才稳）。")
        }
        report["table_source"] = "probe"

        // 2. 校验：是 SQLite、版本 61。校验不过不存坏表，直接停。
        onProgress?("正在校验表…", 0.5)
        try checkCancelled(isCancelled)
        try validateFetchedStore(db: fresh.savedDB, report: report)

        // 3. 合 -wal：checkpoint 合进主库，integrity_check 不过就停。
        onProgress?("正在合库…", 0.7)
        try checkCancelled(isCancelled)
        let merged = try mergeStore(savedDB: fresh.savedDB, savedWAL: fresh.savedWAL, workDir: workDir)

        // 3b. 打表结构：把真表的建表语句打到日志里（只打 CREATE TABLE，不打数据行），
        //     用来补空表缺的 posterRoles / posterMetadata。打不出来不拦路，探针照常存表。
        logTableSchema(db: merged)

        // 4. 存成已存表（merged.sqlite3），跟成功安装后刷新存过的表一个做法。
        onProgress?("正在存表…", 0.9)
        try checkCancelled(isCancelled)
        let dbSize = try saveAsStoredTable(from: merged)
        let version = storeVersionString(from: report) ?? String(storeVersion)
        InstallLog.shared.append("probe: 表已存好（v\(version)，\(dbSize) 字节），table_source=probe。")
        onProgress?("表已存好", 1.0)
        report["success"] = true
        return ProbeFetchOutcome(
            success: true,
            summary: "表已存好（v\(version)，\(dbSize) 字节）。",
            dbSize: dbSize, dbVersion: version, json: jsonString(report))
    }

    /// 打真表的建表语句到日志里：只打 CREATE TABLE（sqlite_master 的 sql 列），
    /// 不打数据行。用来补空表缺的 posterRoles / posterMetadata。
    /// 打不出来也不让探针失败，只记一行原因，探针该存表还存表。
    private static func logTableSchema(db: URL) {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle else {
            InstallLog.shared.append("probe: 表结构没打出来：表打不开。")
            if let h = handle { sqlite3_close(h) }
            return
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT sql FROM sqlite_master WHERE type='table' ORDER BY name;", -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt else {
            InstallLog.shared.append("probe: 表结构没打出来：\(String(cString: sqlite3_errmsg(handle)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        InstallLog.shared.append("probe: 表结构（sqlite_master）：")
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                InstallLog.shared.append(String(cString: text))
            }
        }
    }

    /// 校验刚拷回来的表：是 SQLite 文件、版本是 61。校验不过不存坏表，直接停。
    private static func validateFetchedStore(db: URL, report: [String: Any]) throws {
        // SQLite 文件头：前 16 字节必须是 "SQLite format 3\0"。
        let sqliteMagic: [UInt8] = [0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66,
                                    0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00]
        let data: Data
        do {
            data = try Data(contentsOf: db)
        } catch {
            throw StepError(step: "拿表", detail: "刚拷回来的表打不开，没法校验。")
        }
        guard data.count >= 16, [UInt8](data.prefix(16)) == sqliteMagic else {
            throw StepError(step: "拿表", detail: "刚拷回来的表不是 SQLite 文件，不存。")
        }
        // 版本：拷回那次 JSON 里的 db_version 必须是 61。
        let version = storeVersionString(from: report)
        guard version == String(storeVersion) else {
            throw StepError(step: "拿表", detail: "刚拷回来的表版本不对（\(version ?? "没读到")），只要 v61，不存。")
        }
    }

    /// 从拷回那次 JSON 里读 db_version（可能是字符串 "61"，也可能是数字 61）。
    private static func storeVersionString(from report: [String: Any]) -> String? {
        guard let export = report["export"] as? [String: Any] else { return nil }
        if let s = export["db_version"] as? String { return s }
        if let n = export["db_version"] as? Int { return String(n) }
        if let n = export["db_version"] as? NSNumber { return n.stringValue }
        return nil
    }

    /// 把合好的表存成已存表（merged.sqlite3），跟成功安装后刷新存过的表一个做法。
    /// 存失败就抛错（探针的重点就是存好，存不上要如实报，不悄悄吞掉）。
    /// 返回存好的字节数。
    private static func saveAsStoredTable(from merged: URL) throws -> Int {
        let fm = FileManager.default
        let dest = tableDir.appendingPathComponent("merged.sqlite3")
        do {
            try fm.createDirectory(at: tableDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: merged, to: dest)
            // 旁边要是有旧 -wal 残留会误导下次合库，一并清掉。
            try? fm.removeItem(at: URL(fileURLWithPath: dest.path + "-wal"))
        } catch {
            throw StepError(step: "拿表", detail: "表拿到了，但存成已存表失败：\(error.localizedDescription)")
        }
        guard let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue,
              size > 0 else {
            throw StepError(step: "拿表", detail: "表拿到了，但存成已存表后读不到大小。")
        }
        return size
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
        // V1.19：不分系统版本、不看配对记录，一律走 Vellum 同款路
        // （直读找库 + 逃逸直写，只写一个描述符目录，不碰表和偏好）。
        // 人家真机跑通的就是这条；备份路多出来的改表工序全停用，
        // 配对隧道一个字不碰——27.2 上不连 VPN 也装。
        return try restoreNoPairing(packageData: packageData, report: &report,
                                    onProgress: onProgress, isCancelled: isCancelled)
    }

    // MARK: - 无配对安装（Vellum 同款，只写描述符目录）

    /// 无配对安装（V1.8 起，Vellum 同款）：
    /// 1. 逃逸进应用数据总目录，翻出壁纸库，读一次表确认是系统正在读的那份库；
    /// 2. 包里的描述符目录（descriptors/<UUID>/，跟 Vellum 装好的实物同款形状：
    ///    侧标文件 + providerInfo.plist + versions/1）拷副本，三个身份字段
    ///    （描述符 sidecar、userInfo、Wallpaper.plist）对齐同一个新数字 id；
    /// 3. 只写一个目录：Extensions/com.apple.WallpaperKit.CollectionsPoster/
    ///    descriptors/<新UUID>；
    /// 4. 完事提示重启手机。不写偏好、不写 configurations、不插行、不写回表、
    ///    不清 wal/shm——Vellum 日志里数据库只读不写，行是系统重扫时自己补的。
    /// 旧路（configurations + 插表行 + 写回表）在 27.0 上重启后壁纸消失
    ///（表行还在、图库没有），就是多了那几步：系统重启按描述符重建库，
    /// 只认描述符长出来的形状。这条新路整个照 Vellum 抄。
    private static func restoreNoPairing(packageData: Data, report: inout [String: Any],
                                         onProgress: ((String, Double) -> Void)?,
                                         isCancelled: @escaping () -> Bool) throws -> RestoreOutcome {
        try checkCancelled(isCancelled)
        let fm = FileManager.default
        let stamp = timeStamp()
        let restoreStart = Date()
        let elapsed: () -> String = { String(format: "%.1fs", Date().timeIntervalSince(restoreStart)) }
        let workDir = fm.temporaryDirectory.appendingPathComponent("wallive-clone-vellum-\(stamp)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // V1.16：先体检共享抽屉，把组容器在不在、路径是什么直接写出来——
        //    逃逸被拒时不用再猜是不是签名没配组。
        let health = WorseQueryEscape.groupHealth()
        InstallLog.shared.append("vellum: 共享抽屉体检：\(health.note)")

        // 1. 逃逸 + 找壁纸库：总目录直翻（头一回也直读），翻到的容器读一次表
        //    验过才算系统在读的那份；翻不到再试上次记下的路径。
        onProgress?("正在找壁纸库…", 0.05)
        var escapeHandle: Int64? = nil
        defer { WorseQueryEscape.release(escapeHandle) }
        var container: String? = nil
        if let found = discoverAndReadDirect(workDir: workDir) {
            escapeHandle = found.handle
            container = found.container
            report["escape"] = ["ok": true, "detail": "总目录直翻"]
            InstallLog.shared.append("vellum: 壁纸库找到了（\(elapsed())）：\(found.container)。")
        }
        if container == nil, let cached = cachedContainerPath() {
            let esc = WorseQueryEscape.consume(target: cached, log: {
                InstallLog.shared.append("vellum: \($0)")
            })
            if let h = esc.handle {
                if readStoreDirect(container: cached, workDir: workDir) != nil {
                    escapeHandle = h
                    container = cached
                    report["escape"] = ["ok": true, "detail": esc.detail ?? ""]
                    InstallLog.shared.append("vellum: 上次记下的路径能用（\(elapsed())）：\(cached)。")
                } else {
                    WorseQueryEscape.release(h)
                    InstallLog.shared.append("vellum: 上次记下的路径读不到表（可能路径变了）。")
                }
            }
        }
        guard let container else {
            throw StepError(step: "找壁纸库",
                            detail: "直读没找到壁纸库。这条路不用 VPN：看上面日志——有「总目录列到 N 个容器」就是列目录成了、但逐个探都没拿到通行证（系统封了这条路，换签名/换描述文件再试）；连「总目录列到」这句都没有，就是系统连列目录都不给，把这份日志发回来接着查；容器正常还报错就先重启手机再装一次。")
        }
        report["container"] = container

        // 2. 暂存包、拷描述符副本、对齐三个身份字段（和配对路同一个改法）。
        try checkCancelled(isCancelled)
        onProgress?("正在准备壁纸…", 0.25)
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
        let source = stage.appendingPathComponent("descriptors").appendingPathComponent(descriptorUUID)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw StepError(step: "解包", detail: "包里找不到描述符目录：descriptors/\(descriptorUUID)")
        }
        let numericId = Int.random(in: 9_999...99_999)
        InstallLog.shared.append("vellum: 新编号 \(numericId)（装包时包里所有编号统一换成它）。")
        let copyDir = fm.temporaryDirectory
            .appendingPathComponent("wallive-clone-vellum-desc-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: copyDir)
        } catch {
            throw StepError(step: "写描述符", detail: "描述符目录拷副本失败：\(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: copyDir) }
        // V1.12：userInfo 必须在 versions/1/contents 根层（系统标准位置，
        // 朋友可用包和参照树都是；一部分 -static 包塞在壁纸目录里，系统
        // 可能因此认不出描述符）。挪正；原包压根没有就照朋友的包补一份。
        relocateUserInfoToContentsRoot(in: copyDir)
        rewriteDescriptorIdentity(in: copyDir, identifier: numericId)
        // V1.9：文件名前缀也整体换成新 id（人家同款，id 和文件名一致）。
        renameDescriptorContentsToMatch(in: copyDir, newId: numericId)
        // V1.11：内层 assets.lockAndHome.default.identifier 也得跟着换——
        // 提供方按内层 id 找 .ca 动画文件（编包器那路有 alignedForFamily 干
        // 这事，无配对路之前漏了）。只改顶层的话，系统拿旧 id 找改名后的
        // 文件，找不着，图库卡片就一直转圈（V1.10 真机黑块卡加载）。
        syncDescriptorInnerIdentifier(in: copyDir, id: numericId)
        // V1.13：补渲染配置（深景总开关）。系统渲染壁纸前要读这份配置，缺了
        // 就是黑卡片——Vellum 装包时同样补（静态包也照补），朋友包原样走我们
        // 这条路仍黑，拆人家程序发现它装包时补配置 + 浮动层加 Clownfish_ 前缀。
        // 有浮动层才改前缀；调用放在改 id/改名之后，保证清单值和目录名一致。
        DepthPackageBuilder.applyingDepthConfiguration(
            toDescriptorDir: copyDir,
            log: { InstallLog.shared.append("vellum: \($0)") })
        // V1.11：建议元数据里嵌着旧 id（"<旧id>.DYNAMIC"），朋友的可用包
        // 没这个文件照样能用，直接删掉，省得图库按旧 id 找条目。
        try? fm.removeItem(at: copyDir.appendingPathComponent(
            "com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist"))

        // 3. 只写一个目录：主扩展 descriptors/<新UUID>。同名旧目录先删再写，
        //    防止上次装剩的半新半旧混在一起。
        try checkCancelled(isCancelled)
        onProgress?("正在写描述符…", 0.60)
        guard let escapeHandle else {
            throw StepError(step: "写描述符",
                            detail: "沙箱逃逸没成，描述符写不进。重试一次；还不行就先恢复配对记录再装。")
        }
        let storeBase = container + PosterBoard.storePath(storeVersion)
        let targetDir = storeBase
            + "/Extensions/\(PosterBoard.collectionsExtension)/descriptors/\(descriptorUUID)"
        try? fm.removeItem(atPath: targetDir)
        do {
            try directWriteDir(sourceDir: copyDir.path, targetDir: targetDir,
                               log: { InstallLog.shared.append("vellum: \($0)") })
        } catch {
            throw StepError(step: "写描述符", detail: "描述符直写没成：\(error.localizedDescription)")
        }
        report["descriptors"] = [["target": targetDir, "ok": true]]
        let fileCount = (try? fm.subpathsOfDirectory(atPath: copyDir.path).count) ?? 0
        InstallLog.shared.append(
            "vellum: 描述符写完（\(elapsed())）：\(targetDir)，\(fileCount) 个文件。"
            + "不写表、不写 configurations、不写偏好——人家同款，行是系统重扫时自己补的。")

        // 4. 完事：没有配对记录，隧道重启做不了（Vellum 同样跳过），直接报
        //    重启手机。描述符已落盘，重启后系统重扫自己补行。
        onProgress?("写完了", 1.0)
        report["mode"] = "backup"
        report["method"] = "vellum-descriptor-only"
        report["elapsed_seconds"] = Date().timeIntervalSince(restoreStart)
        let summary = "壁纸已写好（人家同款，只写描述符目录）：\(fileCount) 个文件进了图库目录，"
            + "表和偏好一个字没碰。重启手机后去 设置 › 墙纸 › 添加新壁纸 › 合集 长按看。完整结果见下面日志框."
        return RestoreOutcome(success: true, summary: summary,
                              descriptorUUID: descriptorUUID, posterId: nil,
                              extensionID: PosterBoard.collectionsExtension,
                              payloadCount: fileCount,
                              storeSummary: nil,
                              preferencesWritten: false,
                              refreshConfirmed: false, rebootNeeded: true,
                              injectResults: [InjectResult(targetParentDir: targetDir,
                                                           ok: true, error: nil)],
                              json: jsonString(report))
    }

    // MARK: - 拿表（Phase 0 备份优先，拷回是备选）

    /// Phase 0 拿表：先做一份带 PosterBoard 的备份、再从备份里把表抽出来，
    /// 不走 AirTraffic 拷回通道。27.2 上直写已堵、拷回也不稳，备份是主路。
    ///
    /// 步骤：拿 UDID → 备好取表目录（占位 Manifest.db + Status.plist 满备份
    /// + 空 Manifest.plist）→ Rust 只备 PosterBoard 一个容器（Backup 消息
    /// 里也带 FactoryInfo 双通道定点）→ 从备份里抽商店（合 WAL）→
    /// 拿 PosterBoard 容器路径。哪步不成、或者抽出来的商店版本不是 v61，
    /// 就抛错，调用方改走拷回通道。用户点了停止抛取消，不改走别的路。
    ///
    /// 备份不是 30 秒能完的：取备份给 180 秒超时，拿 UDID 和容器路径各 30 秒；
    /// 超时那次后台调用还在跑，结果丢弃（和拷回超时一个做法），不阻塞后面的路。
    private static func fetchTableViaBackup(pairingPath: String, workDir: URL,
                                            report: inout [String: Any],
                                            onProgress: ((String, Double) -> Void)?,
                                            isCancelled: @escaping () -> Bool) throws
        -> (savedDB: URL, savedWAL: URL?, container: String) {
        let fm = FileManager.default
        let backupRoot = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("posterboard-backup")
        // 1. 拿 UDID：取表目录按 UDID 分。
        let info = try runBackupCall(timeout: 30, isCancelled: isCancelled) {
            try await BackupFFI.deviceInfo(
                pairingPath: pairingPath, log: { InstallLog.shared.append($0) })
        }
        let udid = info.udid
        // 2. 备好取表目录：占位 Manifest.db + Status.plist（满备份）+
        //    空 Manifest.plist。旧目录先清掉，别让上次的残留混进来。
        try? fm.removeItem(at: backupRoot)
        do {
            try PosterBoardBackup.prepareFetchDirectory(
                backupRoot: backupRoot, udid: udid, log: { InstallLog.shared.append($0) })
        } catch {
            throw StepError(step: "拿表", detail: "备份取表目录备不出来：\(error.localizedDescription)")
        }
        // 3. 跑备份：只备 PosterBoard 一个容器。进度折进拿表段（5%→28%）。
        let progressGate = ProgressGate()
        let fetch = try runBackupCall(timeout: 180, isCancelled: isCancelled) {
            try await BackupFFI.fetchPosterBoard(
                pairingPath: pairingPath, backupRoot: backupRoot,
                log: { InstallLog.shared.append($0) },
                onProgress: { detail in
                    guard detail.percent >= 0,
                          progressGate.advance(to: Int(detail.percent)) else { return }
                    onProgress?("正在备份取表…", 0.05 + 0.23 * detail.percent / 100)
                })
        }
        report["backup_kept_files"] = fetch.keptFiles
        report["backup_discarded_files"] = fetch.discardedFiles
        report["backup_dir"] = fetch.backupDir.path
        InstallLog.shared.append(
            "restore: 备份跑完了（留了 \(fetch.keptFiles) 个、排了 \(fetch.discardedFiles) 个）。")
        guard fetch.keptFiles > 0 else {
            throw StepError(step: "拿表", detail: "备份跑完了，但一个文件都没留下来（手机可能没发 PosterBoard 的文件）。")
        }
        // 4. 从备份里抽商店（合 WAL）。
        let extractDir = workDir.appendingPathComponent("backup-extract")
        let store: PosterBoardBackup.Fetch
        do {
            store = try PosterBoardBackup.extractStore(
                from: fetch.backupDir, to: extractDir, log: { InstallLog.shared.append($0) })
        } catch {
            throw StepError(step: "拿表", detail: "备份里抽不出 PosterBoard 的表：\(error.localizedDescription)")
        }
        guard store.structureVersion == storeVersion else {
            throw StepError(step: "拿表",
                            detail: "备份里抽出来的商店是 v\(store.structureVersion)，这次只认 v\(storeVersion)。")
        }
        report["backup_structure_version"] = store.structureVersion
        report["backup_store_summary"] = store.summary
        // 5. 拿 PosterBoard 容器路径（写文件/写回/偏好都要它）。
        let entry = try runBackupCall(timeout: 30, isCancelled: isCancelled) {
            try await BackupFFI.appFactoryEntry(
                pairingPath: pairingPath, bundleID: "com.apple.PosterBoard",
                log: { InstallLog.shared.append($0) })
        }
        guard let container = entry["Container"] as? String, !container.isEmpty else {
            throw StepError(step: "拿表", detail: "PosterBoard 的容器路径拿不到（应用记录里没有 Container）。")
        }
        // 抽出来的表已经合了 WAL，是自包含的单文件，不用再配 -wal。
        return (store.database, nil, container)
    }

    /// 在同步代码里等一个 async 的备份 FFI 调用：超时就取消那路、抛错，
    /// 调用方改走别的路；用户点了停止也一样取消、抛取消。等的时候每秒
    /// 查一次取消，满 60 秒记一行日志，别让用户干等没动静。
    private static func runBackupCall<T>(timeout: TimeInterval,
                                         isCancelled: @escaping () -> Bool,
                                         _ work: @escaping () async throws -> T) throws -> T {
        let box = BackupCallBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task {
            do {
                box.set(.success(try await work()))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        var waited: TimeInterval = 0
        while semaphore.wait(timeout: .now() + 1) == .timedOut {
            waited += 1
            if isCancelled() {
                task.cancel()
                throw CancellationError()
            }
            if waited >= timeout {
                task.cancel()
                throw StepError(step: "拿表", detail: "备份取表超时（\(Int(timeout)) 秒没等到手机备完）。")
            }
            if Int(waited) % 60 == 0 {
                InstallLog.shared.append("restore: 备份取表进行中（已等 \(Int(waited)) 秒）……")
            }
        }
        guard let result = box.result else {
            throw StepError(step: "拿表", detail: "备份取表没回结果。")
        }
        return try result.get()
    }

    /// 跨线程传一次 async 备份调用的结果（和 ExportResultBox 一个做法）。
    private final class BackupCallBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _result: Result<T, Error>?
        var result: Result<T, Error>? {
            lock.lock(); defer { lock.unlock() }
            return _result
        }
        func set(_ result: Result<T, Error>) {
            lock.lock(); defer { lock.unlock() }
            _result = result
        }
    }

    /// 备份进度节流：Rust 回调来得密，只在整百分比变了时才往 UI 报。
    private final class ProgressGate: @unchecked Sendable {
        private let lock = NSLock()
        private var last = -1
        /// 整数百分比变了才返回 true（调用方再报进度）。
        func advance(to percent: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard percent != last else { return false }
            last = percent
            return true
        }
    }

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

    /// FileService 只在 iOS 27.2 及以上走：拷回在 27.2 上死了，27.0.1
    /// 的拷回是通的，老路不动。27.2 beta 3 起直写就堵了，所以 27.2
    /// 及以上都算同一档。
    /// 是不是 iOS 27.2 及以上：27.2 上杀 PosterBoard 回不来（V6 日志已证实
    /// 表对了也不回来），刷新那步不再杀，改报需重启手机。
    /// App 就跑在这台手机上，ProcessInfo 读的就是本机系统版本。
    private static var isIOS27_2OrLater: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion == 27 && v.minorVersion >= 2
    }

    private static var isFileServiceEligible: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion == 27 && v.minorVersion >= 2
    }

    // MARK: - 直读取表（27.2 快路：容器路径缓存 + 逃逸直读）

    /// 容器路径缓存键。
    private static let cachedContainerKey = "restore.posterboard.containerPath"

    /// 上次成功安装记下的 PosterBoard 容器路径。共享抽屉里存一份、
    /// 本机也存一份，读的时候共享抽屉优先（重装 App 后本机的就没了，
    /// 共享抽屉还在）。路径形状不对就当没有。
    /// V1.22：换签名后候选组顺序会变，所以几套组都翻一遍，别只认第一个。
    private static func cachedContainerPath() -> String? {
        var stored: [String] = []
        for group in WorseQueryEscape.candidateGroups {
            if let p = UserDefaults(suiteName: group)?.string(forKey: cachedContainerKey) {
                stored.append(p)
            }
        }
        if let p = UserDefaults.standard.string(forKey: cachedContainerKey) {
            stored.append(p)
        }
        for p in stored {
            if p.contains("Containers/Data/Application/") { return p }
        }
        return nil
    }

    /// 记下这次用的容器路径，下次拿表走直读。几套组都存一份，
    /// 换签名后无论哪个组排第一都查得到。
    private static func saveContainerPath(_ path: String) {
        for group in WorseQueryEscape.candidateGroups {
            UserDefaults(suiteName: group)?.set(path, forKey: cachedContainerKey)
        }
        UserDefaults.standard.set(path, forKey: cachedContainerKey)
    }

    /// 第 0 步：问系统要 PosterBoard 的容器路径（Vellum 的第一条路）。
    /// 走 LaunchServices 私有接口直接拿精确路径，拿到就不用几百个挨个扫。
    /// 拿不到（私有框架没载入、类或方法不在）返回 nil，走后面的扫描。
    private static func posterBoardContainerViaLaunchServices() -> String? {
        // 框架没载入时先载入；两个候选名字都试。
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY)
        dlopen("/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices", RTLD_LAZY)
        let paths = [
            lsProxyContainerURL(className: "LSApplicationProxy",
                                factory: "applicationProxyForIdentifier:"),
            lsProxyContainerURL(className: "LSApplicationWorkspace",
                                factory: "objectForApplicationWithIdentifier:"),
        ]
        for p in paths.compactMap({ $0 }) {
            if p.contains("Containers/Data/Application/") { return p }
        }
        return nil
    }

    /// 对一个 LaunchServices 私有类拿 proxy，再取 containerURL。
    /// LSApplicationProxy 的工厂方法是类方法，直接在类上调；
    /// LSApplicationWorkspace 的同名方法是实例方法，先取 defaultWorkspace 单例。
    private static func lsProxyContainerURL(className: String, factory: String) -> String? {
        let urlSel = NSSelectorFromString("containerURL")
        guard let cls = NSClassFromString(className) as? NSObject.Type else { return nil }
        let factorySel = NSSelectorFromString(factory)
        let proxy: NSObject?
        if cls.responds(to: factorySel) {
            // 类方法路：applicationProxyForIdentifier:
            proxy = cls.perform(factorySel, with: "com.apple.PosterBoard")?
                .takeUnretainedValue() as? NSObject
        } else if className == "LSApplicationWorkspace" {
            // 实例方法路：先拿 defaultWorkspace 单例，再 objectForApplicationWithIdentifier:
            let wsSel = NSSelectorFromString("defaultWorkspace")
            guard cls.responds(to: wsSel),
                  let ws = cls.perform(wsSel)?.takeUnretainedValue() as? NSObject,
                  ws.responds(to: factorySel) else { return nil }
            proxy = ws.perform(factorySel, with: "com.apple.PosterBoard")?
                .takeUnretainedValue() as? NSObject
        } else {
            proxy = nil
        }
        guard let proxy, proxy.responds(to: urlSel),
              let urlUnmanaged = proxy.perform(urlSel) else { return nil }
        guard let url = urlUnmanaged.takeUnretainedValue() as? URL else { return nil }
        return url.path
    }

    /// 总目录直翻（V1.22 改成 Vellum 同款 inode-scan）：不再向「应用数据
    /// 总目录」要通行证——真机实测对父级路径的查询每台手机都被拒，第一
    /// 次装就找不到库。改为把总目录下的容器一个个列出来，逐个单独吃扩
    /// 展、探头找 61 号店（对具体容器的查询系统放行，Vellum 诊断 400 个
    /// 5.4s 全部拿到句柄）。头一回装也走直读，不依赖任何缓存。列出失败
    /// 才退回旧路（总目录扩展）和缓存路径。成了把句柄一并交回，写文件/
    /// 写回表复用同一个扩展。
    private static func discoverAndReadDirect(workDir: URL)
        -> (db: URL, wal: URL?, container: String, handle: Int64)? {
        let fm = FileManager.default

        // 第 0 步：LaunchServices 直接指路（Vellum 的第一条路，拿到就不用扫）。
        if let lsPath = posterBoardContainerViaLaunchServices() {
            InstallLog.shared.append("vellum: LaunchServices 指到壁纸库容器：\(lsPath)。")
            let esc = WorseQueryEscape.consume(target: lsPath, requireWrite: false) {
                InstallLog.shared.append("restore: \($0)")
            }
            if let h = esc.handle,
               let read = readStoreDirect(container: lsPath, workDir: workDir) {
                return (db: read.db, wal: read.wal, container: lsPath, handle: h)
            }
            // 指到了但拿不到通行证或读不了表：继续走扫描。
            WorseQueryEscape.release(esc.handle)
        }

        // /var 和 /private/var 是同一个地方两种写法，列到哪个用哪个。
        let roots = ["/var/mobile/Containers/Data/Application",
                     "/private/var/mobile/Containers/Data/Application"]
        for root in roots {
            // 第一步：把候选容器名列出来（只列名字，不读内容）。
            let entries = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            guard !entries.isEmpty else { continue }
            InstallLog.shared.append("vellum: 总目录列到 \(entries.count) 个容器，逐个探头找库。")
            // 第二步：逐个容器单独吃扩展，探到库就读表。整段限 25 秒，
            // 超时就放弃本机枚举（Vellum 同款规矩）。
            let scanDeadline = Date().addingTimeInterval(25)
            var scanned = 0
            var consecutiveFails = 0
            for entry in entries {
                if Date() > scanDeadline {
                    InstallLog.shared.append("vellum: 扫描超过 25 秒，剩下的容器不再试。")
                    scanned = entries.count
                    break
                }
                let candidate = (root as NSString).appendingPathComponent(entry)
                let esc = WorseQueryEscape.consume(target: candidate, requireWrite: false, quiet: true)
                scanned += 1
                guard let h = esc.handle else {
                    // 连续 20 个容器都拿不到通行证：这条路在这台系统上八成被封了，
                    // 别再白试几百个（每回 400 个×全组被拒要好几分钟）。
                    consecutiveFails += 1
                    if consecutiveFails >= 20 {
                        InstallLog.shared.append("vellum: 连续 \(consecutiveFails) 个容器都拿不到通行证，剩下的不再试。")
                        scanned = entries.count
                        break
                    }
                    continue
                }
                consecutiveFails = 0
                let dbPath = candidate + PosterBoard.storePath(storeVersion)
                    + "/" + PosterBoard.databaseFileName
                if fm.fileExists(atPath: dbPath),
                   let read = readStoreDirect(container: candidate, workDir: workDir) {
                    InstallLog.shared.append("vellum: 探了 \(scanned) 个，壁纸库在：\(candidate)。")
                    return (db: read.db, wal: read.wal, container: candidate, handle: h)
                }
                // 不是这个容器（或表读不了）：把扩展还回去，看下一个。
                WorseQueryEscape.release(h)
            }
            InstallLog.shared.append("vellum: 这 \(scanned) 个容器里都没翻到壁纸库。")
        }
        // 旧路兜底：对总目录吃扩展（多半被拒，留给系统放行的情形）。
        for root in roots {
            let esc = WorseQueryEscape.consume(target: root, requireWrite: false) {
                InstallLog.shared.append("restore: \($0)")
            }
            guard let h = esc.handle else { continue }
            let entries = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            for entry in entries {
                let candidate = (root as NSString).appendingPathComponent(entry)
                let dbPath = candidate + PosterBoard.storePath(storeVersion)
                    + "/" + PosterBoard.databaseFileName
                guard fm.fileExists(atPath: dbPath) else { continue }
                if let read = readStoreDirect(container: candidate, workDir: workDir) {
                    return (db: read.db, wal: read.wal, container: candidate, handle: h)
                }
            }
            // 扩展给了但没翻到表：还回去，换个写法再试一次。
            WorseQueryEscape.release(h)
        }
        return nil
    }

    /// 直读取表：容器路径已知、逃逸在手时，把真实表（含 -wal）直接从手机
    /// 文件里拷出来，不走备份、不走隧道。拷完先验（integrity_check 过了
    /// 才算），验不过当没读到，调用方自动回落老链，绝不拿坏表往下装。
    private static func readStoreDirect(container: String, workDir: URL) -> (db: URL, wal: URL?)? {
        let fm = FileManager.default
        let storeDir = container + PosterBoard.storePath(storeVersion)
        let dbPath = storeDir + "/" + PosterBoard.databaseFileName
        guard fm.fileExists(atPath: dbPath) else { return nil }
        let outDir = workDir.appendingPathComponent("direct-read")
        do {
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch { return nil }
        let dbOut = outDir.appendingPathComponent(PosterBoard.databaseFileName)
        var walOut: URL? = nil
        let walPath = dbPath + "-wal"
        if fm.fileExists(atPath: walPath) {
            let w = outDir.appendingPathComponent(PosterBoard.databaseFileName + "-wal")
            if (try? fm.copyItem(atPath: walPath, toPath: w.path)) != nil { walOut = w }
        }
        do {
            try fm.copyItem(atPath: dbPath, toPath: dbOut.path)
        } catch { return nil }
        // 验库：能打开、integrity_check 是 ok 才算读到真表。
        var db: OpaquePointer?
        guard sqlite3_open(dbOut.path, &db) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        var stmt: OpaquePointer?
        var integrity = ""
        if sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK,
           let stmt {
            if sqlite3_step(stmt) == SQLITE_ROW, let t = sqlite3_column_text(stmt, 0) {
                integrity = String(cString: t)
            }
            sqlite3_finalize(stmt)
        }
        guard integrity == "ok" else { return nil }
        return (dbOut, walOut)
    }

    /// 调 al_fileservice_posterboard_export 走 FileService 读 v61 的表 + -wal，返回存盘路径和容器路径。
    /// 只在 iOS 27.2 及以上调（isFileServiceEligible 把过门）。
    private static func exportViaFileService(pairingPath: String, stamp: String,
                                             report: inout [String: Any]) throws
        -> (savedDB: URL, savedWAL: URL?, container: String) {
        let destDir = tableDir.path
        let (rc, json, error) = callFileServiceFFI(
            pairingPath: pairingPath, destDir: destDir, stamp: stamp)
        guard rc == 0, let json,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StepError(step: "拿表", detail: "FileService 通道没通：\(error ?? "未知错误")")
        }
        report["fileservice_export"] = obj
        guard (obj["success"] as? Bool) == true,
              (obj["saved_db_ok"] as? Bool) == true,
              let dbPath = obj["saved_db_path"] as? String,
              let container = obj["container"] as? String else {
            throw StepError(step: "拿表", detail: "表没从 FileService 读回来（v61 没成，或存盘校验没过）。")
        }
        let walPath = obj["saved_wal_path"] as? String
        return (URL(fileURLWithPath: dbPath),
                walPath.map { URL(fileURLWithPath: $0) },
                container)
    }

    /// FileService 拿表也加 30 秒超时（跟拷回那路一样），超时就停，不死等。
    private static func exportViaFileServiceTimed(pairingPath: String, stamp: String,
                                                  report: inout [String: Any],
                                                  timeout: TimeInterval = 30) throws
        -> (savedDB: URL, savedWAL: URL?, container: String) {
        let box = ExportResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var workerReport: [String: Any] = ["channel": "restore_test"]
            do {
                let fresh = try exportViaFileService(pairingPath: pairingPath, stamp: stamp, report: &workerReport)
                box.set(.success((fresh.savedDB, fresh.savedWAL, fresh.container)), report: workerReport)
            } catch {
                box.set(.failure(error), report: workerReport)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw StepError(step: "拿表", detail: "FileService 取表超时（\(Int(timeout)) 秒没等到手机回表）。")
        }
        // 没超时：把 worker 那边记进 report 的键合回来（失败时也要合，
        // 兜底要从 report["fileservice_export"] 里拿容器路径）。
        for (key, value) in box.report { report[key] = value }
        guard let result = box.result else {
            throw StepError(step: "拿表", detail: "取表没回结果。")
        }
        switch result {
        case .success(let fresh): return fresh
        case .failure(let error): throw error
        }
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
                            detail: "拷回没成（\(exportError.detail)），手机里也没存下来的表：重启手机一次，再来装（拿表只有重启后第一次才稳）。")
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

    /// 手机里有没有存过的表（merged.sqlite3，或任何一份 PBF...-*.sqlite3）。
    /// 只读，不动文件。给第 4 级（造空名单）做门禁：存过的表还在时绝不
    /// 造空名单——哪怕只是容器路径拿不到，也不能把好端端的名单替掉。
    private static func hasStoredTable() -> Bool {
        let fm = FileManager.default
        let dir = tableDir
        if fm.fileExists(atPath: dir.appendingPathComponent("merged.sqlite3").path) {
            return true
        }
        let saved = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return saved.contains {
            $0.lastPathComponent.hasPrefix("PBFPosterExtensionDataStoreSQLiteDatabase-")
            && $0.pathExtension == "sqlite3"
        }
    }

    /// 第 4 级：前面三条都没成时，现场造一张空名单接着装。
    /// 只在“备份、拷回、存过的表”三级全失败、且确认手机里一张存过的表
    /// 都没有时才走（调用方已用 hasStoredTable 把过门）。
    ///
    /// 步骤（每步开始前和每步之间都查取消，点了就直接停，不改走别的路）：
    ///   1. 核包：TendiesPackage.inspect——能解开、有描述符才继续。
    ///   2. 拿容器路径：BackupFFI.appFactoryEntry（30 秒超时），校验非空
    ///      且是应用容器路径开头（/var/mobile/Containers/Data/Application/
    ///      或 /private/var/mobile/Containers/Data/Application/——iOS 上
    ///      /var 就是指向 /private/var 的，同一个地方两种写法，都认）。
    ///   3. 造空库：PosterBoardStore.createEmptyDatabase（6 张必备表，store v61）。
    ///   4. 验库：6 张必备表都在、数据表一行都没有、integrity_check 是 ok。
    /// 哪步不过就抛 StepError（写明哪步），直接停，不硬装。
    /// 返回的表是自包含的单文件（已合 WAL），不用再配 -wal；后面流程
    /// （合库→编包→插行）照常走，插行时空表上第一行就是 posterId 1。
    private static func createEmptyTable(packageData: Data, pairingPath: String, workDir: URL,
                                         report: inout [String: Any],
                                         onProgress: ((String, Double) -> Void)?,
                                         isCancelled: @escaping () -> Bool) throws
        -> (savedDB: URL, savedWAL: URL?, container: String) {
        try checkCancelled(isCancelled)
        // 拿表段的进度是 0.05→0.28（备份那段），拷回和存过的表不报进度，
        // 所以到这里进度最多是 0.28；造空名单从 0.28 往后报，别往回跳。
        onProgress?("前面都没成，正在造一张空名单…", 0.28)
        InstallLog.shared.append("restore: 前面三条都没成（备份、拷回、存过的表），改造空名单接着装。")

        // 1. 核包：能解开、有描述符才继续。包不对直接停，别造了表才发现包是坏的。
        //    完整校验（暂存、编包）后面第 3 步还会再做一遍，那步在写回之前，
        //    包坏了一定拦得住，不会写进手机。
        do {
            _ = try TendiesPackage.inspect(packageData, zip: ZipFoundationAdapter())
        } catch let error as TendiesPackage.Error {
            switch error {
            case .notATendiesPackage:
                throw StepError(step: "造空名单", detail: "包不对：这不是一个 .tendies / .wallive 包，造空名单停下了。")
            case .missingWallpaperDirectory:
                throw StepError(step: "造空名单", detail: "包不对：包里找不到壁纸目录，结构不对，造空名单停下了。")
            case .missingWallpaperPlist:
                throw StepError(step: "造空名单", detail: "包不对：包里找不到 Wallpaper.plist，结构不对，造空名单停下了。")
            }
        } catch {
            throw StepError(step: "造空名单", detail: "包校验没过：\(error.localizedDescription)，造空名单停下了。")
        }
        try checkCancelled(isCancelled)

        // 2. 拿容器路径：单独问手机要一次（不经过拿表那条路），30 秒超时。
        //    拿不到、或者拿到的不是应用容器路径，就直接停，不硬猜、不写死。
        //    runBackupCall 是备份取表共用的等法，超时报错里写的是“备份取表”，
        //    这里是问容器路径，报错要改写成这步的名字，别让人看错。
        onProgress?("正在问手机要壁纸位置…", 0.29)
        let entry: [String: Any]
        do {
            entry = try runBackupCall(timeout: 30, isCancelled: isCancelled) {
                try await BackupFFI.appFactoryEntry(
                    pairingPath: pairingPath, bundleID: "com.apple.PosterBoard",
                    log: { InstallLog.shared.append($0) })
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StepError(step: "造空名单",
                            detail: "容器路径拿不到（问手机要应用记录没成：\((error as? StepError)?.detail ?? error.localizedDescription)），造空名单停下了。")
        }
        guard let container = entry["Container"] as? String, !container.isEmpty else {
            throw StepError(step: "造空名单", detail: "PosterBoard 的容器路径拿不到（应用记录里没有 Container），造空名单停下了。")
        }
        guard container.hasPrefix("/var/mobile/Containers/Data/Application/")
            || container.hasPrefix("/private/var/mobile/Containers/Data/Application/") else {
            throw StepError(step: "造空名单", detail: "PosterBoard 的容器路径不对（不是应用容器路径：\(container)），造空名单停下了。")
        }
        try checkCancelled(isCancelled)

        // 3. 造空库：按真表的结构造（6 张必备表，store v61），一行都没有。
        //    造表本身是本地操作、很快，不用超时；SQL 报错直接抛。
        onProgress?("正在造空名单…", 0.29)
        let emptyDir = workDir.appendingPathComponent("empty-store")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let emptyDB = emptyDir.appendingPathComponent(PosterBoard.databaseFileName)
        do {
            try PosterBoardStore.createEmptyDatabase(at: emptyDB)
        } catch {
            throw StepError(step: "造空名单", detail: "空名单造不出来：\(error.localizedDescription)")
        }
        try checkCancelled(isCancelled)

        // 4. 验库：6 张必备表都在、数据表一行都没有、integrity_check 是 ok。
        //    （posterMetadata / posterRoles 是 db5+ 才加的表，空表里也建了，
        //    校验认全部 6 张必备表。）
        try verifyEmptyStore(emptyDB)
        try checkCancelled(isCancelled)

        report["empty_store_path"] = emptyDB.path
        InstallLog.shared.append("restore: 空名单造好了（\(PosterBoardStore.summary(emptyDB))），接着往下装。")
        // 造出来的表已合 WAL，是自包含的单文件，不用再配 -wal。
        return (emptyDB, nil, container)
    }

    /// 验一张刚造的空名单：6 张必备表都在、数据表一行都没有、
    /// integrity_check 是 ok。哪项不过就抛错，写明是哪项。
    private static func verifyEmptyStore(_ url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw StepError(step: "造空名单", detail: "刚造的空名单打不开，没法验。")
        }
        defer { sqlite3_close(db) }

        func tableExists(_ name: String) throws -> Bool {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;", -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
                throw StepError(step: "造空名单", detail: "验空名单时查表失败：\(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            return sqlite3_step(stmt) == SQLITE_ROW
        }

        func rowCount(_ table: String) throws -> Int64 {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table);", -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
                throw StepError(step: "造空名单", detail: "验空名单时数 \(table) 的行失败：\(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw StepError(step: "造空名单", detail: "验空名单时 \(table) 的行数读不出来。")
            }
            return sqlite3_column_int64(stmt, 0)
        }

        for table in PosterBoardStore.requiredTables {
            guard try tableExists(table) else {
                throw StepError(step: "造空名单", detail: "刚造的空名单缺表：\(table)。")
            }
        }
        for table in ["poster", "posterAttributes", "posterRoleMembership"] {
            let count = try rowCount(table)
            guard count == 0 else {
                throw StepError(step: "造空名单", detail: "刚造的空名单不空：\(table) 里有 \(count) 行。")
            }
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw StepError(step: "造空名单", detail: "验空名单时 integrity_check 跑不起来。")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0),
              String(cString: text) == "ok" else {
            throw StepError(step: "造空名单", detail: "刚造的空名单 integrity_check 没过。")
        }
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

    private static func callFileServiceFFI(pairingPath: String, destDir: String, stamp: String)
        -> (rc: Int32, json: String?, error: String?) {
        "10.7.0.1".withCString { _ = al_set_target_host($0) }
        var outJson: UnsafeMutablePointer<CChar>? = nil
        var outError: UnsafeMutablePointer<CChar>? = nil
        let rc = pairingPath.withCString { pairC in
            destDir.withCString { destC in
                stamp.withCString { stampC in
                    al_fileservice_posterboard_export(pairC, destC, stampC,
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

    // MARK: - 写文件（备份路：逃逸直写；测试版：AirTraffic 老通道）

    /// 载荷按父目录分组，每组平铺进一个临时目录。备份路（requireEscape:
    /// true）只走逃逸直写——逃逸没成或直写失败都直接停，不再回落
    /// AirTraffic；测试版（requireEscape: false，escapeHandle 传 nil）
    /// 照走 al_exploit_write_dir 老通道。返回写了几个文件。
    private static func writePayloadFiles(payloads: [BackupPayload], container: String,
                                          pairingPath: String,
                                          escapeHandle: Int64?,
                                          escapeFailReason: String? = nil,
                                          requireEscape: Bool = false) throws -> Int {
        if requireEscape && escapeHandle == nil {
            throw StepError(step: "写文件",
                            detail: "沙箱逃逸没成（\(escapeFailReason ?? "原因见日志")），27.2 只走逃逸直写，不再走老通道。")
        }
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
                // 有逃逸句柄就走本地直写：把暂存组目录直接拷进容器对应目录。
                // 备份路（requireEscape）直写失败直接停，不回落 AirTraffic；
                // 测试版没有逃逸句柄，照走 AirTraffic 老通道。
                var directOK = false
                if escapeHandle != nil {
                    do {
                        try directWriteDir(sourceDir: groupDir.path,
                                           targetDir: container + "/" + parent,
                                           log: { InstallLog.shared.append("restore: \($0)") })
                        directOK = true
                        written += files.count
                    } catch {
                        if requireEscape {
                            throw StepError(step: "写文件",
                                            detail: "逃逸直写 \(parent) 没成：\(error.localizedDescription)。27.2 不再走老通道。")
                        }
                        InstallLog.shared.append("restore: 直写 \(parent) 没成（\(error.localizedDescription)），回落 AirTraffic。")
                    }
                }
                if !directOK {
                    try writeDirFFI(pairingPath: pairingPath, sourceDir: groupDir.path,
                                    targetDir: container + "/" + parent)
                    written += files.count
                }
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

    /// 逃逸直写：把暂存目录整个拷到容器内目标目录（目录已存在则逐文件覆盖）。
    /// 只在拿着沙箱扩展句柄时用，普通 FileManager 就够了。
    private static func directWriteDir(sourceDir: String, targetDir: String,
                                       log: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: sourceDir)
        let dst = URL(fileURLWithPath: targetDir)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
        for item in items {
            let dest = dst.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: item, to: dest)
        }
        log("直写 \(dst.path)（\(items.count) 个文件）。")
    }

    /// 逃逸直写写回表：stagedDir 里的表（+ 0 字节 -wal/-shm）直接拷进
    /// 商店目录。任何失败抛错（调用方 27.2 不再回落 FFI）。
    private static func directWriteback(stagedDir: String, targetDir: String,
                                        log: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        do {
            let staged = URL(fileURLWithPath: stagedDir)
            let dst = URL(fileURLWithPath: targetDir)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(at: staged, includingPropertiesForKeys: nil)
            for item in items {
                let dest = dst.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: item, to: dest)
            }
            log("写回表走 worse_query 直写（\(items.count) 个文件进 \(dst.path)）。")
        } catch {
            log("写回表直写没成（\(error.localizedDescription)）。")
            throw error
        }
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
                                          container: String, pairingPath: String,
                                          escapeHandle: Int64? = nil) throws -> [[String: Any]] {
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
        let allTargets = AirliftInstaller.dualExtensions(for: config.extensionID).map {
            "\(storeBase)/Extensions/\($0)/descriptors"
        }
        // 没配对：学 Vellum 只写主扩展一个描述符目录（真机对比 Vellum 不卡、
        // 我们卡，两处结构差异之一就是多写了 CollectionsPosterApp 那份）。
        // 配对路保持双扩展不变（配对装没出过卡死）。
        let targets = pairingPath.isEmpty ? [allTargets[0]] : allTargets
        var results: [[String: Any]] = []
        for (index, targetParent) in targets.enumerated() {
            do {
                if pairingPath.isEmpty {
                    // 没配对：描述符照写文件同一条路逃逸直写（目标在容器内，
                    // 同一个扩展句柄盖得住）。句柄不在手就直接报，不硬试。
                    guard let escapeHandle else {
                        throw StepError(step: "写描述符",
                                        detail: "没有配对记录，描述符只能走逃逸直写，但沙箱逃逸没成。重试一次；还不行就先恢复配对记录再装。")
                    }
                    try directWriteDir(sourceDir: copyDir.path,
                                       targetDir: targetParent + "/" + config.uuid,
                                       log: { InstallLog.shared.append("restore: \($0)") })
                    InstallLog.shared.append("restore: 没配对：描述符改走逃逸直写 \(targetParent)/\(config.uuid)")
                } else {
                    try injectFolderFFI(folderURL: copyDir, targetParentDir: targetParent,
                                        destName: config.uuid, pairingPath: pairingPath)
                }
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
                // V1.14：不再挑"原值是数字才改"。朋友的可用包这份文件是数字
                // 3141，跟清单、文件名前缀同一个数；我们的流程把其余全部换成
                // 新数字 id，这份要是不改（原值是打包器新造的 UUID 就转不成
                // 数字，被挑判断挡下），装出去里外两个编号，系统对不上号，
                // 图库卡片就是黑的。一律写成新数字 id，配对路调用点同样要数字。
                let oldContent = (try? String(contentsOf: fileURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? String(identifier).data(using: .utf8)?.write(to: fileURL)
                if oldContent != String(identifier) {
                    InstallLog.shared.append(
                        "vellum: 身份文件原值「\(oldContent)」→ 改成「\(identifier)」"
                        + "（清单、文件名前缀都用这个数）。")
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

    /// 把描述符里所有带旧 id 前缀的名字整体换成新 id（Vellum 同款：装出来的
    /// 描述符里，id 和文件名从头到尾一致）。V1.8 只改三个身份字段、文件名
    /// 留着旧 id，系统重扫时对不上号、图库不认——这是重启后不出现的最大
    /// 嫌疑（人家参照树和朋友的可用包里，id 和文件名前缀都是同一个数）。
    /// 改三处：
    /// 1. 目录/文件名开头 `<旧id>.` → `<新id>.`（contents 壁纸目录、.ca 图层目录）；
    /// 2. Wallpaper.plist 的 backgroundAnimationFileName / foregroundAnimationFileName；
    /// 3. userInfo 的 wallpaperRepresentingFileName。
    /// （id 本身由 rewriteDescriptorIdentity 改好，这里不碰。）
    private static func renameDescriptorContentsToMatch(in folderURL: URL, newId: Int) {
        let fm = FileManager.default
        // 1. 名字带旧 id 前缀的目录/文件：从深到浅换前缀（先深后浅，防止
        //    先改父目录让后面收集的路径失效）。
        var entries: [URL] = []
        if let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL { entries.append(url) }
        }
        for url in entries.sorted(by: { $0.path.count > $1.path.count }) {
            let name = url.lastPathComponent
            guard let dotRange = name.range(of: "^\\d+\\.", options: .regularExpression) else { continue }
            let newName = "\(newId)." + name[dotRange.upperBound...]
            let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
            try? fm.moveItem(at: url, to: newURL)
            // V1.14：逐处改动记进日志（FILE: 行只进文件、不占屏幕）。
            InstallLog.shared.append("FILE:改名：\(name) → \(newName)")
        }
        // 2 + 3. 两个 plist 里的文件名引用跟着换前缀。
        // V1.15 修复（V1.9 起的真凶）：原实现在清单最外层找这几个键，但
        // Wallpaper.plist 里 backgroundAnimationFileName / foregroundAnimationFileName /
        // floatingAnimationFileNameKey 都藏在 assets.lockAndHome.default 下面——
        // 顶层找不到，一个值都没改过，装出去清单指着旧前缀的文件，提供方
        // 找不着层，图库卡片就是黑的；浮动层改名也因此悄悄跳过（清单里的
        // 旧名字在目录里已不存在）。
        let fix: (String) -> String = { value in
            guard let dotRange = value.range(of: "^\\d+\\.", options: .regularExpression) else { return value }
            return "\(newId)." + value[dotRange.upperBound...]
        }
        if let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                let name = url.lastPathComponent
                guard name == "Wallpaper.plist"
                        || name == "com.apple.posterkit.provider.contents.userInfo" else { continue }
                guard var plist = try? PosterBoardPlist.load(contentsOf: url) else {
                    InstallLog.shared.append("FILE:清单读不出，没改前缀：\(url.lastPathComponent)")
                    continue
                }
                var changedCount = 0
                func fixDeep(_ value: Any) -> Any {
                    if let s = value as? String {
                        let fixed = fix(s)
                        if fixed != s { changedCount += 1 }
                        return fixed
                    }
                    if let d = value as? [String: Any] {
                        var out = d
                        for (k, v) in d { out[k] = fixDeep(v) }
                        return out
                    }
                    if let a = value as? [Any] {
                        return a.map { fixDeep($0) }
                    }
                    return value
                }
                guard let fixedPlist = fixDeep(plist) as? [String: Any] else { continue }
                plist = fixedPlist
                guard changedCount > 0 else { continue }
                if let data = try? PropertyListSerialization.data(
                    fromPropertyList: plist, format: .xml, options: 0) {
                    try? data.write(to: url)
                    InstallLog.shared.append(
                        "vellum: \(name) 里改了 \(changedCount) 处文件名前缀（→\(newId)）。")
                } else {
                    InstallLog.shared.append("FILE:清单写回没成：\(name)")
                }
            }
        }
    }

    /// 把 userInfo 挪到 versions/1/contents 根层（V1.12）。系统标准位置是
    /// contents 根层（朋友可用包、Vellum 参照树都在根层）；一部分 -static 包
    /// 把它塞在壁纸目录里，系统可能因此认不出描述符。塞错位置的挪到根层；
    /// 哪儿都没有就照朋友的包补一份（posterEnvironmentOverrides 空 JSON、
    /// 壁纸目录名；代表编号随后由 rewriteDescriptorIdentity 补齐）。
    /// 只在无配对路调用；配对路不碰。
    private static func relocateUserInfoToContentsRoot(in folderURL: URL) {
        let fm = FileManager.default
        let infoName = "com.apple.posterkit.provider.contents.userInfo"
        guard let paths = try? fm.subpathsOfDirectory(atPath: folderURL.path) else { return }
        guard let contentsSub = paths.first(where: {
            $0 == "versions/1/contents" || $0.hasSuffix("/versions/1/contents")
        }) else { return }
        let contentsDir = folderURL.appendingPathComponent(contentsSub)
        let rootInfo = contentsDir.appendingPathComponent(infoName)
        guard !fm.fileExists(atPath: rootInfo.path) else { return } // 已在根层，正好。
        // 塞在壁纸目录里的同名的文件：挪到根层（防重名先删）。
        if let misplaced = paths.first(where: { $0.hasSuffix("/" + infoName) }) {
            try? fm.removeItem(atPath: rootInfo.path)
            try? fm.moveItem(at: folderURL.appendingPathComponent(misplaced),
                             to: rootInfo)
            InstallLog.shared.append("vellum: userInfo 原本塞在壁纸目录里，已挪到 contents 根层。")
            return
        }
        // 哪儿都没有：照朋友的可用包补一份。代表文件名取壁纸目录名
        // （旧 id 前缀随后由 renameDescriptorContentsToMatch 一起换）。
        let wallpaperDirName = paths
            .compactMap { sub -> String? in
                guard sub.hasPrefix(contentsSub + "/") else { return nil }
                let relative = sub.dropFirst(contentsSub.count + 1)
                guard !relative.isEmpty else { return nil }
                let first = relative.split(separator: "/").first.map(String.init) ?? ""
                return first.hasSuffix(".wallpaper") ? first : nil
            }
            .first
        var info: [String: Any] = [
            "posterEnvironmentOverrides": Data(base64Encoded: "e30=") ?? Data()
        ]
        if let wallpaperDirName {
            info["wallpaperRepresentingFileName"] = wallpaperDirName
        }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0) else {
            InstallLog.shared.append("vellum: userInfo 补写失败，继续装（多数不碍事）。")
            return
        }
        try? data.write(to: rootInfo)
        InstallLog.shared.append("vellum: userInfo 原包没有，已照朋友包补一份到 contents 根层。")
    }

    /// 把 Wallpaper.plist 内层的 assets.lockAndHome.default.identifier 也换成
    /// 新 id（V1.11）。提供方按这个内层 id 找 .ca 动画文件（编包器那路的
    /// alignedForFamily 注释原话），只改顶层的话内外对不上，图库卡片渲染
    /// 不出来、一直转圈。朋友的可用包里外是同一个数，系统参照树也一样。
    /// 只在无配对路调用；配对路由编包器 alignedForFamily 对齐，不在这改。
    private static func syncDescriptorInnerIdentifier(in folderURL: URL, id: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folderURL,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return }
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "Wallpaper.plist" {
            guard var plist = try? PosterBoardPlist.load(contentsOf: fileURL),
                  var assets = plist["assets"] as? [String: Any],
                  var lockAndHome = assets["lockAndHome"] as? [String: Any],
                  var def = lockAndHome["default"] as? [String: Any] else { continue }
            def["identifier"] = id
            lockAndHome["default"] = def
            assets["lockAndHome"] = lockAndHome
            plist["assets"] = assets
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: fileURL)
            }
        }
    }

    // MARK: - 写偏好 + 刷新（照直装同一份内容）

    /// 写一次 PosterBoard 偏好（照直装 writePosterBoardPreferences 同一份内容：
    /// PBF_RESET_FILE_PROTECTIONS / PBF_LOCALE_DID_CHANGE + 两份 bundle 清单），
    /// 让系统重载描述符、重新索引。容器内那份失败就停；系统全局那份尽力写，
    /// 失败不算错（和直装一样）。
    /// 同步版：直装那个是 async（跑在 runBlocking 里），这里调用方已在后台线程，
    /// 直接调 writeDirFFI。
    private static func writePosterBoardPreferences(container: String, pairingPath: String,
                                                    escapeHandle: Int64? = nil) throws {
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
        if pairingPath.isEmpty {
            // 没配对：学 Vellum 一个字偏好都不写（Vellum 日志里没有写偏好的动作，
            // 真机对比它不卡、我们卡，这是第二处结构差异）。系统自己会重扫，
            // 不需要这颗重载开关。
            InstallLog.shared.append(
                "restore: 没配对：照 Vellum 不写偏好，等系统自己重扫。")
            return
        }
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
                // 27.2 上 PosterBoard 杀掉后没回来时 Rust 置 true：只有重启
                // 手机能让它重读新表，导入页据此给用户一个“重启手机”按钮。
                result["rebootNeeded"] = obj["reboot_needed"] as? Bool ?? false
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

    /// 装完刷新（V1.7 对齐 V1.6 的规矩）：配对只认配对刷新这一下，没确认
    /// 直接报重启手机，不再回落别的刷新。
    /// 27.2 以下：杀 PosterBoard（只动壁纸进程，App 活着）——2026-11-10
    /// 还原日志（restore-20261109-0043）抓到 27.0 杀完 10 轮没回来、
    /// 还自动回落重启桌面，正是卡锁屏图库的那套连招，这条回落删掉。
    /// 27.2 及以上：先重启桌面（27.2 杀 PosterBoard 是死路，V6/V8 已证实），
    /// 没确认直接报需重启手机，不回落杀 PosterBoard。
    /// 返回的字典跟原来第 8 步同一个形状：confirmed / rebootNeeded / json，
    /// 多一个 method（"springboard" 或 "posterboard"），写进报告和日志。
    private static func refreshAfterInstall(pairingPath: String) -> [String: Any] {
        if pairingPath.isEmpty {
            // 没配对：重启桌面那两条 FFI 都碰不了。文件、表、偏好在前面
            // 已经全写好了，直接报重启手机兜底，绝不在没配对时碰 FFI。
            InstallLog.shared.append(
                "restore: 没配对记录，装完的自动刷新（重启桌面）做不了；文件、表、偏好都已写好，重启手机后去图库看。")
            return ["attempted": false, "confirmed": false, "rebootNeeded": true, "method": "none",
                    "error": "没有配对记录，没做自动刷新"]
        }
        if !isIOS27_2OrLater {
            // V1.7：配对只认配对刷新（杀 PosterBoard）这一下。没确认不再
            // 回落重启桌面——还原日志（restore-20261109-0043）抓到 27.0
            // 杀完 10 轮没回来还接着重启桌面，正是卡锁屏图库的那套连招。
            // 直接报重启手机：重启是全新读取，文件、表、偏好都已写好。
            InstallLog.shared.append("restore: 27.2 以下刷新：先杀 PosterBoard（App 不被带掉）…")
            var pb = posterboardRefresh(pairingPath: pairingPath)
            pb["method"] = "posterboard"
            if pb["confirmed"] as? Bool == true {
                InstallLog.shared.append("restore: PosterBoard 刷新已确认，App 还开着，去图库长按看壁纸。")
                return pb
            }
            InstallLog.shared.append("restore: PosterBoard 刷新没确认（\(pb["error"] as? String ?? "见日志")），不再自动重启桌面，直接报重启手机。")
            pb["rebootNeeded"] = true
            if pb["error"] == nil {
                pb["error"] = "PosterBoard 刷新没确认"
            }
            return pb
        }
        InstallLog.shared.append("restore: 刷新：27.2 先试 SpringBoard 重启…")
        var sb = springboardRespringSync(pairingPath: pairingPath)
        sb["method"] = "springboard"
        if sb["confirmed"] as? Bool == true {
            InstallLog.shared.append("restore: SpringBoard 重启已确认，桌面回来了，去图库看壁纸。")
            return sb
        }
        // V8：27.2 上杀 PosterBoard 是死路（V6 日志证实表对了也不回来），
        // 不再杀——直接报需重启手机，导入页弹出“重启手机”按钮。
        InstallLog.shared.append("restore: SpringBoard 重启没确认（\(sb["error"] as? String ?? "见日志")），27.2 上不杀 PosterBoard，直接报需重启手机。")
        return ["attempted": true, "confirmed": false, "rebootNeeded": true, "method": "springboard",
                "error": sb["error"] as? String ?? "SpringBoard 重启没确认"]
    }

    /// 同步版 SpringBoard 重启：给 restore() 第 8 步用（restore 是同步的，
    /// 不能 await 那个异步版）。跟 posterboardRefresh 一个写法：直接在调用
    /// 线程调 al_springboard_respring（FFI 会阻塞，调用方必须在后台线程，
    /// runRestore 的文档就是这么要求的）。返回 confirmed / old_pid / new_pid / error。
    private static func springboardRespringSync(pairingPath: String) -> [String: Any] {
        "10.7.0.1".withCString { _ = al_set_target_host($0) }
        var outJson: UnsafeMutablePointer<CChar>? = nil
        var outError: UnsafeMutablePointer<CChar>? = nil
        let rc = pairingPath.withCString { pairC in
            al_springboard_respring(pairC, airliftLogCallback, nil, &outJson, &outError)
        }
        var result: [String: Any] = ["attempted": true, "rc": rc, "confirmed": false]
        if let p = outJson {
            let json = String(cString: p)
            al_string_free(p)
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result["json"] = obj
                result["confirmed"] = obj["respring_confirmed"] as? Bool ?? false
            }
            InstallLog.shared.append("restore: SpringBoard 重启：\(json)")
        }
        if let p = outError {
            let error = String(cString: p)
            al_string_free(p)
            result["error"] = error
            InstallLog.shared.append("restore: SpringBoard 重启没回 JSON：\(error)")
        }
        return result
    }

    /// 一键重启手机：调 al_device_respring（diagnostics_relay Restart，
    /// 是整机重启，不是只刷桌面——按钮文案必须写“重启手机”，不许写
    /// “刷新桌面”或“Respring”；2026-11-01 没打招呼的整机重启就是教训）。
    /// 只在刷新失败、PosterBoard 杀掉后没回来时给用户亲手点；绝不自动调。
    /// FFI 会阻塞，放后台线程跑；返回 true 只代表指令发出去了，不代表
    /// 手机已经重启完。
    static func deviceReboot(pairingPath: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            "10.7.0.1".withCString { _ = al_set_target_host($0) }
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc = pairingPath.withCString { pairC in
                al_device_respring(pairC, airliftLogCallback, nil, &outError)
            }
            if let p = outError {
                let error = String(cString: p)
                al_string_free(p)
                InstallLog.shared.append("restore: 重启手机失败：\(error)")
                return false
            }
            InstallLog.shared.append("restore: 已发送重启手机指令（rc=\(rc)）。")
            return rc == 0
        }.value
    }

    /// SpringBoard 重启测试：调 al_springboard_respring（DVT SIGKILL
    /// SpringBoard，只重启桌面、不重启手机；跟换语言时系统重启桌面一个
    /// 道理）。只给状态页诊断日志那张测试卡用；绝不自动调，必须用户亲手点。
    /// FFI 会阻塞，放后台线程跑；桌面重启时 App 可能被系统一起杀掉，那时
    /// 结果回不来，用户直接看屏幕：黑屏后桌面回来就是成了，黑屏超过 1 分钟
    /// 没回来就长按电源键强制重启。日志在 InstallLog 里（落盘了），重开
    /// App 还能看。返回的字典里 confirmed / old_pid / new_pid / error。
    static func springboardRespring(pairingPath: String) async -> [String: Any] {
        await Task.detached(priority: .userInitiated) {
            "10.7.0.1".withCString { _ = al_set_target_host($0) }
            var outJson: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc = pairingPath.withCString { pairC in
                al_springboard_respring(pairC, airliftLogCallback, nil, &outJson, &outError)
            }
            var result: [String: Any] = ["rc": rc, "confirmed": false]
            if let p = outJson {
                let json = String(cString: p)
                al_string_free(p)
                if let data = json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    result.merge(obj) { _, new in new }
                    result["confirmed"] = obj["respring_confirmed"] as? Bool ?? false
                }
                InstallLog.shared.append("restore: SpringBoard 重启测试：\(json)")
            }
            if let p = outError {
                let error = String(cString: p)
                al_string_free(p)
                result["error"] = error
                InstallLog.shared.append("restore: SpringBoard 重启测试没回 JSON：\(error)")
            }
            return result
        }.value
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
            let summary = "列不出来：表还没存下来，重启手机一次、装一张壁纸后再来列。"
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
