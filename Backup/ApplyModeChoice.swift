import Foundation

/// 安装方式三选一：自动 / 直写 / 27.2。
///
/// 和 `PosterBoardApplyModeSettings` 的分工：
/// - 那个存的是"直写还是备份"的偏好（默认直写），`resolved()` 按实际
///   目标机解析：AirLift 被藏起来时自动走备份，不抹掉用户给另一台
///   设备留的偏好。
/// - 这个存的是用户在界面上点的三态。点"自动"就是走上面那套解析；
///   点"直写"或"27.2"是明说——但"直写"点在一台直写已堵的设备上
///   也装不上，装的时候还是按用户点的来，失败原样报，不悄悄换路。
enum ApplyModeChoice: String, CaseIterable, Identifiable {
    case auto
    case airlift
    case backup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .airlift: return "直写（iOS 27）"
        case .backup: return "27.2"
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

    /// 提示行：这个按钮支持的系统版本范围，只写范围，别写别的。
    func hintText(deviceVersion: String, buildVersion: String) -> String {
        switch self {
        case .auto:
            return "自动选择"
        case .airlift:
            return "iOS 26.2 - 27.2 beta 2"
        case .backup:
            return "iOS 27.2+"
        }
    }
}
