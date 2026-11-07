import Foundation

/// 安装方式三选一：自动 / 直写 / 备份还原。
///
/// 和 `PosterBoardApplyModeSettings` 的分工：
/// - 那个存的是"直写还是备份"的偏好（默认直写），`resolved()` 按实际
///   目标机解析：AirLift 被藏起来时自动走备份，不抹掉用户给另一台
///   设备留的偏好。
/// - 这个存的是用户在界面上点的三态。点"自动"就是走上面那套解析；
///   点"直写"或"备份还原"是明说——但"直写"点在一台直写已堵的设备上
///   也装不上，提示行会先说清楚，装的时候还是按用户点的来，
///   失败原样报，不悄悄换路。
enum ApplyModeChoice: String, CaseIterable, Identifiable {
    case auto
    case airlift
    case backup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .airlift: return "直写（iOS 27）"
        case .backup: return "iOS 27.2"
        }
    }

    /// 存在 UserDefaults 里，key 和两态偏好分开。默认自动。
    private static let key = "PosterBoardApplyModeChoice"

    static var current: ApplyModeChoice {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return .auto }
            return ApplyModeChoice(rawValue: raw) ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// 这次安装实际走哪条路。版本读不到时 `AirliftAvailability` 按藏起来
    /// 处理（fail closed），所以自动会落到备份路——不要猜版本走直写。
    func resolvedMode(deviceVersion: String, buildVersion: String) -> PosterBoardApplyMode {
        switch self {
        case .auto:
            return PosterBoardApplyModeSettings.resolved(deviceVersion: deviceVersion,
                                                        buildVersion: buildVersion)
        case .airlift:
            return .airlift
        case .backup:
            return .backup
        }
    }

    /// 提示行：这次实际会用的模式 + 为什么。设备版本读不到时明说，
    /// 不装作知道。
    func hintText(deviceVersion: String, buildVersion: String) -> String {
        let mode = resolvedMode(deviceVersion: deviceVersion, buildVersion: buildVersion)
        guard !deviceVersion.isEmpty else {
            return "设备版本读不到，这次将用备份还原（读不到版本时默认走备份）。"
        }
        switch (self, mode) {
        case (.auto, .backup):
            if deviceVersion.hasPrefix("27.2") {
                return "这台设备将用：备份还原（iOS 27.2，27.2 beta 3 起直写已堵）。"
            }
            return "这台设备将用：备份还原（这台设备直写不可用）。"
        case (.auto, .airlift):
            return "这台设备将用：直写（iOS 27，适用 iOS 26.2–27.2 beta 2）。"
        case (.airlift, .airlift):
            if AirliftAvailability.isHidden(deviceVersion: deviceVersion, buildVersion: buildVersion) {
                return "这次将用：直写（iOS 27）——但这台设备直写已堵，选了也装不上，建议改自动。"
            }
            return "这次将用：直写（iOS 27，适用 iOS 26.2–27.2 beta 2）。"
        case (.backup, .backup):
            if deviceVersion.hasPrefix("27.2") {
                return "这次将用：备份 27.2（支持 iOS 27.2 及以上）。"
            }
            // 27.0.1 上手动选备份：走改表还原（不用整机备份），不用只等 27.2。
            return "这次将用：备份 27.2（支持 iOS 27.2 及以上）。"
        default:
            // 正常走不到这里（强制选的模式就是返回的模式）；兜底也按
            // 界面上的叫法写（带 iOS 版本号），不用 `mode.title`（那是不带版本号的"备份还原"）。
            return "这次将用：\(mode == .backup ? "备份 27.2（支持 iOS 27.2 及以上）" : "直写（iOS 27）")。"
        }
    }
}
