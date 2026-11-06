import AirliftFFI
import Foundation

/// Rust 备份 FFI（`rust-core/src/backup.rs`）的 Swift 封装。
///
/// 三个函数都是阻塞的——一定在后台队列上调，不要在主线程上调。
/// 成功时 Rust 给一段 JSON（`out_json`），失败时给一段错误文本
/// （`out_error`），两段都用 `al_string_free` 释放。
///
/// 回调的 `ctx` 用 `Unmanaged` 装一个盒子传过去，不用全局量：
/// 日志和进度闭包都存在盒子里，Rust 调回来时再取出来。
enum BackupFFI {
    // MARK: - 结果

    struct FetchResult {
        let udid: String
        /// `<backupRoot>/<udid>`，设备备份实际落下的目录。
        let backupDir: URL
        let isEncrypted: Bool
        let keptFiles: Int
        let discardedFiles: Int
        let lastProgress: Double
        let manifestDBBytes: Int
        let finalResponse: [String: Any]?
    }

    struct RestoreResult {
        /// 只有设备确认了还原、且进度到头时才为真。设备中途放弃的还原，
        /// 结束时看起来和完成的一模一样——只信这个字段，不信"没报错"。
        let completed: Bool
        let lastProgress: Double
        let finalResponse: [String: Any]?
    }

    struct DeviceInfo {
        let udid: String
        /// 如 "27.0.1"。
        let productVersion: String
        /// 如 "24A437"（27.0.1）、"24B5089g"（27.2 beta 2）。
        let buildVersion: String
        /// 如 "iPhone17,2"。
        let productType: String
        let deviceName: String
    }

    /// 取备份/还原的实时进度：百分比 + 累计字节/文件数（跨 DL 批次累计）。
    /// `bytesTotal` 是当前这批的预期总量（不知道时为 0）。
    struct ProgressDetail {
        let percent: Double
        let bytesDone: UInt64
        let bytesTotal: UInt64
        let filesDone: UInt32
    }

    // MARK: - 设备身份

    // MARK: - 取表

