import Foundation

/// 壁纸怎么送到手机上。
///
/// 这是两条路，不是同一件事的两种做法——它们只是恰好装的是同一张壁纸，
/// 所以选哪条得由用户定，界面上也要说清各要付出什么。
///
///  - `.backup` 是备份路：取商店的数据库，把壁纸编成载荷，经一次保护性
///    备份和一次还原送回去。所有这 App 能用的设备上都行，最后要重启手机。
///  - `.airlift` 是 AirCard 那路：用已有的配对记录开一条 AirTraffic 隧道，
///    直接往 PosterBoard 的数据容器里写。不备份、不重启，respring 一下
///    就够，但要 iOS 26.2+、LocalDevVPN、手机解锁，而且做不了商店重置。
///
/// AirLift 是默认。备份路不是更好的一条：它要一次完整的保护性备份加一次
///    重启，唯一多出来的本事是商店重置。两条都不想要的用户什么都不用付，
///    所以便宜的那条是默认。
public enum PosterBoardApplyMode: String, CaseIterable, Identifiable, Hashable {
    case backup
    case airlift

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .backup: return "保护性备份"
        case .airlift: return "AirLift（直写）"
        }
    }

    var symbol: String {
        switch self {
        case .backup: return "externaldrive.fill"
        case .airlift: return "bolt.horizontal.circle.fill"
        }
    }

    /// 这条路会做什么、不会做什么，用用户的话讲。
    var summary: String {
        switch self {
        case .backup:
            return "先取商店的数据库，再把壁纸经一次保护性备份送回去。"
                + "所有支持的设备上都行，最后要重启手机。"
        case .airlift:
            return "经隧道直接往 PosterBoard 容器里写——不备份，respring 一下"
                + "就行。要 iOS 26.2 或更新、LocalDevVPN、手机解锁。"
        }
    }

    /// 这条路能不能做重置。
    ///
    /// 重置是商店操作：清掉 PosterBoard 已索引的东西。AirLift 那条路
    /// 只往里加描述符目录，所以在那条路上选了重置不会被悄悄吞掉——
    /// 安装会在碰设备之前就说做不了、停下。
    var supportsReset: Bool {
        self == .backup
    }
}

/// 选中的模式，存法和 `autoRefresh` 一样。
enum PosterBoardApplyModeSettings {
    static let key = "PosterBoardApplyMode"

    /// 默认 AirLift，除非有东西另有说法。
    ///
    /// 只有存下来的值能把它从 AirLift 上移开；一台从来没碰过选择器的
    /// 设备什么都没存，所以默认就是它拿到的。
    /// 按实际目标机解析存下来的 AirLift 选择，不抹掉用户给另一台
    /// 支持的设备留的偏好。
    static func resolved(deviceVersion: String, buildVersion: String) -> PosterBoardApplyMode {
        if AirliftAvailability.isHidden(deviceVersion: deviceVersion, buildVersion: buildVersion) {
            return .backup
        }
        return current
    }

    static var current: PosterBoardApplyMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return .airlift }
            return PosterBoardApplyMode(rawValue: raw) ?? .airlift
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
