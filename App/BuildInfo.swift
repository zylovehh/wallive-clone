import Foundation

/// 版本号 fallback：本地编包、没走 Codemagic 盖戳时用这个。
/// Codemagic 编包时会在 Archive 之前重写这个文件（见 codemagic.yaml 的
/// "Stamp build number into version tag"），tag 变成“V6·日期-构建号”。
enum BuildInfo {
    static let tag = "V6·1104免重启"
}
