import Foundation

/// 设备给一个备份 domain 写的一行是什么形状。
///
/// 取自设备自己在
/// `MobileSync/Backup/00008130-001431082E40001C`（iPad16,2 / iOS 27.0
/// 24A5424a）里的行——和 `MBFileBlob` 的常量同一份实测依据，
/// 规则也一样：设备的记录就是约定。GoldenNugget 给每个 plist tweak
/// 盖 `Tweak.__init__` 默认的 `owner=501, group=501`，设备按 domain
/// 不同意（脚注那行是 `-2/-2`，一个 `DatabaseDomain` 行是 `0/0`），
/// 设备赢。
///
/// `verified` 记的是这款 App 有没有真的拿这个形状跑通过一次还原。
/// 设成 `true` 的两档是本 App 已经交付过的类（`AppDomain-*` 和脚注的
/// `SysSharedContainerDomain`）；其余是量过但没跑过的，运行时在日志里
/// 提醒一句，不悄悄当成验证过的来报。
struct BackupRowProfile {
    let fileOwner: Int
    let fileGroup: Int
    let fileProtectionClass: Int
    /// 文件行的数据保护例外发布者；设备的文件行完全没有例外时是 nil
    /// （实测：`SystemPreferencesDomain`）。
    let fileExceptionPublisher: String?
    let dirOwner: Int
    let dirGroup: Int
    let dirProtectionClass: Int
    let rootOwner: Int
    let rootGroup: Int
    let rootProtectionClass: Int
    /// 这个 domain 的**文件**行带不带 `Digest`（载荷的 SHA-1）。不是风格
    /// 选择：设备在有的 domain 每个文件行上都写、在有的上面一个都不写，
    /// 而一个它对不上载荷的文件记录会回
    /// `MBErrorDomain/205 — "Manifest references files not in backup"`。
    ///
    /// 按设备自己的备份量，110 个带文件行的 domain 分得一清二楚，
    /// 没有一个混着来：
    ///
    ///   * **带**（11 个）：`ManagedPreferencesDomain`、`HomeDomain`、
    ///     `SystemPreferencesDomain`、`DatabaseDomain`、`RootDomain`、
    ///     `MobileDeviceDomain`、`WirelessDomain`、`NetworkDomain`、
    ///     `KeychainDomain`、`ProtectedDomain`、`InstallDomain`
    ///     （`ManagedPreferencesDomain` 4/4，`HomeDomain` 708/708、
    ///     `SystemPreferencesDomain` 9/9、`DatabaseDomain` 3/3）；
    ///   * **不带**（99 个）：`AppDomain*` 家族、
    ///     `SysSharedContainerDomain-*`、`SysContainerDomain-*`、`CameraRollDomain`。
    ///
    /// 目录行和符号链接行永远不带，所以这条只对文件行有意义。
    ///
    /// 两个 `false` 是本 App 已经拿来还原过的两类——AppDomain
    /// （应用容器流程）和 SysSharedContainer（锁屏脚注）——这也正是
    /// 一个从不写摘要的注入器在两边都能过、却过不了下面四档的原因。
    let carriesDigest: Bool
    let verified: Bool
    /// 这些数从哪来，给提醒那行日志用。
    let note: String

    /// 给一个 domain 挑形状。
    static func forDomain(_ domain: String) -> BackupRowProfile {
        if domain == "SysContainerDomain-com.apple.eligibilityd" { return .eligibilityContainer }
        if domain == "AppDomain-com.apple.PosterBoard" { return .posterBoardContainer }
        if domain.hasPrefix("AppDomain") { return .appContainer }
        if domain.hasPrefix("SysSharedContainerDomain") || domain.hasPrefix("SysContainerDomain") {
            return .systemContainer
        }
        switch domain {
        case "ManagedPreferencesDomain": return .managedPreferences
        case "HomeDomain": return .homeDomain
        case "SystemPreferencesDomain": return .systemPreferences
        case "DatabaseDomain": return .database
        default: return .unmeasured
        }
    }
}

extension BackupRowProfile {
    /// Project Linwood 的 eligibilityd 存档约定，从桌面版照搬。
    static let eligibilityContainer = BackupRowProfile(
        fileOwner: 0, fileGroup: 0, fileProtectionClass: 4,
        fileExceptionPublisher: nil,
        dirOwner: 0, dirGroup: 0, dirProtectionClass: 0,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: 0,
        carriesDigest: false, verified: false,
        note: "Project Linwood eligibilityd shape; mobile device verification pending")

