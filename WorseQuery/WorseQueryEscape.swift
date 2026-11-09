import Foundation

/// worse_query 沙箱逃逸的 Swift 封装（27.2 新路子）。
///
/// 原理：对目标路径吃一个沙箱扩展（containermanagerd class 7 查询 +
/// App Group 容器内符号链接），句柄 > 0 期间，本进程可以用普通
/// FileManager 直接读写目标路径——27.2 上不再依赖配对隧道的
/// AirTraffic 写通道。
///
/// 上游：github.com/forcequitOS/worse_query（GPL-3.0，Taj C / forcequit）。
/// 本目录的 worse_query.h/.m 是上游原样拷贝，改动在这里和 Shim 里。
/// 分发含本代码的安装包即触发 GPL-3.0 开源义务，见 WorseQuery/README.md。
@_silgen_name("wq_escape")
private func wq_escape(_ target: UnsafePointer<CChar>?,
                       _ group: UnsafePointer<CChar>?,
                       _ altFlags: Bool,
                       _ createDir: Bool) -> Int64

@_silgen_name("wq_release")
private func wq_release(_ handle: Int64)

enum WorseQueryEscape {

    /// 逃逸用的 App Group：用户已证实全能签会保留这个组
    /// （2026-11-09 提交 001696d 的 zsign 实测结论，按用户最新确认为准）。
    static let appGroup = "group.wb.uniusc8301.tool7.wallive"

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

    /// 对目标路径吃沙箱扩展。成功返回正句柄；失败返回 nil 并把原因写进日志。
    /// - Parameters:
    ///   - target: 目标路径（必须已存在，逃逸不建目录）。
    ///   - altFlags: iOS 26.x 的 App Group 容器要换一组 flags；27.x 用默认 false。
    static func consume(target: String,
                        altFlags: Bool = false,
                        log: @escaping (String) -> Void = { _ in }) -> Int64? {
        let handle = wq_escape(target, appGroup, altFlags, false)
        if handle > 0 {
            log("逃逸成功：沙箱扩展句柄 \(handle)，接下来可以直接写 \(target)。")
            return handle
        }
        log("逃逸没成（\(describe(handle))），这条写盘路用不了，回落原通道。")
        return nil
    }

    /// 释放沙箱扩展。负数/零句柄忽略，安全重复调。
    static func release(_ handle: Int64?) {
        guard let handle, handle > 0 else { return }
        wq_release(handle)
    }
}
