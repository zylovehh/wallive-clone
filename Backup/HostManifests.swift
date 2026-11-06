import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` 是 C 的宏，这个模块看不到它。它就是 `-1`：
/// 告诉 sqlite 把字节拷一份再存，不要留着指针——Swift 的字符串
/// 临时量在 bind 返回的那一刻就没了，留指针会悬空。
///
/// 转换目标是那个 typedef，所以这个常量自带 bind 函数声明里要的
/// 可选函数指针类型。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 宿主那边的三份备份元数据文件。
///
/// pymobiledevice3 在备份**之前**就预先建好它们：设备的第一条 DL
/// 消息就是要 `<udid>/Status.plist` 的 DownloadFiles 请求，缺了它
/// 备份立刻就断。还原时缺了它们也一样拒绝，所以两个流程在动
/// 别的之前都先调 `ensure`。
enum HostManifests {
    /// `Manifest.plist` 里的 `BackupKeyBag`，和参考实现硬编码的一字不差
    /// （`src/restore/backup.py:244`）。
    ///
    /// 它是 libimobiledevice 的备份钥匙包：`VERS` / `TYPE` / `UUID` /
    /// `HMCK` 开头，后面 16 条 `SALT` + `ITER` + `UUID` + `CLAS` +
    /// `WRAP` + `KTYP` + `WPKY`，解出来 1336 字节。它不带设备身份——
    /// 里面的 UUID 是钥匙包条目的标识，不是 UDID——所以同一份能服务
    /// 所有设备，参考实现硬编码它也是这个原因。
    ///
    /// 它的活是包住设备要求一个 `DataProtection: true` 的清单必须交代的
    /// 每个文件的数据保护密钥。漏了它，设备会把载荷全拉过去，
    /// 然后以 `MBErrorDomain/205 — No keybag in manifest` 拒绝还原。
    private static let backupKeyBag = Data(base64Encoded: Self.backupKeyBagBase64)!
    private static let backupKeyBagBase64 =
        """
        VkVSUwAAAAQAAAAFVFlQRQAAAAQAAAABVVVJRAAAABDud41d1b9NBICR1BH9JfVtSE1DSwAAACgA\
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAV1JBUAAAAAQAAAAAU0FMVAAA\
        ABRY5Ne2bthGQ5rf4O3gikep1e6tZUlURVIAAAAEAAAnEFVVSUQAAAAQB7R8awiGR9aba1UuVahG\
        PENMQVMAAAAEAAAAAVdSQVAAAAAEAAAAAktUWVAAAAAEAAAAAFdQS1kAAAAoN3kQAJloFg+ukEUY\
        +v5P+dhc/Welw/oucsyS40UBh67ZHef5ZMk9UVVVSUQAAAAQgd0cg0hSTgaxR3PVUbcEkUNMQVMA\
        AAAEAAAAAldSQVAAAAAEAAAAAktUWVAAAAAEAAAAAFdQS1kAAAAoMiQTXx0SJlyrGJzdKZQ+SfL1\
        24w+2Tf/3d1R2i9yNj9zZCHNJhnorVVVSUQAAAAQf7JFQiBOS12JDD7qwKNTSkNMQVMAAAAEAAAA\
        A1dSQVAAAAAEAAAAAktUWVAAAAAEAAAAAFdQS1kAAAAoSEelorROJA46ZUdwDHhMKiRguQyqHuko\
        trxhjIfqiZ5ESBXX9txi51VVSUQAAAAQfF0G/837QLq01xH9+66vx0NMQVMAAAAEAAAABFdSQVAA\
        AAAEAAAAAktUWVAAAAAEAAAAAFdQS1kAAAAol0BvFhd5bu4Hr75XqzNf4g0fMqZAie6OxI+x/pgm\
        6Y95XW17N+ZIDVVVSUQAAAAQimkT2dp1QeadMu1KhJKNTUNMQVMAAAAEAAAABVdSQVAAAAAEAAAA\
        A0tUWVAAAAAEAAAAAFdQS1kAAAAo2N2DZarQ6GPoWRgTiy/tdjKArOqTaH0tPSG9KLbIjGTOcLod\
        hx23xFVVSUQAAAAQQV37JVZHQFiKpoNiGmT6+ENMQVMAAAAEAAAABldSQVAAAAAEAAAAA0tUWVAA\
        AAAEAAAAAFdQS1kAAAAofe2QSvDC2cV7Etk4fSBbgqDx5ne/z1VHwmJ6NdVrTyWi80Sy869DM1VV\
        SUQAAAAQFzkdH+VgSOmTj3yEcfWmMUNMQVMAAAAEAAAAB1dSQVAAAAAEAAAAA0tUWVAAAAAEAAAA\
        AFdQS1kAAAAo7kLYPQ/DnHBERGpaz37eyntIX/XzovsS0mpHW3SoHvrb9RBgOB+WblVVSUQAAAAQ\
        EBpgKOz9Tni8F9kmSXd0sENMQVMAAAAEAAAACFdSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kA\
        AAAo5mxVoyNFgPMzphYhm1VG8Fhsin/xX+r6mCd9gByF5SxeolAIT/ICF1VVSUQAAAAQrfKB2uPS\
        QtWh82yx6w4BoUNMQVMAAAAEAAAACVdSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAo5iay\
        ZBwcRa1c1MMx7vh6lOYux3oDI/bdxFCW1WHCQR/Ub1MOv+QaYFVVSUQAAAAQiLXvK3qvQza/mea5\
        inss/0NMQVMAAAAEAAAACldSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAoD2wHX7KriEe1\
        E31z7SQ7/+AVymcpARMYnQgegtZD0Mq2U55uxwNr2FVVSUQAAAAQ/Q9feZxLS++qSe/a4emRRENM\
        QVMAAAAEAAAAC1dSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAocYda2jyYzzSKggRPw/qg\
        h6QPESlkZedgDUKpTr4ZZ8FDgd7YoALY1g==
        """

    /// `Status.plist` / `Manifest.plist` / `Info.plist`，缺哪个补哪个。
    ///
    /// 设备会上传 `Manifest.db`，但这三个它永远不上传——是宿主的责任。
    /// 内容按宿主能知道的填；目标应用由注入器事后加上。
    /// `isFullBackup` 是另一半，两个调用方确实想要的不一样：
    ///
    /// - 注入器是给*还原*合成一份备份，所以它是稀疏的：清单只列
    ///   这次要注的载荷，设备按那张表对账。这就是 `IsFullBackup: false`
    ///   的意思。
    /// - 保护性拉取要的是反面。设备往外流，宿主筛掉不要的，所以清单
    ///   不能把流约束在一张表上——表还没影。稀疏标记在这里是让设备
    ///   发"清单上写的东西"，也就是什么都没有，而这正是拉取要避免的
    ///   症状。
    ///
    /// 所以这是个参数，不是常量。写错了不会出声：传输跑完，什么都没动。
    ///
    /// - Parameter applications: `Applications` 下要列的应用记录，
    ///   设备就是靠它才上传那些应用的容器。`nil` 留一个空字典
    ///   （保护性备份要的就是"不上传任何应用容器"）；非 nil 一定会
    ///   重写 `Info.plist`，所以第二次用不同的应用表来调，
    ///   不会拿到第一次那个文件。
    static func ensure(deviceDir: URL,
                       udid: String,
                       ios27: Bool = true,
                       isFullBackup: Bool = false,
                       applications: [String: [String: Any]]? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: deviceDir, withIntermediateDirectories: true)

        // 版本分界是参考实现的：`Backup.manifest_ios27`
        // （`backup.py:113`），按 `restore.py:1065-1074` 从产品版本定。
        // iOS 26 讲老 MBDB 格式，Status 2.4 / Manifest 9.1+20.0；
        // iOS 27+ 用 sqlite Manifest.db，3.3 / 10.0+24.0。
        //
        // `IsFullBackup` 是稀疏标记，在这里最要紧：这份备份是从零建的，
        // 声明成"完整"就是告诉设备去对账一批从来没发过的内容。
        let statusURL = deviceDir.appendingPathComponent("Status.plist")
        if !fm.fileExists(atPath: statusURL.path) || isFullBackup {
            let status: [String: Any] = [
                "BackupState": "new",
                "Date": Date(),
                "IsFullBackup": isFullBackup,
                "Version": ios27 ? "3.3" : "2.4",
                "SnapshotState": "finished",
                "UUID": UUID().uuidString.uppercased(),
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: status,
                                                              format: .binary, options: 0) {
                try? data.write(to: statusURL)
            }
        }

        // Manifest.plist——下面的钥匙包不是可选项。AppDomain 的载荷
        // 还得在这里注册：没有匹配的 Applications 条目，mobilebackup2
        // 会以 MBErrorDomain/205 "Unknown domain name in file record"
        // 拒绝那个文件行。
        let manifestURL = deviceDir.appendingPathComponent("Manifest.plist")
        if !fm.fileExists(atPath: manifestURL.path) || applications != nil {
            var manifest: [String: Any]
            if fm.fileExists(atPath: manifestURL.path),
               let data = try? Data(contentsOf: manifestURL),
               let existing = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any] {
                manifest = existing
            } else {
                manifest = [
                    "DataProtection": true,
                    "BackupKeyBag": Self.backupKeyBag,
                    "Lockdown": [:],
                    "SystemDomainsVersion": ios27 ? "24.0" : "20.0",
                    "Version": ios27 ? "10.0" : "9.1",
                    "Applications": [:],
                ]
            }

            if let applications {
                // 还原注册用的是这个项目早期的应用容器 PoC 验证过的紧凑形状。
                // FactoryInfo 用的是完整的 installation_proxy 记录；
                // Manifest.plist 只要能让 AppDomain-<包名> 被 mobilebackup2
                // 认出来的应用身份/路径字段。
                var registered: [String: Any] = [:]
                for (bundleID, entry) in applications {
                    var app: [String: Any] = [
                        "CFBundleIdentifier": entry["CFBundleIdentifier"] as? String ?? bundleID,
                    ]
                    for key in ["CFBundleVersion", "Path", "ContainerContentClass"] {
                        if let value = entry[key] { app[key] = value }
                    }
                    registered[bundleID] = app
                }
                manifest["Applications"] = registered
            }

            try PropertyListSerialization.data(fromPropertyList: manifest,
                                               format: .xml, options: 0)
                .write(to: manifestURL)
        }

        // Info.plist——设备身份，以及决定设备上传哪些应用容器的
        // `Applications` 表。参考实现的 `init_mobile_backup_factory_info`
        // 在这里写同样的字典，还把它当消息的 `FactoryInfo` 发出去；
        // 两边都是调用方给的。
        let infoURL = deviceDir.appendingPathComponent("Info.plist")
        if !fm.fileExists(atPath: infoURL.path) || applications != nil {
            var info: [String: Any] = [
                "Unique Identifier": udid.uppercased(),
                "Target Type": "Device",
                "Target Identifier": udid,
                "Build Version": "",
                "Product Version": "",
                "Product Type": "",
                "Serial Number": "",
                "Applications": [:],
            ]
            if let applications, !applications.isEmpty {
                info["Applications"] = applications
                info["Installed Applications"] = applications.keys.sorted()
            }
            if let data = try? PropertyListSerialization.data(fromPropertyList: info,
                                                              format: .xml, options: 0) {
                try? data.write(to: infoURL)
            }
        }
    }

    /// sqlite 版 `Manifest.db`，是 iOS 27 向*宿主*要的东西。
    ///
    /// 上面三个 plist 是 iOS 26 上宿主方面的全部故事，写这段时也是
    /// 按 27 也一样来写的。它不是：27 上设备的第二条 DL 消息就是
    /// 要 `<udid>/Manifest.db` 的 DownloadFiles 请求，宿主交不出来
    /// 就会失败（Rust 日志里的 `not found (-6)`），在传出第一个载荷
    /// 之前就放弃传输。这就是保护性拉取 "0 个留了 0 个，3 秒" 那次
    /// 失败的全部原因——根本没东西可筛，因为什么都没发过。
    ///
    /// 结构和属性是 libimobiledevice 的，表故意留空：这是"以前什么
    /// 都没备过"的答案，所以设备发全量而不是对着一份不存在的备份
    /// 发增量。往这里填内容比报错更糟——设备会只发它在表里找到
    /// 的行然后停下。
    static func writeSQLiteManifest(deviceDir: URL, ios27: Bool) throws {
        guard ios27 else { return }
        let url = deviceDir.appendingPathComponent("Manifest.db")
        try? FileManager.default.removeItem(at: url)

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw BackupError("占位 Manifest.db 打不开：\(why)")
        }
        defer { sqlite3_close(db) }

        // SQLite 要在句柄消失前把页写进去，建了一半的清单比没有更糟：
        // 设备读了它会当真。
        guard sqlite3_exec(db, """
            PRAGMA journal_mode=DELETE;
            CREATE TABLE ManifestEntry (
                domain TEXT,
                relative_path TEXT,
                flags INTEGER,
                file BLOB
            );
            CREATE TABLE Properties (key TEXT PRIMARY KEY, value BLOB);
            """, nil, nil, nil) == SQLITE_OK else {
            throw BackupError("占位 Manifest.db 建表失败：\(String(cString: sqlite3_errmsg(db)))")
        }

        let properties: [(String, String)] = [
            ("Version", "3.3"),
            ("Date", String(Int(Date().timeIntervalSince1970))),
            ("SystemDomainsVersion", "24.0"),
            ("WasPasscodeSet", "false"),
        ]
        // C 函数返回状态，语句通过 out 参数交回来；没有那种直接把语句
        // 返回来的方便写法。
        var insert: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "INSERT INTO Properties (key, value) VALUES (?, ?)",
                                          -1, &insert, nil)
        guard prepared == SQLITE_OK, let insert else {
            throw BackupError("占位 Manifest.db 写属性失败：\(String(cString: sqlite3_errmsg(db)))")
        }
        for (key, value) in properties {
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            sqlite3_bind_text(insert, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insert, 2, value, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(insert) == SQLITE_DONE else {
                throw BackupError("占位 Manifest.db 写属性 \(key) 失败：\(String(cString: sqlite3_errmsg(db)))")
            }
        }

        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "VACUUM;", nil, nil, &err)
        sqlite3_free(err)
    }

    /// 清掉 `<backupRoot>/<udid>/`，重新播种宿主的清单文件。
    ///
    /// 路径用参数传，不用全局量。
    static func reset(backupRoot: URL, udid: String) throws {
        let deviceDir = backupRoot.appendingPathComponent(udid, isDirectory: true)
        try? FileManager.default.removeItem(at: deviceDir)
        try ensure(deviceDir: deviceDir, udid: udid)
    }
}
