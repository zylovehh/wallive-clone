import Foundation

/// 还原的薄封装：调 Rust 的 `al_backup_restore`，按设备的回应验真。
///
/// 完成判定照 Rust 那边：final_response 里没有 ErrorCode、且进度到头
/// （或设备从来没报过进度）才算成。设备中途放弃的还原，结束时看起来
/// 和完成的一模一样——旧版 GoldenNugget 手机版就吃过这个亏：进度停在
/// 55% 也报成功。只信 `completed`，不信"没报错"。
enum RestoreRunner {
    /// 还原一份备好的备份目录（`<backupRoot>/<udid>/`）。
    /// 还原本体不重启；成功后调用方另外重启手机（备份路的规矩：
    /// 还原完必须重启一次，壁纸才会进图库）。
    static func runRestore(backupRoot: URL, pairingPath: String,
                           log: BackupLog = { _ in }) async throws {
        log("正在还原备份…")
        // 进度按 5% 一档记，太碎了日志没法看。Rust 那边已经按整
        // 百分比节流过一次，这里只做分档。
        var lastLoggedStep = -1
        let result = try await BackupFFI.restore(
            pairingPath: pairingPath, backupRoot: backupRoot, reboot: false, log: log
        ) { percent in
            guard percent >= 0 else { return }
            let step = Int(percent / 5) * 5
            guard step != lastLoggedStep else { return }
            lastLoggedStep = step
            log("还原进度 \(step)%")
        }
        guard result.completed else {
            let progress = result.lastProgress >= 0 ? "\(Int(result.lastProgress))%" : "未知"
            let reason: String
            if result.finalResponse == nil {
                reason = "设备没有给最后的回应"
            } else if let errorCode = result.finalResponse.flatMap({ $0["ErrorCode"] }) {
                reason = "设备回了错误码 \(errorCode)"
            } else {
                reason = "进度没到头"
            }
            throw BackupError("还原没完成（进度 \(progress)，\(reason)）。"
                + "设备上的壁纸没动，再试一次或改走 AirLift 那路。")
        }
        log("还原完成（设备进度 \(Int(result.lastProgress))%），重启手机后壁纸进图库")
    }
}
