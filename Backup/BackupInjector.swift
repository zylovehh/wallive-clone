import CryptoKit
import Foundation

/// 把设备刚给的备份变成还原守护进程肯收的样子：先把 `Manifest.db`
/// 剪到磁盘上实际有的东西，再把这次要送的文件写成行和载荷。
///
/// 要送的文件是系统容器 plist，行的形状和应用容器**不是**一种——
/// 不用 `Applications` 注册、属主是 nobody、保护级别 4。形状抄
/// 设备自己给同一条路径写的那行，只有设备的版本不可能是错的。
enum BackupInjector {
    /// 注入一个**不是**应用容器的文件——目前只有锁屏脚注那份
    /// `SysSharedContainerDomain` plist。
    ///
    /// 上面那个 `inject` 带不了它，有两个各自独立的原因：
    ///
    ///   1. 它要注册一个应用包。注册只为一件事——还原守护进程对
    ///      `Applications` 字典里没有对应包名的 `AppDomain-*` 载荷，
    ///      会回 `MBErrorDomain/205 "Unknown domain name in file record"`。
    ///      `SysSharedContainerDomain` 不在那一家里，也没有包可注册，
    ///      这也是参考实现送它的 `BasicPlistTweak` 文件时完全不注册的原因。
    ///   2. 它写的是应用容器的行形状。设备给系统容器 plist 写的是
    ///      另一种形状，而一行设备没自己写过的行，错了没法靠重传修。
    ///
    /// 按设备自己给这个文件写的记录量出来的
    /// （`MobileSync/Backup/00008130-001431082E40001C`，fileID
    /// `0affc9c4722175be11a30bb60e96880ffedf29d5` =
    /// `SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles` /
    /// `Library/ConfigurationProfiles/SharedDeviceConfiguration.plist`）：
    ///
    ///     文件行    Mode 0o100644  UserID -2  GroupID -2  ProtectionClass 4  EA 有
    ///     里层目录  Mode 0o40755   UserID -2  GroupID -2  ProtectionClass 4  EA 无
    ///     domain 根 Mode 0o40755   UserID  0  GroupID  0  ProtectionClass 0  EA 无
    ///
    /// `-2` 是 Darwin 的 `nobody`，就是设备给这条路径记的值（同一个
    /// domain 里别的行混着 `501` 和 `-2`，所以这个值是按行不按 domain 的——
    /// 这里抄的是*这个文件*那行）。扩展属性和应用容器行是同一个
    /// `com.apple.dataprotection.policy.exception-applied-by`，所以
    /// "只有应用容器才有这个属性"那条规则对这类也不成立。
    ///
    /// 属主是故意和 Python 不一样的：GoldenNugget 的 `Tweak.__init__`
    /// 默认 `owner=501, group=501`，所以它合成的脚注行在设备自己给
    /// 同一条路径写的 `-2` 的地方写了 `501`。这里设备的记录赢
    /// （仓库里没有别的地方拿一个 Python 默认值去顶实测），
    /// 从参考实现抄的、它确实对的那部分是：非 `AppDomain-*` 的 domain
    /// 不做 `Applications` 注册。
    ///
    /// 只有常规文件带载荷；目录行是还原代理改名到位时用的路径脚手架
    /// （删了它们代理会报 `renameatx ENOENT`——见剪裁里 `flags == 2`
    /// 那条规则）。
    static func injectSystemPlist(
        into deviceDir: URL,
        domain: String,
        relativePath: String,
        contents: Data,
        log: @escaping BackupLog = { _ in }
    ) throws {
        let fileID = ManifestStore.fileID(domain: domain, relativePath: relativePath)
        let store = ManifestStore(deviceDir: deviceDir, log: log)
        let fm = FileManager.default

        // 1. 载荷放在 fileID 说的位置。和其他行一样的分片布局：
        //    这是数据库和文件树之间的连接点。
        let payloadDir = store.payloadURL(forFileID: fileID).deletingLastPathComponent()
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try contents.write(to: store.payloadURL(forFileID: fileID))

        // 2. 行：domain 根、每个父级一件，最后是文件本身。
        //    和 `inject` 一样的顺序——目录在前，这样在一份全新的
        //    Manifest.db 上不可能和文件行撞主键。
        var rows: [(path: String, flags: Int32)] = [("", 2)]
        var accumulated = ""
        for component in relativePath.split(separator: "/").dropLast() {
            accumulated = accumulated.isEmpty ? String(component) : "\(accumulated)/\(component)"
            rows.append((accumulated, 2))
        }
        rows.append((relativePath, 1))

        let dataprotection = buildDataprotectionExtendedAttributes()
        let now = Int(Date().timeIntervalSince1970)
        // Darwin 的 `nobody`，就是设备给系统容器文件记的 -2。
        // 负数 id 在这里是合法的：它是 `uid_t` 4294967294 在归档里
        // 来回一趟之后的样子，设备自己就是这么产生的。
        let systemOwner = -2

        for row in rows {
            let isFile = row.flags == 1
            // domain 根行是上面实测里唯一的例外：设备在那里写 0/0、
            // 保护级别 0，下面的行都是 `nobody`、级别 4。
            let isRoot = row.path.isEmpty
            let owner = isRoot ? 0 : systemOwner
            let rowID = ManifestStore.fileID(domain: domain, relativePath: row.path)
            let blob = buildMBFileBlob(
                relativePath: row.path,
                mode: isFile
                    ? (Int(MODE_FILE_DEFAULT) | Int(S_IFREG))
                    : (Int(MODE_DIR_DEFAULT) | Int(S_IFDIR)),
                size: isFile ? contents.count : 0,
                userID: owner,
                groupID: owner,
                protectionClass: isRoot ? PROTECTION_CLASS_DIR : PROTECTION_CLASS_SYSTEM_FILE,
                inodeNumber: inode(for: rowID),
                timestamp: now,
                // 只有文件行带扩展属性，按上面的实测。
                extendedAttributes: isFile ? dataprotection : nil)
            try store.upsert(fileID: rowID, domain: domain,
                             relativePath: row.path, flags: row.flags, blob: blob)
        }

        log("已注入系统 plist \(domain)/\(relativePath)"
            + "（fileID=\(fileID)，\(contents.count) 字节，属主 \(systemOwner)，级别 "
            + "\(PROTECTION_CLASS_SYSTEM_FILE)）")
        log(store.blobKeySample(ours: fileID))
    }

