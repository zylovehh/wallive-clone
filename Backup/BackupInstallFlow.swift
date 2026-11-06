import Foundation

/// 备份模式的完整安装流程：包数据 + 配对文件 → 还原回去的壁纸。
///
/// 一条路走到底，中间任何一步失败就停，报错说清死在哪一步，
/// 不要继续往下走。成功返回后调用方要告诉用户重启手机——
/// 还原完必须重启一次，壁纸才会进图库（`RestoreRunner` 也不重启）。
///
/// 步骤（和 `backup-swift/REPORT.md` 的调用链一致）：
/// 1. 清掉旧的备份目录、备好取表目录（占位 Manifest.db，满备份）
/// 2. Rust 只备 PosterBoard 一个容器
/// 3. 从取回来的备份里取出商店数据库（WAL 合并进去）
/// 4. 解包、编还原包（描述符走 `configurations/<新 UUID>`，不是 `descriptors/`）
/// 5. 往商店数据库里加行（posterId 取 MAX+1）
/// 6. 清单剪裁 + 注入（数据库 + 0 字节 -wal/-shm 一起送）
/// 7. Rust 还原，验 `completed`
///
/// 只支持 iOS 27：占位 Manifest.db、sqlite 清单、WAL 商店全是 27 的
/// 形状；iOS 26 那路（MBDB）没移植，来了直接报错，不硬走。
enum BackupInstallFlow {

    /// 备份路装完的结果。`descriptorUUID` 是编包时新编的 UUID
    ///（`configurations/` 下那个），和包里原来的 UUID 不一样——
    /// 数据库行和文件用的都是这个新的，两边必须一致。
    struct Outcome {
        let descriptorUUID: String
        let extensionID: String
        let payloadCount: Int
        let storeSummary: String
        /// 备份路装完永远要重启手机。
        let needsReboot = true
    }

