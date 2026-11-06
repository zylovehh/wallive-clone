import Foundation

/// 备份还原路上的错误。对应 GoldenNugget 的 `GoldenNuggetError`，只改名和文案：
///
/// 原版就是一个只装一句话的错误类型，所有调用处直接传一句话进来；这里也一样，
/// 不搞一堆 case——调用处写什么，用户在日志里就看到什么。
/// 错误信息一律中文（用户在安装页日志里直接看到）。
struct BackupError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// 备份流程的日志回调。所有移植文件的日志都走这个参数传进来，不用全局量：
///
/// 原版用 `AppLog.write`（全局单例）；我们这边安装页有自己的 InstallLog，
/// 以后接线时由调用方把写日志的闭包传进来。这里默认什么都不做，
/// 调用方不传也不会崩。
typealias BackupLog = @Sendable (String) -> Void
