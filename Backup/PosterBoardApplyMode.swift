import Foundation

/// 壁纸怎么送到手机上。
///
/// 这是三条路，不是同一件事的三种做法——它们只是恰好装的是同一张壁纸，
/// 所以选哪条得由用户定，界面上也要说清各要付出什么。
///
///  - `.backup` 是备份路：把 PosterBoard 那张表拿回来改一行，再把壁纸
///    文件和描述符写进容器、把改好的表写回去、写一次偏好、调一次刷新。
///    不用整机备份；刷新确认了不用重启手机。直写那条路走不通的设备
///    （27.2 起）走这条。
///  - `.airlift` 是 AirCard 那路：用已有的配对记录开一条 AirTraffic 隧道，
///    直接往 PosterBoard 的数据容器里写。不备份、不重启，respring 一下
///    就够，但要 iOS 26.2+、LocalDevVPN、手机解锁，而且做不了商店重置。
///  - `.test` 是测试版：只写描述符文件和 configurations，不读表、不插行、
///    不写回数据库，写完先试 PBF 轻量刷新（写偏好），不行再重启手机。
///    27.2 新路子（Vellum 那套只写描述符的思路），还在验证。
///
/// AirLift 是默认。备份路不是更好的一条：它要拿表改表、最后可能还要
/// 重启一次，唯一多出来的本事是商店重置。两条都不想要的用户什么都不用付，
/// 所以便宜的那条是默认。
public enum PosterBoardApplyMode: String, CaseIterable, Identifiable, Hashable {
    case backup
    case airlift
    case test

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .backup: return "备份还原"
        case .airlift: return "AirLift（直写）"
        case .test: return "测试版"
        }
    }

    var symbol: String {
        switch self {
        case .backup: return "externaldrive.fill"
        case .airlift: return "bolt.horizontal.circle.fill"
        case .test: return "testtube.2"
        }
    }

    /// 这条路会做什么、不会做什么，用用户的话讲。
    var summary: String {
        switch self {
        case .backup:
            return "改表还原：先拿表改一行，再把壁纸写进容器、写回表、写偏好、刷新。"
                + "不用整机备份；刷新确认了不用重启手机。"
        case .airlift:
            return "经隧道直接往 PosterBoard 容器里写——不备份，respring 一下"
                + "就行。要 iOS 26.2 或更新、LocalDevVPN、手机解锁。"
        case .test:
            return "只写描述符文件、不碰数据库表，写完先试轻量刷新，"
                + "不行再重启手机。"
        }
    }

    /// 这条路能不能做重置。
    ///
    /// 重置是商店操作：清掉 PosterBoard 已索引的东西。AirLift 那条路
    /// 只往里加描述符目录，所以在那条路上选了重置不会被悄悄吞掉——
    /// 安装会在碰设备之前就说做不了、停下。
    /// 测试版也一样：只写描述符、不碰商店，重置做不了（只有备份路能做）。
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
