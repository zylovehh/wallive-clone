import Foundation

/// 把解出来的 .tendies 暂存目录编成备份载荷。
///
/// 照 GoldenNugget 手机版 `Nugget/Core/PosterBoard.swift` 里的
/// `PosterBoard.compile` + `PosterBoardBuilder.walk` 搬过来，只改了
/// 三处：`TweakPayload` → `BackupPayload`、`GoldenNuggetError` →
/// `BackupError`、日志走 `BackupLog`。行为一个字没动。
///
/// 关键点（原版注释里讲清的，v1 全部保留）：
/// - 一张壁纸只送一次，走 `Extensions/<提供方>/configurations/<UUID>`——
///   这是设备自己的商店里唯一有的形状，也是参考实现唯一写的形状。
///   早期版本还把每份文件在 `Extensions/com.apple.Posters.CollectionsPosterApp/`
///   `descriptors/` 下再发一份"为了在添加壁纸里显示"——那是图库描述符通道，
///   不是已装海报：iOS 27.0.1 的商店里根本没有 `descriptors` 目录，
///   身份重复还会在启动时逼商店重建（每张壁纸都没了）。不要双写。
/// - 描述符目录名换成新 UUID（只换这一层，`versions/`、`1/`、`contents/`
///   保持设备自己的名字），同时在数据库行、角色 sidecar、描述符标识
///   sidecar、userInfo、`Wallpaper.plist` 里把 id 对齐。
/// - 每个描述符版本目录（`versions/1/`）都换上
///   `PosterBoardResources.configConversion` 里那三份配置 plist。
/// - 不做的事：legacy 转换（`convertLegacyPack`）没搬。我们的包都是编辑器
///   导出的现代格式（`descriptors/<UUID>/versions/1/contents`）；老格式的包
///   在这里一个描述符都找不到，`compile` 会直接报错，不会悄悄送个空包。
/// - Mercury 那路的 identifier 是它自己的文本查找键，绝不重写。
enum PosterBoardCompiler {

    /// 编包结果：要送的载荷 + 要往商店数据库里加的行。
    /// `configs` 为空说明包里一个描述符都没找到，调用方必须报错停下，
    /// 不能拿着空载荷去还原。
    static func compile(stageDirectory: URL, structureVersion: Int,
                        log: @escaping BackupLog = { _ in }) throws
        -> (payloads: [BackupPayload], configs: [PosterBoardConfigItem]) {
        var builder = PosterBoardBuilder(structureVersion: structureVersion, log: log)
        try builder.walk(currentPath: stageDirectory, restorePath: "", isAdding: false)
        return (builder.payloads, builder.configs)
    }
}

/// 描述符的数字 id 取值范围（手机版 `PosterBoard.identifierRange`）。
private let posterIdentifierRange = 9_999...99_999

private struct PosterBoardBuilder {
    let structureVersion: Int
    let log: BackupLog
    var payloads: [BackupPayload] = []
    var configs: [PosterBoardConfigItem] = []

    /// 每个描述符版本目录都换上的三份配置 plist 的文件名（按名字排过序，
    /// 见 `PosterBoard` 的 divergence note）。
    static var configFileNames: [String] { PosterBoardResources.configConversion.keys.sorted() }

    /// 描述符的身份 sidecar，`provider.descriptor.identifier`——walk 要保持
    /// 一致的三个身份字段里的第一个，第三方包最常漏的就是它。
    static let descriptorIdentifierFile = "com.apple.posterkit.provider.descriptor.identifier"

    mutating func walk(currentPath: URL,
                       restorePath: String,
                       isAdding: Bool = false,
                       randomizeUUID: Bool = false,
                       randomizedID: Int? = nil) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: currentPath.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        let children = (try? fm.contentsOfDirectory(atPath: currentPath.path)) ?? []
        let ordered = children.sorted()
        // 上游按 `os.listdir` 的大小排这张表——和下面的循环不一样，
        // 下面那圈不过滤点文件。保持一致，包拿到的 id 才和上游给的一样。
        var orderedIDs: [Int] = []
        if isAdding, randomizeUUID,
           currentPath.path.contains("ordered-descriptor") {
            // PosterBoard 按 id 倒序排壁纸，所以 ordered-descriptor 的包
            // 拿降序 id，出来才是它自己的顺序。
            let base = Int.random(in: posterIdentifierRange)
            orderedIDs = (0..<children.count).map { base + $0 }.sorted(by: >)
        }
        var counter = 0

