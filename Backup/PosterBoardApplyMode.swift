import Foundation

/// 壁纸怎么送到手机上。
///
/// V1.20 起只剩一条路（Vellum 同款：只写描述符目录，不碰表和偏好，
/// 全程不碰配对隧道），安装报告固定标 `.backup`；枚举留着是报告
/// 字段还在用它，别的路都删了。
public enum PosterBoardApplyMode: String, CaseIterable, Identifiable, Hashable {
    case backup
}
