import SwiftUI
import UIKit

/// 导出流程页：管理员门控 + 已装壁纸列表 + 逐条导出 + 系统分享。
/// 支持扫描容器里全部壁纸（不限本 App 安装记录）。
///
/// 命名口径（封面识别优先）：每行最前放封面缩略图，名称解析按
/// 「用户备注 → 目录表匹配（按描述符编号）→ providerInfo 名称 → 未识别」，
/// 环境类壁纸单独标「系统」。封面只用于识别，不影响导出包内容。
struct ExportFlowView: View {
    @EnvironmentObject private var state: AppState
    @State private var unlocked: Bool

    /// 状态页已通过管理员验证时直接进列表，不用再登一次；默认仍先过管理员验证。
    init(initiallyUnlocked: Bool = false) {
        _unlocked = State(initialValue: initiallyUnlocked)
    }
    @State private var scanning = false
    @State private var scannedBackupDir: URL?
    @State private var descriptors: [InstalledWallpaperExporter.DescriptorInfo] = []
    /// 直读扫到的描述符（scanStore 的结果）；导出时优先直读，不用备份。
    @State private var directEntries: [DirectStoreExporter.DirectDescriptor]?
    @State private var exportingUUID: String?
    @State private var exportedFileURL: URL?
    @State private var showShareSheet = false
    @State private var errorMessage: String?
    /// 用户备注：描述符 UUID → 名称，记在 UserDefaults，重启还在。
    @State private var notes: [String: String] = [:]
    @State private var editingUUID: String?
    @State private var editingText = ""
    @State private var showRename = false
    @StateObject private var catalog = CatalogStore()
    /// 本轮已拉过目录表的标志，防止重复拉取。
    @State private var catalogFetched = false
    /// 本地封面：描述符 UUID → 压好的小图（从包里挑图压成，系统自带的没有）。
    @State private var covers: [String: Data] = [:]
    /// 系统组默认收起来：那组全是系统自带的，平时不用看，点标题再展开。
    @State private var foldedSystem = true

    private static let notesKey = "win97-wallpaper-notes"

