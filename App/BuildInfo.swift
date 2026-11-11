import Foundation

/// 版本号 fallback：本地编包、没走 Codemagic 盖戳时用这个。
/// Codemagic/Azure 编包时会在 Archive 之前重写这个文件（见 codemagic.yaml 的
/// "Stamp build number into version tag"），tag 变成“V数字 正式版”（#53→V1，之后自动加）。
/// GitHub Actions 编包不盖戳，直接用这里的 tag，所以这里须与当前版本一致。
enum BuildInfo {
    static let tag = "V1.27"
}