        for child in ordered {
            // 只跳 Finder / 归档垃圾，**不是**"所有点开头的文件"：
            // `.com.apple.posterkit.provider.contents.configurableOptions.plist`
            // 是合法的描述符 plist（苹果用前导点把它藏起来），里面带着
            // `preferredRenderingConfiguration`——编辑器读它才有深景控制。
            // 把所有点文件都跳了，送到的描述符就没有深景控制可给。
            if child == "__MACOSX" || child == ".DS_Store" || child.hasPrefix("._") { continue }
            let childPath = currentPath.appendingPathComponent(child)

            if isAdding {
                var folderName = child
                var currentID = randomizedID
                if randomizeUUID {
                    if currentPath.path.contains("ordered-descriptor") {
                        folderName = UUID().uuidString.uppercased()
                        currentID = orderedIDs[counter]
                        counter += 1
                    } else {
                        folderName = UUID().uuidString.uppercased()
                        currentID = Int.random(in: posterIdentifierRange)
                    }
                    // 扩展名从刚搭好的路径里读回来——
                    // `/<商店>/<版本>/Extensions/<扩展>/configurations` 的第 6 段。
                    // 只有这一层能走到这里，也是唯一一层路径是这个形状。
                    let components = restorePath.components(separatedBy: "/")
                    guard components.count > 6 else {
                        throw BackupError("PosterBoard：从 \(restorePath) 里读不出提供方"
                            + "扩展名——描述符被送到了意料之外的地方。")
                    }
                    configs.append(PosterBoardConfigItem(uuid: folderName,
                                                         extensionID: components[6],
                                                         setSelected: true,
                                                         numericId: isMercury(restorePath) ? nil : currentID))
                }

                let destination = joined(restorePath, folderName)
                var childIsDirectory: ObjCBool = false
                guard fm.fileExists(atPath: childPath.path, isDirectory: &childIsDirectory) else { continue }

                // 图库描述符还不是 configurations。原生 iOS 27 的 configurations
                // 除了 SQL 里的 membership，还带这个角色 sidecar；DVD 屏保这类
                // 第三方包没有，这里补上。
                let roleFile = "com.apple.posterkit.role.identifier"
                if randomizeUUID, childIsDirectory.boolValue,
                   !fm.fileExists(atPath: childPath.appendingPathComponent(roleFile).path) {
                    payloads.append(BackupPayload(domain: PosterBoard.domain,
                                                  relativePath: joined(destination, roleFile),
                                                  contents: Data("PRPosterRoleLockScreen".utf8)))
                }

                // 第三方 .tendies 通常不带 `provider.descriptor.identifier` sidecar。
                // PosterKit 就会自己编一个，和 `contents.userInfo` / `Wallpaper.plist`
                // 对不上，WallpaperKit 建视图时直接 trap——所以在这里盖上，
                // 用的就是另外两个身份字段那个随机 id。参考实现只在 `randomizeUUID`
                // 那个分支里做，也就是只在正在改名的那一层，Mercury 除外
                //（它的 identifier 是自己的文本查找键）。
                if randomizeUUID, let currentID, childIsDirectory.boolValue,
                   !isMercury(restorePath),
                   !fm.fileExists(atPath: childPath
                       .appendingPathComponent(Self.descriptorIdentifierFile).path) {
                    payloads.append(BackupPayload(domain: PosterBoard.domain,
                                                  relativePath: joined(destination,
                                                                       Self.descriptorIdentifierFile),
                                                  contents: Data(String(currentID).utf8)))
                }

                if !childIsDirectory.boolValue {
                    if Self.configFileNames.contains(child) {
                        // 包自带一份转换 plist；下面在版本目录那层用
                        // `PosterBoardResources` 里那份换掉它。
                        continue
                    }
                    let rewritten = rewrittenContents(directory: currentPath,
                                                      fileName: child,
                                                      identifier: currentID,
                                                      restorePath: restorePath)
                    switch rewritten {
                    case .none:
                        payloads.append(BackupPayload(domain: PosterBoard.domain,
                                                      relativePath: destination,
                                                      source: childPath))
                    case .bytes(let data):
                        payloads.append(BackupPayload(domain: PosterBoard.domain,
                                                      relativePath: destination,
                                                      contents: data))
                    case .unreadable(let error):
                        // 参考实现碰到 `IOError` 就跳过。保留，但说出来：
                        // 一个悄悄缺了的描述符文件，就是一张只有一半的壁纸。
                        log("  ⚠️ 跳过 \(destination)：\(error)")
                    }
                } else {
                    // 每个描述符版本目录都换上参考实现那三份转换 plist。
                    if currentPath.lastPathComponent == "versions",
                       currentPath.path.contains("descriptor") {
                        for fileName in Self.configFileNames {
                            guard let data = PosterBoardResources.configConversion[fileName] else { continue }
                            payloads.append(BackupPayload(domain: PosterBoard.domain,
                                                          relativePath: joined(destination, fileName),
                                                          contents: data))
                        }
                    }
                    try walk(currentPath: childPath,
                             restorePath: destination,
                             isAdding: true,
                             randomizeUUID: false,
                             randomizedID: currentID)
                }
                continue
            }

            // 没在加：分流，或者往下走。
            let lower = child.lowercased()
            if lower == "container" {
                // container 是整份数据商店快照：从商店根开始走，
                // 里面的描述符文件夹和自制包一样分流进 configurations、注册。
                try walk(currentPath: childPath, restorePath: "/", isAdding: false)
                return
            }
            if lower.contains("descriptor") {
                let extensionID = try self.extensionID(descriptorDirectory: currentPath,
                                                       descriptorName: lower)
                try walk(currentPath: childPath,
                         restorePath: "\(PosterBoard.storePath(structureVersion))/Extensions/"
                             + "\(extensionID)/configurations",
                         isAdding: true,
                         randomizeUUID: true)
                continue
            }
            try walk(currentPath: childPath, restorePath: restorePath, isAdding: false)
        }
    }

    /// 一个描述符目录属于哪个提供方扩展——参考实现的四路分支，按原顺序。
    private func extensionID(descriptorDirectory: URL, descriptorName: String) throws -> String {
        let parent = descriptorDirectory.lastPathComponent
        if parent.hasPrefix("com.apple.") { return parent }
        if descriptorName.contains("video") || descriptorName.contains("photos") {
            return PosterBoard.photosExtension
        }
        if descriptorName.contains("mercury") { return PosterBoard.mercuryExtension }
        return PosterBoard.collectionsExtension
    }

    /// `f"{restore_path}/{folder_name}".replace("//", "/")`。
    ///
    /// 参考实现用 join 拼路径，再把 `container/` 那一路产生的双斜杠压掉
    ///（它从 `/` 起步）。清单的 fileID 就是按这份路径算的，所以压掉这一步
    /// 必须恰好发生在这里。
    private func joined(_ base: String, _ component: String) -> String {
        "\(base)/\(component)".replacingOccurrences(of: "//", with: "/")
    }

    /// `update_plist_id` + `update_for_family` 对一个文件字节做的事。
    private enum Rewrite {
        case none
        case bytes(Data)
        case unreadable(String)
    }

    /// 参考实现重写描述符里的三个文件名，让里面的 id 和刚编的目录名一致。
    /// 一张壁纸的 `identifier` 和自己的目录对不上，提供方就解析不出来。
    private func rewrittenContents(directory: URL,
                                   fileName: String,
                                   identifier: Int?,
                                   restorePath: String) -> Rewrite {
        guard let identifier else { return .none }
        // MercuryPoster 的配置自带文本 identifier（"v6x.colorB"），
        // `userInfo.lookIdentifier` 和 `suggestionMetadata` 都指着它；
        // 改成随机数字会断掉查找链，所以那个扩展的 identifier 原样保留。
        if isMercury(restorePath) { return .none }

        let fileURL = directory.appendingPathComponent(fileName)
        do {
            switch true {
            case fileName == Self.descriptorIdentifierFile:
                return .bytes(Data(String(identifier).utf8))
            case fileName == "com.apple.posterkit.provider.contents.userInfo":
                // 顶层，而且是**字符串**。`recursive: true` 只会*替换*已有的键，
                // 第三方 tendie 的 userInfo 本来就没有
                // `wallpaperRepresentingIdentifier`——所以这个键得加上，不是
                // 光覆盖，否则 WallpaperKit 解包 nil 直接 trap
                //（makeViewProvider 里 EXC_BREAKPOINT）。商店里的描述符
                // 这个 id 存的是文本，参考实现这里写的也是文本。
                return .bytes(try PosterBoardPlist.set(contentsOf: fileURL,
                                                       key: "wallpaperRepresentingIdentifier",
                                                       value: String(identifier),
                                                       recursive: false))
            case fileName.hasSuffix("Wallpaper.plist"):
                // 只改顶层（`recursive=False`），再按 iOS 26.4+ 要的
                // Configs（Marble）模型对齐。
                let withIdentifier = try PosterBoardPlist.set(contentsOf: fileURL,
                                                              key: "identifier",
                                                              value: identifier,
                                                              recursive: false)
                return .bytes(try PosterBoardPlist.alignedForFamily(withIdentifier))
            default:
                return .none
            }
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// `PosterboardTweak.is_mercury`：商店相对路径的第 6 段。
    private func isMercury(_ restorePath: String) -> Bool {
        let parts = restorePath.components(separatedBy: "/")
        return parts.count > 6 && parts[6] == PosterBoard.mercuryExtension
    }
}
