import Foundation

/// 备份模式的正式安装流程：改表还原（拿表 → 插行 → 写 configurations →
/// 注入 descriptors → 写偏好 → 写回表 → 刷新）。
///
/// 旧的那套 MobileBackup2 定点备份（取 PosterBoard 备份 → 清单剪裁 → 还原）
/// 已证实死在 27.0.1 上（手机根本不认 Applications 定点，备的永远是整台），
/// 不再走。新的这套就是原来状态页上还原测试跑通的那套：拿表先走 Phase 0
/// 备份（备份 → 抽表），备份拿不到再走 AirTraffic 拷回通道（探针 3 那条），
/// 文件走直写那条 AirTraffic 写通道，描述符和偏好照直装补上，
/// 表写回后调刷新；刷新确认了不用重启手机。
///
/// 不再有旧的 iOS 27 门控：那是给旧备份流的（占位 Manifest.db、sqlite 清单
/// 全是 27 的备份形状）；新流程不用 MobileBackup2，门控不在这里——
/// 走哪条路，由 AppState 按设备版本解析（直写被藏时自动切备份）。
/// 也不再要设备身份和 zip：容器路径走配对找，编包自己建 ZipFoundationAdapter。
enum BackupInstallFlow {

    /// 备份路装完的结果。`descriptorUUID` 是编包时新编的 UUID
    ///（`configurations/` 下那个），和包里原来的 UUID 不一样——
    /// 数据库行和文件用的都是这个新的，两边必须一致。
    struct Outcome {
        let descriptorUUID: String
        let extensionID: String
        let payloadCount: Int
        let storeSummary: String
        let preferencesWritten: Bool
        let refreshConfirmed: Bool
        /// 描述符注入逐目标结果（主扩展 + 现代扩展）。
        let injectResults: [InjectResult]
        /// 刷新没确认才要重启手机。
        var needsReboot: Bool { !refreshConfirmed }
    }

    static func install(packageData: Data,
                        pairingPath: String,
                        log: @escaping BackupLog = { _ in },
                        onProgress: ((String, Double) -> Void)? = nil) async throws -> Outcome {
        onProgress?("正在取表…", 0.05)
        log("备份还原：走改表还原（拿表 → 插行 → 写文件 → 写回表 → 写偏好 → 刷新），不用整机备份。")
        // RestoreTest.runRestore 是同步阻塞的（FFI + SQLite），放后台线程跑。
        // 停止按钮取消的是上层 Task，后台那路看不到取消标记，所以用取消盒
        // 中转：上层取消时这里的轮询立刻抛取消、关弹窗，不等后台回来；
        // 后台 runRestore 在下一步边界查到取消标记就自己停。
        // 进度由 runRestore 按步骤报（拿表 5%→30% → 写文件 50% → 插行 70% →
        // 写回 85% → 刷新 100%），不在这里写死一个数。
        try Task.checkCancellation()
        let cancelBox = CancelBox()
        let outcomeBox = OutcomeBox()
        _ = Task.detached(priority: .userInitiated) {
            let outcome = RestoreTest.runRestore(
                packageData: packageData, pairingPath: pairingPath,
                onProgress: onProgress,
                isCancelled: { cancelBox.isCancelled })
            outcomeBox.finish(outcome)
        }
        let outcome: RestoreOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await waitForOutcome(outcomeBox)
            } onCancel: {
                cancelBox.cancel()
            }
        } catch {
            // 取消或等待出错：不等后台回来，直接抛，调用方关弹窗报“已停止”。
            cancelBox.cancel()
            throw error
        }
        try Task.checkCancellation()
        guard outcome.success else {
            throw BackupError(outcome.summary)
        }
        guard let uuid = outcome.descriptorUUID, let ext = outcome.extensionID else {
            throw BackupError("备份还原跑完了，但没拿到描述符信息，日志里看详情。")
        }
        onProgress?("备份还原完成", 1.0)
        return Outcome(descriptorUUID: uuid,
                       extensionID: ext,
                       payloadCount: outcome.payloadCount ?? 0,
                       storeSummary: outcome.storeSummary ?? "",
                       preferencesWritten: outcome.preferencesWritten,
                       refreshConfirmed: outcome.refreshConfirmed,
                       injectResults: outcome.injectResults)
    }

    /// 测试版安装：只写描述符、不写表（拿表/插行/写回全跳过），写完偏好
    /// 等 5 秒，直接报重启手机。和 install() 同一个等法（后台跑
    /// runRestoreTestMode，取消盒中转，进度由里面按步骤报）。
    /// Outcome 里 refreshConfirmed 一定是 false，needsReboot 一定是 true。
    static func installTest(packageData: Data,
                            pairingPath: String,
                            log: @escaping BackupLog = { _ in },
                            onProgress: ((String, Double) -> Void)? = nil) async throws -> Outcome {
        onProgress?("正在问手机要壁纸位置…", 0.05)
        log("测试版：走只写描述符（不写表），写完偏好等 PosterBoard 重扫，再重启手机。")
        try Task.checkCancellation()
        let cancelBox = CancelBox()
        let outcomeBox = OutcomeBox()
        _ = Task.detached(priority: .userInitiated) {
            let outcome = RestoreTest.runRestoreTestMode(
                packageData: packageData, pairingPath: pairingPath,
                onProgress: onProgress,
                isCancelled: { cancelBox.isCancelled })
            outcomeBox.finish(outcome)
        }
        let outcome: RestoreOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await waitForOutcome(outcomeBox)
            } onCancel: {
                cancelBox.cancel()
            }
        } catch {
            cancelBox.cancel()
            throw error
        }
        try Task.checkCancellation()
        guard outcome.success else {
            throw BackupError(outcome.summary)
        }
        guard let uuid = outcome.descriptorUUID, let ext = outcome.extensionID else {
            throw BackupError("测试版跑完了，但没拿到描述符信息，日志里看详情。")
        }
        onProgress?("测试版完成", 1.0)
        return Outcome(descriptorUUID: uuid,
                       extensionID: ext,
                       payloadCount: outcome.payloadCount ?? 0,
                       storeSummary: outcome.storeSummary ?? "",
                       preferencesWritten: outcome.preferencesWritten,
                       refreshConfirmed: outcome.refreshConfirmed,
                       injectResults: outcome.injectResults)
    }

    /// 等后台 runRestore 写结果盒：先看盒里有没有（活刚好干完按成功算），
    /// 没有再查取消、睡 0.2 秒再看；上层 Task 取消（点了停止）就立刻抛，
    /// 不等后台那路回来，弹窗马上关。
    private static func waitForOutcome(_ box: OutcomeBox) async throws -> RestoreOutcome {
        while true {
            if let outcome = box.outcome { return outcome }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}

/// 取消标记盒：上层 Task 取消时置位，后台阻塞调用在步骤之间查。
private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = true
    }
}

/// runRestore 的结果盒：后台线程写完、轮询循环读。
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcome: RestoreOutcome?
    var outcome: RestoreOutcome? {
        lock.lock(); defer { lock.unlock() }
        return _outcome
    }
    func finish(_ outcome: RestoreOutcome) {
        lock.lock(); defer { lock.unlock() }
        _outcome = outcome
    }
}