    static func install(packageData: Data,
                        zip: ZipEditing,
                        pairingPath: String,
                        deviceInfo: BackupFFI.DeviceInfo,
                        log: @escaping BackupLog = { _ in },
                        onProgress: ((String, Double) -> Void)? = nil) async throws -> Outcome {
        // 备份路只支持 iOS 27（占位 Manifest.db、sqlite 清单、WAL 商店
        // 全是 27 的形状）。版本号读不出来也按不支持处理，不猜。
        let major = deviceInfo.productVersion.split(separator: ".").first
            .flatMap { Int($0) }
        guard major == 27 else {
            throw BackupError("备份路只支持 iOS 27，这台设备是 iOS "
                + "\(deviceInfo.productVersion.isEmpty ? "未知版本" : deviceInfo.productVersion)"
                + "，走不了这条路。")
        }

        let fm = FileManager.default
        let backupRoot = fm.temporaryDirectory
            .appendingPathComponent("wallive-clone-backup-\(UUID().uuidString)")
        let workDir = backupRoot.appendingPathComponent("work")
        // 成功就清掉（里面有设备商店数据库的拷贝）；失败留着，日志里
        // 写清路径，方便排查。暂存目录（stage）按 AirLift 那路的规矩留着，
        // 系统自己清 tmp。
        var didFinish = false
        defer {
            // defer 在 return/throw 时都跑——成功才清，失败留着。
            if didFinish { try? fm.removeItem(at: backupRoot) }
        }

        do {
            // 1. 清掉上次的备份目录，重新备好取表目录。
            onProgress?("正在准备备份目录…", 0.05)
            log("备份目录：\(backupRoot.path)")
            try HostManifests.reset(backupRoot: backupRoot, udid: deviceInfo.udid)
            try PosterBoardBackup.prepareFetchDirectory(backupRoot: backupRoot,
                                                       udid: deviceInfo.udid, log: log)

            // 2. Rust 只备 PosterBoard 一个容器。
            onProgress?("正在取 PosterBoard 备份…", 0.10)
            let fetchStart = Date()
            var lastBytes: UInt64 = 0
            var lastTick = fetchStart
            let fetch = try await BackupFFI.fetchPosterBoard(
                pairingPath: pairingPath, backupRoot: backupRoot, log: log
            ) { detail in
                guard detail.percent >= 0 else { return }
                let now = Date()
                let elapsed = now.timeIntervalSince(fetchStart)
                let delta = detail.bytesDone >= lastBytes ? detail.bytesDone - lastBytes : 0
                let dt = now.timeIntervalSince(lastTick)
                let speed = dt > 0 ? Double(delta) / dt : 0
                lastBytes = detail.bytesDone
                lastTick = now
                let step = "正在取备份… \(detail.filesDone) 个文件 · \(byteText(detail.bytesDone)) · \(speedText(speed))"
                onProgress?(step, 0.10 + 0.35 * detail.percent / 100.0)
                log("取备份 \(Int(detail.percent))%：\(detail.filesDone) 个文件，\(byteText(detail.bytesDone))，\(speedText(speed))，已用 \(Int(elapsed)) 秒")
            }
            log("取回备份：留了 \(fetch.keptFiles) 个文件，筛掉 \(fetch.discardedFiles) 个")

            // 3. 从取回来的备份里取出商店数据库（WAL 合并进去）。
            onProgress?("正在取商店数据库…", 0.50)
            let storeDir = workDir.appendingPathComponent("store")
            let fetched = try PosterBoardBackup.extractStore(from: fetch.backupDir,
                                                             to: storeDir, log: log)
            log("商店数据库已取出（结构版本 \(fetched.structureVersion)，\(fetched.summary)）")

            // 4. 解包、编还原包。
            onProgress?("正在解包…", 0.58)
            let installer = DescriptorInstaller(zip: zip)
            let stage: URL
            do {
                (stage, _) = try installer.stage(packageData)
            } catch let error as TendiesPackage.Error {
                // TendiesPackage.Error 没带中文说明，这里按 case 翻译。
                switch error {
                case .notATendiesPackage:
                    throw BackupError("解包失败（第 4 步）：这不是一个 .tendies / .wallive 包。")
                case .missingWallpaperDirectory:
                    throw BackupError("解包失败（第 4 步）：包里找不到壁纸目录，结构不对。")
                case .missingWallpaperPlist:
                    throw BackupError("解包失败（第 4 步）：包里找不到 Wallpaper.plist，结构不对。")
                }
            } catch {
                throw BackupError("解包失败（第 4 步）：这个包打不开，\(error.localizedDescription)")
            }
            onProgress?("正在编还原包…", 0.64)
            let compiled = try PosterBoardCompiler.compile(
                stageDirectory: stage,
                structureVersion: fetched.structureVersion, log: log)
            guard !compiled.configs.isEmpty else {
                throw BackupError("包里没找到描述符（`descriptors/` 目录），编不出还原包。"
                    + "这个包可能是老格式，备份路只接现代格式的包。")
            }
            log("编包完成：\(compiled.payloads.count) 个载荷，\(compiled.configs.count) 张壁纸")

            // 5. 往商店数据库里加行（在拷贝上改，源文件不动）。
            onProgress?("正在往商店里加行…", 0.72)
            let stitchDir = workDir.appendingPathComponent("stitch")
            let staged = try PosterBoardStore.stitch(database: fetched.database,
                                                     items: compiled.configs,
                                                     workingDirectory: stitchDir)

            // 6. 清单剪裁 + 注入。数据库和 0 字节 -wal/-shm 一起送：
            // 只换主文件、留着旧 -wal，下次打开会把旧帧重放到新库上，
            // 商店直接报"database disk image is malformed"。
            onProgress?("正在把还原包写进清单…", 0.78)
            var payloads = compiled.payloads
            let storeRelativePath = PosterBoard.storePath(fetched.structureVersion)
                + "/" + PosterBoard.databaseFileName
            payloads.append(BackupPayload(domain: PosterBoard.domain,
                                          relativePath: storeRelativePath, source: staged))
            for suffix in ["-wal", "-shm"] {
                payloads.append(BackupPayload(domain: PosterBoard.domain,
                                              relativePath: storeRelativePath + suffix,
                                              contents: Data()))
            }
            try await BackupInjector.pruneAndInject(
                backupRoot: backupRoot, udid: deviceInfo.udid,
                pairingPath: pairingPath, payloads: payloads,
                posterBoardSnapshot: nil, prune: true, ios27: true, log: log)

            // 7. Rust 还原，验 completed。还原本体不重启。
            onProgress?("正在还原…", 0.86)
            try await RestoreRunner.runRestore(backupRoot: backupRoot,
                                               pairingPath: pairingPath, log: log)
            onProgress?("还原完成", 1.0)

            didFinish = true
            let first = compiled.configs[0]
            return Outcome(descriptorUUID: first.uuid,
                           extensionID: first.extensionID,
                           payloadCount: payloads.count,
                           storeSummary: fetched.summary)
        } catch let error as BackupError {
            // 已经是中文的步骤错误，原样抛，调用方直接显示。
            throw error
        } catch is CancellationError {
            // 用户点了停止：原样往上抛，别包成"备份安装失败"。
            throw CancellationError()
        } catch {
            // 非 BackupError 的错误（解包、文件读写等）没有中文说明，
            // 在这里补一句，免得用户只看到系统英文。
            throw BackupError("备份安装失败：\(error.localizedDescription)")
        }
    }

    /// 字节数写成 "12.3 MB" / "45 KB" / "900 字节"。
    private static func byteText(_ bytes: UInt64) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000.0) }
        if bytes >= 1_000 { return String(format: "%.0f KB", Double(bytes) / 1_000.0) }
        return "\(bytes) 字节"
    }

    /// 速度写成 "45 KB/s" / "1.2 MB/s"。
    private static func speedText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 { return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000.0) }
        if bytesPerSecond >= 1_000 { return String(format: "%.0f KB/s", bytesPerSecond / 1_000.0) }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}
