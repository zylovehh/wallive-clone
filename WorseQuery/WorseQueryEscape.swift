import Foundation

/// worse_query 沙箱逃逸的 Swift 封装（27.2 新路子）。
///
/// 原理：对目标路径吃一个沙箱扩展（containermanagerd 查询 +
/// App Group 容器内符号链接），句柄 > 0 期间，本进程可以用普通
/// FileManager 直接读写目标路径——27.2 上不再依赖配对隧道的
/// AirTraffic 写通道。
///
/// 加强版（worse_query_escape2）：
///  - class 7 一次试 3 组 flags（第一组 0x8100000000 是上游 worse_query 没有的）；
///  - 全挂后按用户开关再试 class 2 的 4 组 flags（兜 iOS 27.3，带熔断）；
///  - 拿到扩展先探测可写，不行就把扩展还回去，不留半开着的门；
///  - 启动时自检：上次崩溃留下的假 Caches 符号链接自动收拾干净。
///
/// 上游：github.com/forcequitOS/worse_query（GPL-3.0，Taj C / forcequit）。
/// 本目录的 worse_query.h/.m 在上游拷贝上做了本项目扩展（escape2/多组 flags），
/// 扩展全部沿用 GPL-3.0。分发含本代码的安装包即触发 GPL-3.0 开源义务，
/// 见 WorseQuery/README.md。
@_silgen_name("wq_escape")
private func wq_escape(_ target: UnsafePointer<CChar>?,
                       _ group: UnsafePointer<CChar>?,
                       _ altFlags: Bool,
                       _ createDir: Bool) -> Int64

@_silgen_name("wq_escape2")
private func wq_escape2(_ target: UnsafePointer<CChar>?,
                        _ group: UnsafePointer<CChar>?,
                        _ createDir: Bool,
                        _ allowClass2: Bool,
                        _ lastCode: UnsafeMutablePointer<Int64>?,
                        _ lastClass: UnsafeMutablePointer<Int32>?,
                        _ lastIndex: UnsafeMutablePointer<Int32>?) -> Int64

@_silgen_name("wq_release")
private func wq_release(_ handle: Int64)

enum WorseQueryEscape {

    /// 逃逸用的 App Group：改成 Vellum 在同一台手机上实测可用的组
    /// （2026-11-10 用户贴出的 Vellum 日志：group.com.tgqq.1767742703，
    /// 容器 /private/var/mobile/Containers/Shared/AppGroup/35E720DF-…/ 真实存在）。
    /// 旧的 group.com.usc.1787713824 在这台 27.2 手机上 containerURL 拿不到。
    static let appGroup = "group.com.tgqq.1767742703"