    /// `AppDomain-*`：`BackupInjector.inject` 已经在交付的那一类，
    /// 有生产证据（本 App 自己的应用容器还原）。
    static let appContainer = BackupRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: PROTECTION_CLASS_FILE,
        fileExceptionPublisher: "com.apple.containermanagerd_system",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: PROTECTION_CLASS_DIR,
        rootOwner: 501, rootGroup: 501, rootProtectionClass: PROTECTION_CLASS_DIR,
        carriesDigest: false,
        verified: true,
        note: "AppDomain-* rows, as delivered by BackupInjector.inject")

    /// PosterBoard 的 live 快照给 Library、商店和偏好文件用级别 4。
    /// 通用的应用容器级别 3 不是它的行约定。
    static let posterBoardContainer = BackupRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: 4,
        fileExceptionPublisher: "com.apple.containermanagerd_system",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: 4,
        rootOwner: 501, rootGroup: 501, rootProtectionClass: 0,
        carriesDigest: false, verified: true, note: "PosterBoard native snapshot row classes")

    /// `SysSharedContainerDomain-*`：`BackupInjector.injectSystemPlist`
    /// 已经在交付的那一类（锁屏脚注），有生产证据。
    static let systemContainer = BackupRowProfile(
        fileOwner: -2, fileGroup: -2, fileProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.containermanagerd_system",
        dirOwner: -2, dirGroup: -2, dirProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: PROTECTION_CLASS_DIR,
        carriesDigest: false,
        verified: true,
        note: "SysSharedContainerDomain rows, as delivered by BackupInjector.injectSystemPlist")

    /// 实测：`mobile/com.apple.springboard.plist`、
    /// `mobile/.GlobalPreferences.plist` 和 `mobile/com.apple.sharingd.plist`
    /// 都是 mode 0o100755、`501/501`、级别 4、EA `com.apple.BackupAgent2`；
    /// `mobile` 目录行是 `501/501` 级别 4，domain 根是 `0/0` 级别 4。
    static let managedPreferences = BackupRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        carriesDigest: true,
        verified: false,
        note: "ManagedPreferencesDomain rows")

    /// 实测：`Library/Preferences/.GlobalPreferences.plist` 是 mode
    /// 0o100600、`501/501`、级别 4（EA `com.apple.cfprefsd`），
    /// `com.apple.ScreenTimeAgent.plist` 级别 4、`501/501`（EA
    /// `com.apple.BackupAgent2`）；目录行是级别 0、`501/501`，根也一样。
    /// 文件行只用一个发布者，不按文件列表——`BackupAgent2` 是
    /// 这次移植写的 HomeDomain 偏好文件实测带的值。
    static let homeDomain = BackupRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: PROTECTION_CLASS_DIR,
        rootOwner: 501, rootGroup: 501, rootProtectionClass: PROTECTION_CLASS_DIR,
        carriesDigest: true,
        verified: false,
        note: "HomeDomain rows")

    /// 实测：`SystemConfiguration/*.plist` 是 mode 0o100644、`0/0`、
    /// 级别 4，**没有**扩展属性；目录行和根都是 `0/0` 级别 4。
    static let systemPreferences = BackupRowProfile(
        fileOwner: 0, fileGroup: 0, fileProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: nil,
        dirOwner: 0, dirGroup: 0, dirProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        carriesDigest: true,
        verified: false,
        note: "SystemPreferencesDomain rows")

    /// 实测：`com.apple.xpc.launchd/disabled.plist` 是 `0/0` 级别 4，
    /// EA `com.apple.BackupAgent2`；它的目录行是 `0/0` 级别 4。
    static let database = BackupRowProfile(
        fileOwner: 0, fileGroup: 0, fileProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 0, dirGroup: 0, dirProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        carriesDigest: true,
        verified: false,
        note: "DatabaseDomain rows")

    /// 这个移植没有量过的 domain。退回备份里系统偏好文件最常见的形状，
    /// 每次用它跑都会报"没量过"。
    static let unmeasured = BackupRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        // 跟上面四个量过的 domain 走，不跟两个 `false` 的走：这个退路
        // 能走到的每个 domain（`RootDomain`、`MobileDeviceDomain`）都是
        // 系统 domain，而备份里每个系统 domain 都盖摘要
        // （RootDomain 36/36）。
        carriesDigest: true,
        verified: false,
        note: "no measurement for this domain — using the common system-preference shape")
}