    /// 给一行清单一个稳定、可信的 inode。
    ///
    /// 设备给它建的每一行都写 `InodeNumber`（抽样的 4000/4000 个
    /// `AppDomain-*` 文件行），从来不写 0；两行共用一个 inode 就是
    /// 在对文件树撒谎。从 `fileID` 推出来，所以重跑一次得到的数一样，
    /// 再映射进设备自己的 inode 所在的区间（那份备份里是
    /// 87278…1306390），而不是一个一眼就是编的数。
    static func inode(for fileID: String) -> Int {
        let head = Insecure.SHA1.hash(data: Data(fileID.utf8))
            .prefix(4)
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return 100_000 + Int(head % 900_000)
    }

    /// 注入的报告。
    struct Report {
        let files: Int
        let dirRows: Int
        /// 行形状量过、但还没跑通过一次还原的 domain。
        let unverifiedDomains: [String]

        var summary: String {
            "\(files) 个文件，\(dirRows) 个目录行"
        }
    }

    /// 把编译好的载荷写进一份备份，变成可还原的行。
    ///
    /// 每个文件的行集合和 `injectSystemPlist` 用的是同一套，
    /// 也是 GoldenNugget `_ensure_directory_rows` 建的那套：一个
    /// domain 根行、每个父级一件 `flags == 2` 的行，最后是
    /// `flags == 1` 的文件行——"iOS 27 的还原代理会跳过父目录
    /// 没有清单行的文件"（`src/restore/inject.py:211-219`）。
    ///
    /// inode 从清单当前的最大值往上数，和 `inject_file_into_backup`
    /// 一样，因为代理按 inode 去重，复用一个 inode 就会还原出
    /// 错的字节。
    ///
    /// 行是 upsert 的，所以重跑是幂等的。
    static func inject(into deviceDir: URL, payloads: [BackupPayload],
                       preservedDirectories: Set<String> = [],
                       preservedFileMetadata: [String: Data] = [:],
                       log: @escaping BackupLog = { _ in }) throws -> Report {
        let store = ManifestStore(deviceDir: deviceDir, log: log)
        let fm = FileManager.default
        let now = Int(Date().timeIntervalSince1970)
        var nextInode = store.maxInode()
        var fileRows = 0
        var dirRows = 0
        var unverified: Set<String> = []

        for payload in payloads {
            let profile = BackupRowProfile.forDomain(payload.domain)
            if !profile.verified { unverified.insert(payload.domain) }
            let fileException = profile.fileExceptionPublisher
                .map { buildDataprotectionExtendedAttributes(publisher: $0) }
            // 只读一次。磁盘上的载荷是个映射文件，写出、算大小、算摘要
            // 都得是同一次读——视频壁纸读三遍就是把几百 MB 过三遍。
            let bytes = try payload.bytes()

            var rows: [(path: String, flags: Int32)] = [("", 2)]
            var accumulated = ""
            for component in payload.relativePath.split(separator: "/").dropLast() {
                accumulated = accumulated.isEmpty ? String(component) : "\(accumulated)/\(component)"
                rows.append((accumulated, 2))
            }
            rows.append((payload.relativePath, 1))

            for row in rows {
                if row.flags == 2 && preservedDirectories.contains(payload.domain + "/" + row.path) { continue }
                let isFile = row.flags == 1
                let isRoot = row.path.isEmpty
                let rowID = ManifestStore.fileID(domain: payload.domain, relativePath: row.path)
                if isFile {
                    let payloadURL = store.payloadURL(forFileID: rowID)
                    try fm.createDirectory(at: payloadURL.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try bytes.write(to: payloadURL)
                    fileRows += 1
                } else {
                    dirRows += 1
                }

                if isFile, let native = preservedFileMetadata[payload.domain + "/" + row.path] {
                    let blob = try patchMBFileContents(native, contents: bytes)
                    try store.upsert(fileID: rowID, domain: payload.domain,
                                     relativePath: row.path, flags: row.flags, blob: blob)
                    continue
                }

                nextInode += 1
                let blob = buildMBFileBlob(
                    relativePath: row.path,
                    mode: isFile
                        ? (Int(MODE_FILE_DEFAULT) | Int(S_IFREG))
                        : (Int(MODE_DIR_DEFAULT) | Int(S_IFDIR)),
                    size: isFile ? bytes.count : 0,
                    userID: isFile ? (payload.owner ?? profile.fileOwner) : (isRoot ? profile.rootOwner : profile.dirOwner),
                    groupID: isFile ? (payload.owner ?? profile.fileGroup) : (isRoot ? profile.rootGroup : profile.dirGroup),
                    protectionClass: isFile
                        ? profile.fileProtectionClass
                        : (isRoot ? profile.rootProtectionClass : profile.dirProtectionClass),
                    inodeNumber: nextInode,
                    timestamp: now,
                    // 这些 domain 的文件行是带摘要的那一类，值就是上面
                    // 刚写下去的字节的 SHA-1——见 `MBFileArchiver.digest` /
                    // `BackupRowProfile.carriesDigest`。目录行在设备上
                    // 永远不带摘要。
                    digest: isFile && profile.carriesDigest ? payloadDigest(bytes) : nil,
                    // 只有文件行带这个例外，按 `BackupRowProfile` 背后的
                    // 实测（已经在交付的那两类也是这么做的）。
                    extendedAttributes: isFile ? fileException : nil)
                try store.upsert(fileID: rowID, domain: payload.domain,
                                 relativePath: row.path, flags: row.flags, blob: blob)
            }
        }

        return Report(files: fileRows, dirRows: dirRows,
                      unverifiedDomains: unverified.sorted())
    }

    /// 完整流程的第 2+3 段：补齐宿主的元数据，把设备的清单剪到
    /// 磁盘上实际有的东西，再注入这次要送的。
    ///
    /// 注入放在剪裁*后面*，只有一个原因：剪裁只留 keep 集里的行，
    /// 而这次要送的行不在里面——先写行再剪裁，剪裁时会顺手删掉。
    /// - Parameter prune: 传 `false` 就是建一份备份而不是剪一份。
    ///   Partial Restore 没有设备内容要保护：备份是宿主的清单加上这次
    ///   的行和载荷合成的，没什么可对着文件系统核对，`pruneToDiskState`
    ///   只会去走一个空的载荷库。
    static func pruneAndInject(
        backupRoot: URL,
        udid: String,
        pairingPath: String,
        payloads: [BackupPayload],
        posterBoardSnapshot: URL? = nil,
        prune: Bool = true,
        ios27: Bool = true,
        log: @escaping BackupLog = { _ in }
    ) async throws {
        let deviceDir = backupRoot.appendingPathComponent(udid, isDirectory: true)
        let store = ManifestStore(deviceDir: deviceDir, log: log)

        // 退路：如果设备没上传宿主的备份元数据（Info.plist /
        // Status.plist / Manifest.plist），写一份最小可用的——
        // 还原缺了它们会拒绝。
        log("正在补齐宿主的清单文件…")

        // AppDomain-* 的文件行自己说不清自己。mobilebackup2 会把后缀
        // 当成一个已装应用，`Manifest.plist` 的 `Applications` 里没有
        // 那个应用就以 MBErrorDomain/205（"Unknown domain name in file
        // record"）拒绝还原。PosterBoard 是这条移植里第一个真正用
        // AppDomain-* 的生产载荷。
        //
        // 应用条目走 Rust FFI（`al_backup_app_factory_entry`，经
        // installation_proxy 取设备的原始记录），不再经过 Minimuxer。
        let appDomainPrefix = "AppDomain-"
        let appBundleIDs = Set(payloads.compactMap { payload -> String? in
            guard payload.domain.hasPrefix(appDomainPrefix) else { return nil }
            let bundleID = String(payload.domain.dropFirst(appDomainPrefix.count))
            return bundleID.isEmpty ? nil : bundleID
        }).sorted()

        var applications: [String: [String: Any]]?
        if !appBundleIDs.isEmpty {
            var records: [String: [String: Any]] = [:]
            for bundleID in appBundleIDs {
                let entry = try await BackupFFI.appFactoryEntry(pairingPath: pairingPath,
                                                                 bundleID: bundleID, log: log)
                records[bundleID] = entry
                log("已在还原里注册 AppDomain \(bundleID)"
                    + "（设备的原始记录里有 \(entry.keys.count) 个字段）")
            }
            applications = records
        }

        try HostManifests.ensure(deviceDir: deviceDir, udid: udid, ios27: ios27,
                                 applications: applications)
        log("宿主的清单文件已就绪")

        if !ios27 {
            // iOS 26 走老 MBDB 清单（`Manifest.mbdb`，载荷平铺）。
            // 本版没移植那条路：目标机是 iOS 27（27.0.1 / 27.2），
            // MBDB 那份（`MBDBManifest.swift`）不在移植范围内。
            throw BackupError("iOS 26 的老格式备份（MBDB）本版不支持，只支持 iOS 27 及以上的 sqlite 清单。")
        }

        if prune {
            log("正在剪裁 Manifest.db…")
            // keep 集：只留这次要送的 domain 和 PosterBoard 自己的行。
            // 原版在这里用的是 GoldenNugget 保护性备份的 keep 集
            // （只留它那几个系统 domain）；我们这边只备 PosterBoard
            // 一个容器，那套规则不适用——留 PosterBoard 和载荷的
            // domain，别的行（Rust 筛掉的文件留下的空行）都删掉。
            let keepDomains = Set(payloads.map(\.domain)).union([PosterBoard.domain])
            store.pruneToDiskState { domain, _ in keepDomains.contains(domain) }
            log("Manifest.db 剪裁完成")
        } else {
            log("Partial Restore：正在合成备份，没什么可剪的。")
        }

        let preservedDirectories: Set<String>
        let preservedFileMetadata: [String: Data]
        if let posterBoardSnapshot {
            // 只从快照里导这次的增量。容器的其余部分按设备手里的样子
            // 原样不动：那些文件本来就在设备上，再导一遍只会把 live
            // 商店的整棵树交给还原代理重建。原生记录还是会跟着来当供体——
            // 这就是同路径替换（数据库、刷新偏好）能盖着设备自己的
            // 元数据章的原因。
            let delivering = Set(payloads.map { $0.domain + "/" + $0.relativePath })
            let snapshot = try PosterBoardSnapshot.merge(from: posterBoardSnapshot, into: deviceDir,
                                                        delivering: delivering)
            preservedDirectories = snapshot.directories
            preservedFileMetadata = snapshot.fileMetadata
            log("PosterBoard：原生清单已恢复——\(preservedDirectories.count) 条目录记录，"
                + "\(snapshot.delivered) 个快照文件带过来了；容器的其余文件"
                + "按设备手里的样子不动")
        } else { preservedDirectories = []; preservedFileMetadata = [:] }

        log("正在注入 \(payloads.count) 个文件…")
        let report = try inject(into: deviceDir, payloads: payloads,
                                preservedDirectories: preservedDirectories,
                                preservedFileMetadata: preservedFileMetadata, log: log)
        log("文件已注入：\(report.summary)")
        for domain in report.unverifiedDomains {
            log("注意：\(domain) 的行形状是按设备自己的备份量出来的，但还没跑通过一次还原")
        }
    }
}