    var body: some View {
        Group {
            if unlocked {
                exportList
            } else {
                AdminLoginView {
                    // 仅验证通过后才进入列表，门控不能跳过。
                    unlocked = true
                }
            }
        }
        .navigationTitle("导出已装壁纸")
        .task(id: unlocked) {
            // 进列表后拉一次目录表：按描述符编号匹配封面和标题。
            guard unlocked, !catalogFetched else { return }
            catalogFetched = true
            loadNotes()
            await catalog.fetch()
        }
        .alert("重命名壁纸", isPresented: $showRename) {
            TextField("名称", text: $editingText)
            Button("保存") {
                guard let uuid = editingUUID else { return }
                setNote(editingText.isEmpty ? nil : editingText, for: uuid)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("留空并保存即清除手动命名。")
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportedFileURL {
                ActivityShareSheet(items: [url])
            }
        }
    }

    private var exportList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 扫描容器：备份一次，列出全部描述符，不只本 App 的安装记录。
                Button {
                    Task { await scan() }
                } label: {
                    Text(scanning ? "扫描中…" : (scannedBackupDir == nil ? "扫描容器里的壁纸" : "重新扫描"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(scanning || exportingUUID != nil)

                // 没配对时给出明确的下一步指引，别让用户卡在报错里。
                if !state.hasPairingFile {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("导出前需要配对记录：先去「回环 VPN」页确认 VPN 已连接，再到「配对记录」页点“生成配对文件”或导入一份。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        NavigationLink(destination: StatusPairingPage()) {
                            Text("去配对记录页").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                    .padding()
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                }

                if !state.installHistory.isEmpty && descriptors.isEmpty && scannedBackupDir == nil {
                    Text("共 \(state.installHistory.count) 条本 App 安装记录，点“导出”生成 .tendies 文件。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(state.installHistory, id: \.self) { uuid in
                        descriptorRow(InstalledWallpaperExporter.DescriptorInfo(
                            uuid: uuid, extensionID: nil, name: nil, isAmbient: false,
                            receiptPackageName: InstalledWallpaperExporter.DescriptorInfo.receiptNameByUUID()[uuid]), isOwn: true)
                    }
                }

                if !descriptors.isEmpty {
                    Text("共扫到 \(descriptors.count) 个壁纸（含其他 App 装入容器的）。")
                        .font(.caption).foregroundStyle(.secondary)
                    // 两组：别的 App / 自己装的在前，系统自带的收进一组、默认折叠。
                    // 自己装的按回执和日期认（回执对上，或比系统最早一批晚三天以上），
                    // 不只看扩展名——自己装的 .tendies 也走系统扩展。
                    let baseline = Self.systemBaseline(in: descriptors)
                    let grouped = Self.grouped(descriptors)
                    let systemEntries = grouped.system
                    let otherEntries = grouped.other
                    ForEach(otherEntries, id: \.uuid) { info in
                        descriptorRow(info, isOwn: Self.isOwnEntry(info, baseline: baseline))
                    }
                    if !systemEntries.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { foldedSystem.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Text("系统壁纸（\(systemEntries.count)）").font(.headline).foregroundStyle(.blue)
                                Text(foldedSystem ? "▶" : "▼").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        if !foldedSystem {
                            ForEach(systemEntries, id: \.uuid) { info in
                                descriptorRow(info, isOwn: false)
                            }
                        }
                    }
                }

                if let exportingUUID {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在导出 \(String(exportingUUID.prefix(8)))…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Text("命名优先级：你的备注 → 目录匹配（封面+标题）→ 系统自带名字 → 壁纸自带信息。封面只用于识别，不影响导出包内容。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
    }

    // MARK: - 行渲染（封面识别优先）

    private var placeholderThumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
        .frame(width: 60, height: 60)
    }

    @ViewBuilder
    private func thumbnail(for urlString: String?) -> some View {
        if let urlString, !urlString.isEmpty {
            // 目录封面和目录卡片走同一份带备用链的加载：主链拉不到换 raw 直链再试。
            CachedCoverImage(urlString: urlString)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            placeholderThumb
        }
    }

    /// 行封面：优先用刚从包里取的本地小图，没有再用目录表里的封面；
    /// 系统自带的没有本地封面、目录里也没有，走占位图（只有名字、没封面）。
    @ViewBuilder
    private func coverThumbnail(for info: InstalledWallpaperExporter.DescriptorInfo, resolved: ResolvedName) -> some View {
        if let data = covers[info.uuid], let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable().scaledToFill()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            thumbnail(for: resolved.thumbURL)
        }
    }

    /// 行渲染：封面在最前，名称按「备注 → 目录 → 回执 → 系统自带 → providerInfo → 未识别」解析。
    /// 自己装的（回执/日期新）不标系统、显示真名和导入时间。
    private func descriptorRow(_ info: InstalledWallpaperExporter.DescriptorInfo, isOwn: Bool) -> some View {
        let resolved = resolvedName(for: info.uuid, providerName: info.name, isAmbient: info.isAmbient, extensionID: info.extensionID,
                                    receiptName: info.receiptPackageName, isOwn: isOwn)
        return HStack(spacing: 10) {
            coverThumbnail(for: info, resolved: resolved)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(resolved.name)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if resolved.isSystem {
                        Text("系统")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.yellow.opacity(0.5), lineWidth: 1))
                    }
                    // 改名降为辅助操作：小铅笔入口。
                    Button {
                        editingUUID = info.uuid
                        editingText = notes[info.uuid] ?? ""
                        showRename = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("重命名")
                }
                Text(resolved.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(info.uuid)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let t = info.creationDate {
                    Text("导入时间：\(Self.shortTime.string(from: t))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            GlassIconButton(title: "导出", systemImage: "square.and.arrow.up") {
                Task { await export(uuid: info.uuid) }
            }
            .disabled(exportingUUID != nil)
        }
        .padding(.vertical, 4)
    }

    /// 导入时间：跟管理页同一格式（月-日 时:分）。
    private static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    // MARK: - 名称解析与备注

    private struct ResolvedName {
        let name: String
        let source: String
        let thumbURL: String?
        let isSystem: Bool
    }

    /// 系统自带扩展的人话名字：时钟 / 环境 / 照片 / 合集；不是系统的返回 nil。
    static func systemName(for extensionID: String?) -> String? {
        guard let ext = extensionID else { return nil }
        if ext.hasPrefix("com.apple.ClockPoster") { return "系统时钟海报" }
        if ext == PosterBoard.mercuryExtension { return "系统环境海报" }
        if ext == PosterBoard.photosExtension { return "系统照片海报" }
        if ext == PosterBoard.collectionsExtension { return "系统合集海报" }
        // 别的苹果自带扩展（天文、天气这类没单列名字的）：一律算系统壁纸，别再掉进“未识别”。
        if ext.hasPrefix("com.apple.") { return "系统壁纸" }
        return nil
    }

    /// 是不是系统自带的：扩展是系统扩展，或 providerInfo 标了环境类。
    /// 注意：只看扩展会错标——自己装的 .tendies 也走系统扩展（时钟/合集），
    /// 所以分组不用这个单条判断，改用下面的 isOwnEntry + baseline（回执/日期优先）。
    static func isSystemEntry(_ info: InstalledWallpaperExporter.DescriptorInfo) -> Bool {
        systemName(for: info.extensionID) != nil || info.isAmbient
    }

    /// 系统最早一批的基准日期：没回执的条目里最早的创建日期；没有日期返回 nil。
    /// 管理页同口径（三天窗口）。
    static func systemBaseline(in entries: [InstalledWallpaperExporter.DescriptorInfo]) -> Date? {
        entries.filter { $0.receiptPackageName == nil }.compactMap(\.creationDate).min()
    }

    /// 自己装的：回执对上，或没回执但日期比系统最早一批晚三天以上。
    /// 日期拿不到的按扩展名兜底（不算自己装的）。
    static func isOwnEntry(_ info: InstalledWallpaperExporter.DescriptorInfo, baseline: Date?) -> Bool {
        if info.receiptPackageName != nil { return true }
        if let t = info.creationDate, let base = baseline, t > base + 3 * 24 * 3600 {
            return true
        }
        return false
    }

    /// 两组：系统自带的收进一组默认折叠，其余（自己装的、别的工具装的）在前。
    /// 自己装的（回执/日期新）不进系统组，哪怕走了系统扩展。
    static func grouped(_ entries: [InstalledWallpaperExporter.DescriptorInfo])
        -> (system: [InstalledWallpaperExporter.DescriptorInfo], other: [InstalledWallpaperExporter.DescriptorInfo]) {
        let baseline = systemBaseline(in: entries)
        var system: [InstalledWallpaperExporter.DescriptorInfo] = []
        var other: [InstalledWallpaperExporter.DescriptorInfo] = []
        for e in entries {
            if isOwnEntry(e, baseline: baseline) {
                other.append(e)
            } else if systemName(for: e.extensionID) != nil || e.isAmbient {
                system.append(e)
            } else {
                other.append(e)
            }
        }
        return (system, other)
    }

    /// 名称解析：你的备注 → 目录表匹配（按描述符编号）→ 回执包名 → 系统自带名字 → providerInfo 名称 → 未识别。
    /// 回执对上的就是自己装的，显示真名、不标系统；没回执但日期新的也一样
    /// （isOwn），不标系统。系统名只给真正系统自带的。
    private func resolvedName(for uuid: String, providerName: String?, isAmbient: Bool, extensionID: String?,
                              receiptName: String?, isOwn: Bool) -> ResolvedName {
        let note = notes[uuid]
        let catalogItem = catalog.item(withUUID: uuid)
        if let note, !note.isEmpty {
            return ResolvedName(name: note, source: "你手动起的名字 · 目录未匹配",
                                thumbURL: catalogItem?.thumbnailURL, isSystem: false)
        }
        if let item = catalogItem {
            return ResolvedName(name: item.title, source: "目录匹配 · 封面已对应",
                                thumbURL: item.thumbnailURL, isSystem: false)
        }
        if let receiptName, !receiptName.isEmpty {
            return ResolvedName(name: receiptName, source: "本 App 装的 · 回执对上",
                                thumbURL: catalogItem?.thumbnailURL, isSystem: false)
        }
        if isOwn {
            if let providerName, !providerName.isEmpty {
                return ResolvedName(name: providerName, source: "来自壁纸自带信息",
                                    thumbURL: nil, isSystem: false)
            }
            return ResolvedName(name: "未识别壁纸", source: "暂无封面来源 · 可手动起名",
                                thumbURL: nil, isSystem: false)
        }
        if let system = Self.systemName(for: extensionID) {
            return ResolvedName(name: system, source: "系统自带壁纸",
                                thumbURL: nil, isSystem: true)
        }
        if isAmbient {
            return ResolvedName(name: "未识别 · 疑似系统壁纸", source: "环境类壁纸 · 容器中无独立媒体",
                                thumbURL: nil, isSystem: true)
        }
        if let providerName, !providerName.isEmpty {
            return ResolvedName(name: providerName, source: "来自壁纸自带信息", thumbURL: nil, isSystem: false)
        }
        return ResolvedName(name: "未识别壁纸", source: "暂无封面来源 · 可手动起名",
                            thumbURL: nil, isSystem: false)
    }

    private func loadNotes() {
        notes = UserDefaults.standard.dictionary(forKey: Self.notesKey) as? [String: String] ?? [:]
    }

    private func setNote(_ note: String?, for uuid: String) {
        var all = notes
        if let note, !note.isEmpty {
            all[uuid] = note
        } else {
            all.removeValue(forKey: uuid)
        }
        notes = all
        UserDefaults.standard.set(all, forKey: Self.notesKey)
    }

    // MARK: - 扫描与导出

    private func scan() async {
        guard state.hasPairingFile else {
            errorMessage = "还没导入配对记录，先去“配对记录”页导入。"
            return
        }
        scanning = true
        exportingUUID = nil
        errorMessage = nil
        // 优先直读商店（逃逸只读，27.0.1 备份 0 文件时的正路）；直读不成再退回备份兜底。
        let (live, directFailReason) = DirectStoreExporter.scanStore(
            log: { InstallLog.shared.append($0) })
        if let live = live, !live.isEmpty {
            directEntries = live
            scannedBackupDir = nil
            let receiptNames = InstalledWallpaperExporter.DescriptorInfo.receiptNameByUUID()
            descriptors = live.map {
                InstalledWallpaperExporter.DescriptorInfo(uuid: $0.uuid, extensionID: $0.extensionID, name: $0.name, isAmbient: $0.isAmbient,
                                                          receiptPackageName: receiptNames[$0.uuid], creationDate: $0.creationDate)
            }
            scanning = false
            // 封面后台取：逐条在后台读包里的图，读完一条显示一条，界面不卡；
            // 系统自带的跳过（只有名字、没封面）。自己装的就算走了系统扩展
            // 也要取封面（回执对上 / 日期新都算自己装的）。
            let receiptUUIDs = Set(receiptNames.keys)
            let baseline = live.filter { !receiptUUIDs.contains($0.uuid) }.compactMap(\.creationDate).min()
            let window: TimeInterval = 3 * 24 * 3600
            let isNew: (DirectStoreExporter.DirectDescriptor) -> Bool = { entry in
                guard let t = entry.creationDate, let base = baseline else { return false }
                return t > base + window
            }
            Task {
                for entry in live where !entry.isAmbient && (receiptUUIDs.contains(entry.uuid) || Self.systemName(for: entry.extensionID) == nil || isNew(entry)) {
                    let data = await Task.detached { DirectStoreExporter.coverData(for: entry) }.value
                    if let data {
                        await MainActor.run { covers[entry.uuid] = data }
                    }
                }
            }
            return
        }
        if let note = directFailReason {
            InstallLog.shared.append("直读导出不可用（\(note)），改走备份通道。")
        }
        do {
            let dir = try await InstalledWallpaperExporter.fetchBackup(
                pairingPath: state.pairingFileURL.path,
                log: { InstallLog.shared.append($0) })
            directEntries = nil
            scannedBackupDir = dir
            descriptors = try InstalledWallpaperExporter.listAllDescriptors(backupDir: dir)
        } catch {
            errorMessage = "扫描失败：\(error.localizedDescription)"
        }
        scanning = false
    }

    private func export(uuid: String) async {
        guard state.hasPairingFile else {
            errorMessage = "还没导入配对记录，先去“配对记录”页导入。"
            return
        }
        exportingUUID = uuid
        errorMessage = nil
        do {
            let result: InstalledWallpaperExporter.ExportResult
            if let entry = directEntries?.first(where: { $0.uuid == uuid }) {
                // 直读导出：直接读容器，不走备份。
                result = try DirectStoreExporter.exportDescriptor(
                    entry, log: { InstallLog.shared.append($0) })
            } else {
                let dir: URL
                if let cached = scannedBackupDir {
                    dir = cached
                } else {
                    dir = try await InstalledWallpaperExporter.fetchBackup(
                        pairingPath: state.pairingFileURL.path,
                        log: { InstallLog.shared.append($0) })
                    scannedBackupDir = dir
                }
                result = try InstalledWallpaperExporter.exportWallpaper(
                    descriptorUUID: uuid,
                    backupDir: dir,
                    log: { InstallLog.shared.append($0) })
            }
            let url = try Self.writeToExports(result: result)
            exportedFileURL = url
            showShareSheet = true
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
        exportingUUID = nil
    }

    /// 导出包写入沙盒 Documents/exports/，分享面板拿文件 URL。
    private static func writeToExports(result: InstalledWallpaperExporter.ExportResult) throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("exports", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(result.fileName)
        try result.data.write(to: url, options: .atomic)
        return url
    }
}

/// UIActivityViewController 的 SwiftUI 包装（分享 .tendies 文件用）。
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
