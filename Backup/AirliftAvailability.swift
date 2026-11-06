import Foundation

/// 光看版本号分不出 27.2 的 beta。能用 AirLift 的只有 beta 1（24B5084k）
/// 和 beta 2（24B5089g）；beta 3（24B5099f）起已堵死，不认识的 27.2
/// build 也一律按不能用处理。注意别把 24B5099f 当成 beta 2——它是 beta 3，
/// 是第一个不能用的；桌面版 passcode_support.py 里那个含 24B5099f 的
/// 三元集合是通行码主题功能的支持范围，不是 AirLift 写盘路的。
/// 已用 `ipsw download appledb --os iOS --version "27.2 beta" --json`
/// 和 Apple CDN 上 beta 3 IPSW 的 BuildManifest 核过。
enum AirliftAvailability {
    /// 27.2 beta 3 之前已知的 build（beta 1、beta 2）。
    private static let early272Builds: Set<String> = ["24B5084k", "24B5089g"]

    /// 这台设备上 AirLift 是不是被藏起来了（不能用）。
    /// 版本号或 build 号读不出来时也按藏起来处理（fail closed）。
    static func isHidden(deviceVersion: String, buildVersion: String) -> Bool {
        let parts = deviceVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return true }
        if major != 27 { return major > 27 }
        if minor != 2 { return minor > 2 }
        if parts.count == 3, Int(parts[2]) != 0 { return true }
        return !early272Builds.contains(buildVersion.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
