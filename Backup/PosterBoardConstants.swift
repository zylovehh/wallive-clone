import Foundation

/// PosterBoard 的固定常量。对应 GoldenNugget 的 `PosterBoard` enum 里
/// 与取表、编包有关的那部分；选壁纸、导视频、偏好设置那堆不在这里。
///
/// 壁纸不是偏好：每一张壁纸 = 描述符目录（在
/// `<容器>/Library/Application Support/PRBPosterExtensionDataStore/<版本>/`
/// `Extensions/<扩展>/configurations/<UUID>/…`）+ 商店数据库里的一行，
/// 缺了数据库那行，锁屏选择器里根本看不到它。所以装壁纸要先取到
/// 设备自己的数据库、往里加行、再把改好的库送回去——这就是备份这条路
/// 存在的理由。
enum PosterBoard {
    /// 容器所属的包名；所有要还原的文件都落在 `AppDomain-<包名>` 里。
    static let bundleID = "com.apple.PosterBoard"
    static let domain = "AppDomain-\(bundleID)"

    /// 描述符可能属于的扩展。
    static let mercuryExtension = "com.apple.MercuryPoster"
    static let photosExtension = "com.apple.PhotosUIPrivate.PhotosPosterProvider"
    static let collectionsExtension = "com.apple.WallpaperKit.CollectionsPoster"

    /// 商店目录。数字后缀是**结构版本**（61、62……），苹果每次改版就加一；
    /// 不能写死，从取回来的数据库自己的路径上读，没有才退回 61。
    static let storeDirectoryName = "PRBPosterExtensionDataStore"
    static let storeRoot = "/Library/Application Support/\(storeDirectoryName)"
    static let fallbackStructureVersion = 61

    /// 商店数据库的文件名。按**文件名**认，不按路径——iOS 27 上传时走的是
    /// 原始路径树（`/.b/<n>/Containers/…`），路径里有时连商店目录名都没有。
    static let databaseFileName = "PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"

    /// 完整重置后商店偏好的落点。
    static let preferencesPath =
        "/Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist"

    /// `/Library/Application Support/PRBPosterExtensionDataStore/<版本>`。
    static func storePath(_ structureVersion: Int) -> String {
        "\(storeRoot)/\(structureVersion)"
    }
}

/// 这次要加的一张壁纸：桌面版的 `PBConfigItem`。
///
/// `uuid` 是编包时给描述符目录起的随机名，数据库 `poster` 表里的行
/// 用的也是同一个字符串——两边必须一致，否则选择器里会出现一张
/// 找不到文件的壁纸。
struct PosterBoardConfigItem: Equatable {
    let uuid: String
    let extensionID: String
    /// 是否把它设为当前选中。桌面版给每张都设，最后加的那张胜出。
    let setSelected: Bool
}