    /// 只备 PosterBoard 一个容器。调之前先用
    /// `PosterBoardBackup.prepareFetchDirectory` 把目录备好。
    static func fetchPosterBoard(pairingPath: String, backupRoot: URL,
                                 log: @escaping BackupLog = { _ in },
                                 onProgress: ((ProgressDetail) -> Void)? = nil) async throws -> FetchResult {
        let box = CallbackBox(log: log, onProgress: onProgress)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        // 盒子不能用 defer 放：任务被取消时这个函数先返回了，Rust 还在
        // 后台读数据、还会调回调；盒子必须活到 Rust 调用真正回来那一刻，
        // 在派发的块里放掉（见下面）。
        let resumeBox = ResumeBox<FetchResult>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resumeBox.set(continuation)
                if Task.isCancelled {
                    // 还没开始就被取消了：不调 FFI，直接把盒子放掉。
                    Unmanaged<CallbackBox>.fromOpaque(ctx).release()
                    resumeBox.cancel()
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result: Result<FetchResult, Error> = pairingPath.withCString { pairingC in
                        backupRoot.path.withCString { rootC in
                            var outJSON: UnsafeMutablePointer<CChar>?
                            var outError: UnsafeMutablePointer<CChar>?
                            let rc = al_backup_fetch_posterboard(
                                pairingC, rootC, logCallback, progressCallback, ctx,
                                &outJSON, &outError)
                            guard rc == 0 else {
                                return .failure(BackupError(
                                    "取 PosterBoard 备份失败：\(errorString(outError))"))
                            }
                            do {
                                let json = try jsonDictionary(outJSON)
                                guard let udid = json["udid"] as? String,
                                      let backupDir = json["backup_dir"] as? String else {
                                    return .failure(BackupError("取备份的结果缺字段，读不懂。"))
                                }
                                return .success(FetchResult(
                                    udid: udid,
                                    backupDir: URL(fileURLWithPath: backupDir),
                                    isEncrypted: json["is_encrypted"] as? Bool ?? false,
                                    keptFiles: json["kept_files"] as? Int ?? 0,
                                    discardedFiles: json["discarded_files"] as? Int ?? 0,
                                    lastProgress: json["last_progress"] as? Double ?? -1,
                                    manifestDBBytes: json["manifest_db_bytes"] as? Int ?? 0,
                                    finalResponse: json["final_response"] as? [String: Any]))
                            } catch {
                                return .failure(error)
                            }
                        }
                    }
                    Unmanaged<CallbackBox>.fromOpaque(ctx).release()
                    resumeBox.resume(with: result)
                }
            }
        } onCancel: {
            resumeBox.cancel()
        }
    }

    // MARK: - 还原

    /// 还原一份备好的备份目录。`reboot` 默认 false：还原本身不重启，
    /// 调用方在还原成功后另外重启（GoldenNugget 手机版也一样）。
    static func restore(pairingPath: String, backupRoot: URL, reboot: Bool = false,
                        log: @escaping BackupLog = { _ in },
                        onProgress: ((ProgressDetail) -> Void)? = nil) async throws -> RestoreResult {
        let box = CallbackBox(log: log, onProgress: onProgress)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        // 盒子不能用 defer 放：原因同 fetchPosterBoard，见那里。
        let resumeBox = ResumeBox<RestoreResult>()
        let options = "{\"reboot\":\(reboot ? "true" : "false")}"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resumeBox.set(continuation)
                if Task.isCancelled {
                    Unmanaged<CallbackBox>.fromOpaque(ctx).release()
                    resumeBox.cancel()
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result: Result<RestoreResult, Error> = pairingPath.withCString { pairingC in
                        backupRoot.path.withCString { rootC in
                            options.withCString { optionsC in
                                var outJSON: UnsafeMutablePointer<CChar>?
                                var outError: UnsafeMutablePointer<CChar>?
                                let rc = al_backup_restore(
                                    pairingC, rootC, optionsC, logCallback, progressCallback, ctx,
                                    &outJSON, &outError)
                                guard rc == 0 else {
                                    return .failure(BackupError(
                                        "还原失败：\(errorString(outError))"))
                                }
                                do {
                                    let json = try jsonDictionary(outJSON)
                                    return .success(RestoreResult(
                                        completed: json["completed"] as? Bool ?? false,
                                        lastProgress: json["last_progress"] as? Double ?? -1,
                                        finalResponse: json["final_response"] as? [String: Any]))
                                } catch {
                                    return .failure(error)
                                }
                            }
                        }
                    }
                    Unmanaged<CallbackBox>.fromOpaque(ctx).release()
                    resumeBox.resume(with: result)
                }
            }
        } onCancel: {
            resumeBox.cancel()
        }
    }

    // MARK: - 设备身份

    /// 只读设备身份：UDID、iOS 版本、build、机型、设备名。
    /// 不写盘、不改设备——安装前先调它，定用哪条路（`AirliftAvailability`）、
    /// 拿备目录要的 UDID。失败就是隧道/配对不通，原样报给用户。
    static func deviceInfo(pairingPath: String,
                           log: @escaping BackupLog = { _ in }) async throws -> DeviceInfo {
        let box = CallbackBox(log: log)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<CallbackBox>.fromOpaque(ctx).release() }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<DeviceInfo, Error> = pairingPath.withCString { pairingC in
                    var outJSON: UnsafeMutablePointer<CChar>?
                    var outError: UnsafeMutablePointer<CChar>?
                    let rc = al_device_info(
                        pairingC, logCallback, ctx, &outJSON, &outError)
                    guard rc == 0 else {
                        return .failure(BackupError(
                            "读不到设备身份：\(errorString(outError))"))
                    }
                    do {
                        let json = try jsonDictionary(outJSON)
                        guard let udid = json["udid"] as? String,
                              let productVersion = json["product_version"] as? String,
                              let buildVersion = json["build_version"] as? String,
                              let productType = json["product_type"] as? String else {
                            return .failure(BackupError("设备身份缺字段，读不懂。"))
                        }
                        return .success(DeviceInfo(
                            udid: udid,
                            productVersion: productVersion,
                            buildVersion: buildVersion,
                            productType: productType,
                            deviceName: json["device_name"] as? String ?? ""))
                    } catch {
                        return .failure(error)
                    }
                }
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - 应用注册

    /// 一个 bundle id 的 InstallationProxy 原始记录，给
    /// `Manifest.plist` 的 `Applications` 注册用。
    /// 返回的就是 Rust JSON 里 `entry` 那层字典。
    static func appFactoryEntry(pairingPath: String, bundleID: String,
                                log: @escaping BackupLog = { _ in }) async throws -> [String: Any] {
        let box = CallbackBox(log: log)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<CallbackBox>.fromOpaque(ctx).release() }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<[String: Any], Error> = pairingPath.withCString { pairingC in
                    bundleID.withCString { bundleC in
                        var outJSON: UnsafeMutablePointer<CChar>?
                        var outError: UnsafeMutablePointer<CChar>?
                        let rc = al_backup_app_factory_entry(
                            pairingC, bundleC, logCallback, ctx, &outJSON, &outError)
                        guard rc == 0 else {
                            return .failure(BackupError(
                                "取 \(bundleID) 的应用记录失败：\(errorString(outError))"))
                        }
                        do {
                            let json = try jsonDictionary(outJSON)
                            guard let entry = json["entry"] as? [String: Any] else {
                                return .failure(BackupError(
                                    "\(bundleID) 的应用记录缺 entry，读不懂。"))
                            }
                            return .success(entry)
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - 私有

    /// 只恢复一次的 continuation 盒子：Rust 阻塞调用回来了、或者任务被取消了，
    /// 两边都可能来恢复，先到的那次生效，另一边不再碰。
    /// `set` 时如果已经取消了，立刻用取消错误恢复，不等 Rust。
    private final class ResumeBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var resumed = false
        private var cancelled = false

        func set(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock(); defer { lock.unlock() }
            if cancelled {
                resumed = true
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
        }

        func resume(with result: Result<T, Error>) {
            lock.lock(); defer { lock.unlock() }
            guard !resumed, let continuation else { return }
            resumed = true
            self.continuation = nil
            continuation.resume(with: result)
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            guard !resumed, let continuation else { return }
            resumed = true
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    /// 装日志和进度闭包的盒子，经 `ctx` 传给 Rust。
    private final class CallbackBox: @unchecked Sendable {
        let log: BackupLog
        var onProgress: ((ProgressDetail) -> Void)?
        init(log: @escaping BackupLog, onProgress: ((ProgressDetail) -> Void)? = nil) {
            self.log = log
            self.onProgress = onProgress
        }
    }

    /// Rust 日志回调：`ALLogCallback(ctx, msg)`。
    private static let logCallback: @convention(c) (UnsafeMutableRawPointer?,
                                                    UnsafePointer<CChar>?) -> Void = { ctx, msg in
        guard let ctx, let msg else { return }
        Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
            .log(String(cString: msg))
    }

    /// Rust 进度回调：`ALBackupProgressCallback(ctx, percent, bytes_done, bytes_total, files_done)`，
    /// percent 在 [0, 100]，-1 表示不知道；字节/文件数是跨 DL 批次累计的。
    private static let progressCallback: @convention(c) (UnsafeMutableRawPointer?,
                                                         Double, UInt64, UInt64, UInt32) -> Void = { ctx, percent, bytesDone, bytesTotal, filesDone in
        guard let ctx else { return }
        Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
            .onProgress?(ProgressDetail(percent: percent, bytesDone: bytesDone, bytesTotal: bytesTotal, filesDone: filesDone))
    }

    /// `out_json` 指针对应的字典，用完释放。
    private static func jsonDictionary(_ ptr: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        guard let ptr else { throw BackupError("Rust 返回了空结果。") }
        defer { al_string_free(ptr) }
        let data = Data(String(cString: ptr).utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw BackupError("Rust 返回的结果不是 JSON 对象，读不懂。")
        }
        return dict
    }

    /// `out_error` 指针对应的文本，用完释放。指针是空时给一句通用的。
    private static func errorString(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
        guard let ptr else { return "原因不明" }
        defer { al_string_free(ptr) }
        return String(cString: ptr)
    }
}