    /// 共享抽屉体检：27.2 逃逸的先决条件是 App Group 容器真实存在。
    /// 返回容器路径（nil = 签名没把它配好）和一句给人看的结论。
    static func groupHealth() -> (containerPath: String?, note: String) {
        let fm = FileManager.default
        if let root = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return (root.path, "共享抽屉正常，逃逸有门可走。路径：\(root.path)")
        }
        return (nil, "共享抽屉没开：签名时没把这个组配好。去全能签核对 App Group 设置（应为 \(appGroup)，可对照 Vellum 签名时用的组名）。")
    }

    // ---- class 2 备用招的开关与熔断（存 UserDefaults）----
    private static let class2OptInKey = "wq.class2.optIn"
    private static let class2FailuresKey = "wq.class2.failures"
    private static let class2DisabledKey = "wq.class2.autoDisabled"
    /// 连续失败这么多次就自动停用备用招，防止反复折腾系统
    private static let class2FuseLimit = 3

    /// 备用招开关（默认关，和 Vellum 一个思路：有风险的功能要用户点头）。
    static var class2OptIn: Bool {
        get { UserDefaults.standard.bool(forKey: class2OptInKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: class2OptInKey)
            if newValue {
                // 重新打开时清掉旧熔断状态
                UserDefaults.standard.set(false, forKey: class2DisabledKey)
                UserDefaults.standard.set(0, forKey: class2FailuresKey)
            }
        }
    }

    /// 熔断后置 true；用户把开关关了再开才算重新启用。
    static var class2AutoDisabled: Bool {
        UserDefaults.standard.bool(forKey: class2DisabledKey)
    }

    /// 错误码 → 中文说明（对应上游 ContentView 的 switch）。
    static func describe(_ handle: Int64) -> String {
        switch handle {
        case -1: return "App Group 容器访问不了"
        case -2: return "系统符号解析失败（系统版本可能不支持）"
        case -3: return "建容器查询失败"
        case -4: return "容器内建符号链接失败"
        case -5: return "查询被 containermanagerd 拒了"
        case -6: return "内核拒发沙箱扩展"
        case -255: return "目标路径不存在"
        default: return "未知错误（\(handle)）"
        }
    }

    /// 对目标路径吃沙箱扩展（加强版）。成功返回正句柄；失败返回 nil，原因同时
    /// 写进日志并放在返回值 failReason 里（27.2 砍掉老通道后，报错要带上它）。
    /// - Parameters:
    ///   - target: 目标路径（必须已存在，逃逸不建目录）。
    static func consume(target: String,
                        log: @escaping (String) -> Void = { _ in }) -> (handle: Int64?, failReason: String?, detail: String?) {
        let fm = FileManager.default
        let class2Allowed = class2OptIn && !class2AutoDisabled
        if class2OptIn && class2AutoDisabled {
            log("class 2 备用招之前连败 \(class2FuseLimit) 次已自动停用；到状态页重新开关一次可重置。")
        }

        var lastCode: Int64 = 0
        var lastClass: Int32 = 0
        var lastIndex: Int32 = -1
        let handle = target.withCString { t in
            appGroup.withCString { g in
                wq_escape2(t, g, false, class2Allowed, &lastCode, &lastClass, &lastIndex)
            }
        }

        if handle > 0 {
            let flagDesc = lastClass > 0 ? "\(lastClass == 7 ? "class 7" : "class 2 备用招") 第 \(lastIndex + 1) 组 flags" : ""
            log("逃逸成功：沙箱扩展句柄 \(handle)" + (flagDesc.isEmpty ? "" : "（\(flagDesc)）") + "。")

            // 写前探测：拿到扩展不等于真能写，先试一下，不行就把扩展还回去
            guard Self.probeWrite(target: target, fm: fm) else {
                wq_release(handle)
                log("扩展拿到了，但目标还是写不进，探测失败，扩展已还回去。本次安装终止。")
                return (nil, "沙箱扩展已获取，但目标仍不可写（probe 失败）", flagDesc.isEmpty ? nil : flagDesc)
            }
            log("探测通过：目标现在真的可写。")
            if class2Allowed { UserDefaults.standard.set(0, forKey: class2FailuresKey) }
            return (handle, nil, flagDesc.isEmpty ? nil : flagDesc)
        }

        // 失败：记录错误；若 class 2 参与过且失败，累加熔断计数
        let reason = describe(lastCode)
        if class2Allowed {
            let failures = UserDefaults.standard.integer(forKey: class2FailuresKey) + 1
            UserDefaults.standard.set(failures, forKey: class2FailuresKey)
            if failures >= class2FuseLimit {
                UserDefaults.standard.set(true, forKey: class2DisabledKey)
                log("class 2 备用招连败 \(failures) 次，已自动停用，防止反复折腾系统。")
            }
        }
        let tried: String
        switch lastClass {
        case 2: tried = "class 7 三组 + class 2 备用招都"
        case 13: tried = "class 7 三组 + class 13 免组兜底路都"
        default: tried = "class 7 三组 flags 都"
        }
        log("逃逸没成（\(reason)，\(tried)试过，最后一组：class \(lastClass) 第 \(lastIndex + 1) 组）。27.2 不再回落老通道，本次安装终止。")
        return (nil, reason, "最后失败：class \(lastClass) 第 \(lastIndex + 1) 组 flags，\(tried)均试过")
    }

    /// 释放沙箱扩展。负数/零句柄忽略，安全重复调。
    static func release(_ handle: Int64?) {
        guard let handle, handle > 0 else { return }
        wq_release(handle)
    }

    // MARK: - 写前探测

    /// 真写一次再删，比只看权限位可靠。
    private static func probeWrite(target: String, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target, isDirectory: &isDir) else { return false }
        if !isDir.boolValue {
            return fm.isWritableFile(atPath: target)
        }
        let probe = (target as NSString).appendingPathComponent(".wq_probe-\(UUID().uuidString)")
        let ok = fm.createFile(atPath: probe, contents: Data("probe".utf8))
        if ok { try? fm.removeItem(atPath: probe) }
        return ok
    }

    // MARK: - 崩溃自愈

    /// 上次崩溃可能把 App Group 里的 Library/Caches 留成了指向壁纸库的
    /// 符号链接。启动时检查：还是软链就拆掉，重建真正的空目录。
    static func recoverStaleSymlink(log: @escaping (String) -> Void = { _ in }) {
        let fm = FileManager.default
        guard let groupRoot = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let caches = groupRoot.appendingPathComponent("Library/Caches").path
        guard fm.fileExists(atPath: caches) else { return }
        guard let original = try? fm.destinationOfSymbolicLink(atPath: caches) else { return }
        do {
            try fm.removeItem(atPath: caches)
            try fm.createDirectory(atPath: caches, withIntermediateDirectories: true)
            log("自愈：收拾了上次没拆干净的符号链接（原来指向 \(original)），Caches 已恢复成空目录。")
        } catch {
            log("自愈：符号链接收拾失败（\(error.localizedDescription)），下次启动再试。")
        }
    }
}
