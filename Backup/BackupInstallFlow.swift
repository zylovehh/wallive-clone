import Foundation

/// 备份模式的正式安装流程：改表还原（拿表 → 插行 → 写 configurations →
/// 注入 descriptors → 写偏好 → 写回表 → 刷新）。
///
/// 旧的那套 MobileBackup2 定点备份（取 PosterBoard 备份 → 清单剪裁 → 还原）
/// 已证实死在 27.0.1 上（手机根本不认 Applications 定点，备的永远是整台），
/// 不再走。新的这套就是原来状态页上还原测试跑通的那套：表走 AirTraffic
/// 拷回通道拿（探针 3 那条），文件走直写那条 AirTraffic 写通道，
/// 描述符和偏好照直装补上，表写回后调刷新；刷新确认了不用重启手机。
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
        onProgress?("正在取表、改表、写回…", 0.10)
        log("备份还原：走改表还原（拿表 → 插行 → 写文件 → 写回表 → 写偏好 → 刷新），不用整机备份。")
        // RestoreTest.runRestore 是同步阻塞的（FFI + SQLite），放后台线程跑；
        // 取消只能在跑之前和跑完之后响应，跑中间停不下来（阻塞调用中途不停）。
        try Task.checkCancellation()
        let outcome = await Task.detached(priority: .userInitiated) {
            RestoreTest.runRestore(packageData: packageData, pairingPath: pairingPath)
        }.value
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
}
