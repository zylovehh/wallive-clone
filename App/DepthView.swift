// DepthView.swift
// 管理页：刷入记录管理（按回执删）+ 进群入口。
// 深景包制作流程已按用户要求从本页拿掉（生成/分享/设为当前包/安装）。

import Foundation
import SwiftUI

/// 液态透明按钮样式：iOS 26+ 用透明系统玻璃，低版本回退半透明白胶囊。
private struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            // #02：玻璃胶囊是透明的，字色不写死就是系统默认色，浅色模式下黑字
            // 在黑底上看不见（QQ 群“加入 QQ 群”按钮就是这么糊住的）。写死白字。
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background {
                if #available(iOS 26.0, *) {
                    Capsule().glassEffect(.clear)
                } else {
                    Capsule().fill(.white.opacity(0.06))
                }
            }
            // 点动特效：点下缩一点、松开弹簧弹回，跟底部 dock 栏的点动一样。
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: configuration.isPressed)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

struct DepthView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                // 刷入记录（Drift 同款入口）：管理页里看装过哪些、按回执删。
                VStack(alignment: .leading, spacing: 8) {
                    Text("刷入记录").font(.headline)
                    NavigationLink {
                        ReceiptManageView()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.title3).foregroundStyle(.blue)
                            Text("管理刷入的壁纸").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                // QQ 群：收成一条细的——左边渐变文字、右边加入按钮，点哪边都进群领视频教程。
                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=153226955&card_type=group&source=qrcode") {
                            openURL(url)
                        }
                    } label: {
                        TimelineView(.animation) { timeline in
                            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                            Text("进群领取视频教程")
                                .font(.subheadline.weight(.light))
                                .foregroundStyle(
                                    // 无缝循环渐变：色序首尾是同一个青色、渐变正好跨一个字宽，
                                    // phase 从 1 回到 0 时颜色完全接上，没有跳变；色阶排密一点，过渡更柔。
                                    LinearGradient(
                                        colors: [.cyan, .teal, .blue, .indigo, .purple, .pink, .red, .orange, .yellow, .green, .cyan],
                                        startPoint: UnitPoint(x: phase, y: 0.5),
                                        endPoint: UnitPoint(x: phase + 1, y: 0.5)
                                    )
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("加入 QQ 群") {
                        if let url = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=153226955&card_type=group&source=qrcode") {
                            openURL(url)
                        }
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 1))
            }
            .padding()
            .background(AppBackgroundView())
            .navigationTitle("管理")
        }
    }
}

// MARK: - 商店实时枚举（V1.44，Drift 同款）

/// 手写左滑删除（ScrollView 里系统 swipeActions 不生效）：
/// 往左拖露出红色删除键，滑过一半就停住，点删除弹确认；松手不到一半弹回去。
private struct SwipeToDelete<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var offset: CGFloat = 0
    @State private var revealed = false
    private let deleteWidth: CGFloat = 84

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                onDelete()
                revealed = false
                withAnimation(.spring()) { offset = 0 }
            } label: {
                Text("删除")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: deleteWidth - 4)
                    .frame(maxHeight: .infinity)
            }
            .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
            .opacity(offset < -8 ? 1 : 0)
            content()
                .offset(x: offset)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 24)
                        .onChanged { v in
                            let base: CGFloat = revealed ? -deleteWidth : 0
                            offset = min(0, max(-deleteWidth, base + v.translation.width))
                        }
                        .onEnded { _ in
                            revealed = offset < -deleteWidth / 2
                            withAnimation(.spring()) { offset = revealed ? -deleteWidth : 0 }
                        }
                )
        }
    }
}

/// 实时扫出来的一个在册描述符（Drift 同款口径）：不管是谁刷的、
/// 有没有回执，商店里在册就列出来。回执对上的把包名带上。
private struct LiveDescriptor: Identifiable {
    let uuid: String
    let extensionID: String
    let structureVersion: String
    let fullPath: String
    /// 文件创建时间：分「系统同期」和「后来装的」用（按时间推断，不是官方标记）。
    var creationDate: Date?
    /// 回执账本里对得上的那条（可能没有）。
    var receipt: InstallReceipt?
    var id: String { fullPath }

    /// 用户能看懂的名字：回执有包名用包名；没有按扩展叫。
    var displayName: String {
        if let pkg = receipt?.packageName { return pkg }
        switch extensionID {
        case PosterBoard.collectionsExtension: return "合集壁纸（未记账）"
        case PosterBoard.mercuryExtension: return "Mercury 海报（未记账）"
        case PosterBoard.photosExtension: return "照片海报（未记账）"
        default: return "\(extensionID)（未记账）"
        }
    }
}

/// 实时扫商店 + 按实时路径删（Drift 同款，V1.44 抄）。
/// 老办法按回执里记的路径删：商店换代、描述符一搬家，老路径就作废了，
/// 结果是「说删了其实还在」。Drift 的做法是每次管理页都现场扫商店，
/// 删除也按扫到的当前路径来——路径永远是最新的，不存在删空。
private enum ManagedWallpaperStore {
    /// 扫商店全部版本/扩展下的 descriptors 目录。只读逃逸。
    /// 成功返回 (名单, nil)；定位不到容器或拿不到通行证返回 (nil, 给用户看的一句原因)。
    static func scan(log: @escaping (String) -> Void)
        -> (entries: [LiveDescriptor]?, failNote: String?) {
        let fm = FileManager.default
        guard let container = RestoreTest.containerForLiveScan() else {
            return (nil, "定位不到壁纸库容器，没法实时扫商店，先按账本显示。")
        }
        // 对容器整体吃只读扩展：进得去商店目录，才能翻 descriptors。
        let escape = WorseQueryEscape.consume(target: container, requireWrite: false, log: log)
        guard let handle = escape.handle else {
            return (nil, "翻商店没拿到通行证（\(escape.failReason ?? "原因见日志")），先按账本显示。")
        }
        defer { WorseQueryEscape.release(handle) }
        let storeRoot = container + PosterBoard.storeRoot
        let receipts = InstallReceiptStore.receipts()
        var entries: [LiveDescriptor] = []
        // 版本目录（61、62……）挨个翻；每个版本下再翻 Extensions。
        let versionDirs = ((try? fm.contentsOfDirectory(atPath: storeRoot)) ?? []).sorted()
        for v in versionDirs {
            let extRoot = storeRoot + "/" + v + "/Extensions"
            let exts = ((try? fm.contentsOfDirectory(atPath: extRoot)) ?? []).sorted()
            for ext in exts {
                let descRoot = extRoot + "/" + ext + "/descriptors"
                let descs = ((try? fm.contentsOfDirectory(atPath: descRoot)) ?? []).sorted()
                for d in descs {
                    let full = descRoot + "/" + d
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
                    // 回执优先按「UUID + 路径都对上」记；路径对不上（描述符搬过家）
                    // 也算同一条账，包名照样带上——删除按实时路径来，不受影响。
                    let receipt = receipts.first { $0.descriptorUUID == d && $0.targetPath == full }
                        ?? receipts.first { $0.descriptorUUID == d }
                    // 文件创建时间：分档用；拿不到就空着，条目进「没对上账」档。
                    let created = try? fm.attributesOfItem(atPath: full)[.creationDate] as? Date
                    entries.append(LiveDescriptor(uuid: d, extensionID: ext,
                                                  structureVersion: v, fullPath: full,
                                                  creationDate: created,
                                                  receipt: receipt))
                }
            }
        }
        log("实时扫商店：\(versionDirs.count) 个版本目录，扫到 \(entries.count) 个在册描述符。")
        return (entries, nil)
    }

    /// 按实时路径删一个在册描述符。三道保险照 deleteByReceipt 的规矩：
    /// 路径必须在商店目录里且以 descriptors/<UUID> 收尾；逃逸拿到写通行证
    /// 才动手；删完重新枚举，真不在了才算数。回执对上的顺手清账。
    static func deleteLive(_ entry: LiveDescriptor,
                           log: @escaping (String) -> Void = { InstallLog.shared.append($0) }
    ) -> (message: String, removed: Bool) {
        let fm = FileManager.default
        // 保险一：路径必须是当前商店里的这个描述符。
        guard entry.fullPath.contains("PRBPosterExtensionDataStore/"),
              entry.fullPath.hasSuffix("/descriptors/\(entry.uuid)") else {
            log("实时删除：路径不在商店目录里，拒绝删除。")
            return ("路径不在商店目录里，拒绝删除。", false)
        }
        // 保险二：逃逸拿写通行证（对描述符的父目录，和按回执删一个路数）。
        let parent = (entry.fullPath as NSString).deletingLastPathComponent
        let escape = WorseQueryEscape.consume(target: parent, log: { log($0) })
        guard let escapeHandle = escape.handle else {
            return ("删除没成：沙箱逃逸没成（\(escape.failReason ?? "原因见日志")）。", false)
        }
        defer { WorseQueryEscape.release(escapeHandle) }
        // 本来就不在了：可能刚才已删过。清掉回执，如实记账。
        guard fm.fileExists(atPath: entry.fullPath) else {
            if let r = entry.receipt { InstallReceiptStore.removeAll(descriptorUUID: r.descriptorUUID) }
            log("实时删除：目录已经不在商店里，回执记录已清理。")
            return ("目录已经不在商店里（可能刚才删过），账本记录已顺手清理。", true)
        }
        do {
            try fm.removeItem(atPath: entry.fullPath)
        } catch {
            log("实时删除：删除没成（\(error.localizedDescription)）。")
            return ("删除没成：\(error.localizedDescription)。再试一次，还不行看安装日志。", false)
        }
        // 保险三：删完重新枚举，删干净了才算数。
        if fm.fileExists(atPath: entry.fullPath) {
            log("实时删除：删除后仍然能看到这个目录，没有确认删除。")
            return ("删除后仍然能看到这个目录，没有确认删除。再试一次，还不行看安装日志。", false)
        }
        if let r = entry.receipt { InstallReceiptStore.removeAll(descriptorUUID: r.descriptorUUID) }
        log("实时删除：已删除并在本机核验，\(entry.uuid) 的描述符已不在商店里。")
        return ("已删除并在本机核验：这张壁纸已不在商店里。上滑关掉海报应用（或刷新桌面）后生效。", true)
    }
}

/// 管理刷入的壁纸（Drift 同款页，V1.44 起）：列表不再来自回执账本，
/// 而是每次进来实时扫本机商店（逃逸只读翻 PRBPosterExtensionDataStore
/// 全部版本/扩展的 descriptors），在册就列，不管是谁刷的、有没有回执；
/// 删除也按扫到的当前路径来，回执对上的删完顺手清账。实时扫没成
///（定位不到容器/拿不到通行证）时降级按账本显示，跟老版一样。
private struct ReceiptManageView: View {
    @State private var liveEntries: [LiveDescriptor]?
    @State private var receipts: [InstallReceipt] = []
    @State private var scanNote = ""
    @State private var deleteBusy = false
    @State private var resultNote = ""
    @State private var deleteTarget: LiveDescriptor?
    @State private var showClearConfirm = false
    @State private var detailEntry: LiveDescriptor?
    @State private var resultOK: Bool?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if liveEntries == nil {
                    if deleteBusy {
                        ProgressView("翻商店里…")
                    } else {
                        // 实时扫没成：降级按账本显示，跟老版一样能按回执删。
                        if !scanNote.isEmpty {
                            Text(scanNote).font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if receipts.isEmpty {
                            Text("实时扫没成，账本里也没有记录。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(receipts, id: \.targetPath) { receipt in
                            fallbackEntry(receipt)
                        }
                    }
                } else if let entries = liveEntries {
                    if entries.isEmpty {
                        Text("商店里现在没有在册的壁纸描述符。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // 三档：自己装的（账本对上）／别的工具装的（没对账、比系统晚）／
                    // 大概率是系统的（没对账、跟最早一批同期）。线是按写入时间划的，推断。
                    let groups = Self.grouped(entries)
                    // 计数先拆成本地常量，避免编译器把整段表达式当一类推导（会超时）。
                    let ownCount = groups.own.count
                    let thirdPartyCount = groups.thirdParty.count
                    let systemishCount = groups.systemish.count
                    if !groups.own.isEmpty {
                        sectionHeader("自己装的（\(ownCount)）",
                                      note: nil, color: .green)
                        ForEach(groups.own) { entry in
                            liveRow(entry)
                        }
                    }
                    if !groups.thirdParty.isEmpty {
                        sectionHeader("别的工具装的（\(thirdPartyCount)）",
                                      note: "多半是第三方或旧版本，想清就删", color: .orange)
                        ForEach(groups.thirdParty) { entry in
                            liveRow(entry)
                        }
                    }
                    if !groups.systemish.isEmpty {
                        sectionHeader("大概率是系统的（\(systemishCount)）",
                                      note: "跟系统最早一批同一时期，建议别动", color: .blue)
                        ForEach(groups.systemish) { entry in
                            liveRow(entry)
                        }
                    }
                }
                if liveEntries != nil && !scanNote.isEmpty {
                    Text(scanNote).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !resultNote.isEmpty {
                    // 删除结果提示做成醒目的一块：成了绿色、没成红色，一眼看到。
                    Text(resultNote).font(.caption.weight(.semibold))
                        .foregroundStyle(resultOK == true ? .green : (resultOK == false ? .red : .primary))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke((resultOK == true ? Color.green : Color.red).opacity(0.6), lineWidth: 1))
                }
                HStack {
                    Button("重新扫一遍") { scan(forceReload: true) }
                        .buttonStyle(.bordered)
                        .disabled(deleteBusy)
                    Button("清空记录", role: .destructive) { showClearConfirm = true }
                        .buttonStyle(.bordered)
                }
                Text("列表是实时扫出来的：自己装的=账本对上；剩下两条按写入时间划线（跟最早一批同期算系统，更晚算第三方），是推断不是官方标记。所有条目左滑删除、点开看完整信息，删除按当前路径删，删完重新数一遍，删干净才算数。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("管理刷入的壁纸")
        .onAppear { scan(forceReload: false) }
        .refreshable { scan(forceReload: true) }
        .sheet(item: $detailEntry) { entry in
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.displayName).font(.headline)
                Text("UUID：\(entry.uuid)").font(.caption).textSelection(.enabled)
                Text("扩展：\(entry.extensionID) · 版本 \(entry.structureVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                if let t = entry.creationDate {
                    Text("写入时间：\(Self.timeFormatter.string(from: t))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(entry.receipt != nil
                     ? "账本：\(entry.receipt?.method == "pairing" ? "配对隧道" : "本机直刷")"
                     : "账本里没有这条的记录")
                    .font(.caption).foregroundStyle(.secondary)
                Text("路径：\(entry.fullPath)").font(.caption2).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .presentationDetents([.medium])
        }
        .confirmationDialog(
            deleteTarget.map { "删除「\($0.displayName)」？" } ?? "删除壁纸？",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let entry = deleteTarget { delete(entry) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("只删这一个描述符，系统自带的不碰。删完重新数一遍，删干净才算数。")
        }
        .alert("清空记录？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                InstallReceiptStore.clearAll()
                receipts = []
                scanNote = "账本记录清了；设备上的壁纸不动，列表以实时扫商店为准。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清装壁纸落的那张账，设备上的壁纸不动。")
        }
    }

    /// 实时扫商店。首次进来直接扫；forceReload 时先清空旧列表再扫。
    /// 扫不成降级：显示账本记录，跟老版一样能按回执删（走 RestoreTest.deleteByReceipt）。
    private func scan(forceReload: Bool) {
        scanNote = ""
        if forceReload { liveEntries = nil }
        guard liveEntries == nil else { return }
        receipts = Array(InstallReceiptStore.receipts().reversed())
        deleteBusy = true
        Task {
            let (entries, failNote) = await Task.detached(priority: .userInitiated) {
                ManagedWallpaperStore.scan(log: { InstallLog.shared.append($0) })
            }.value
            if let entries {
                liveEntries = entries
            } else {
                scanNote = failNote ?? "实时扫商店没成，先按账本显示。"
            }
            deleteBusy = false
        }
    }

    // 三档分组：账本对上=自己装的；没对上的按文件创建时间划线——
    // 跟商店里最早一批差三天以内算「大概率是系统的」，更晚的算「别的工具装的」。
    // 时间是推断依据不是官方标记；拿不到时间的进「别的工具装的」。
    private static func grouped(_ entries: [LiveDescriptor])
        -> (own: [LiveDescriptor], thirdParty: [LiveDescriptor], systemish: [LiveDescriptor]) {
        let own = entries.filter { $0.receipt != nil }
        let unmatched = entries.filter { $0.receipt == nil }
        let baseline = unmatched.compactMap(\.creationDate).min()
        let window: TimeInterval = 3 * 24 * 3600
        var thirdParty: [LiveDescriptor] = []
        var systemish: [LiveDescriptor] = []
        for entry in unmatched {
            if let t = entry.creationDate, let base = baseline, t <= base + window {
                systemish.append(entry)
            } else {
                thirdParty.append(entry)
            }
        }
        return (own, thirdParty, systemish)
    }

    private func sectionHeader(_ title: String, note: String?, color: Color) -> some View {
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(color)
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// 紧凑一行：名字 + UUID 前 8 位 · 版本，右侧时间；左滑删除，点开看完整信息。
    /// （ScrollView 里 SwiftUI 自带的 swipeActions 不生效，这里用手写的左滑。）
    private func liveRow(_ entry: LiveDescriptor) -> some View {
        SwipeToDelete(onDelete: { deleteTarget = entry }) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(String(entry.uuid.prefix(8)))… · 版本 \(entry.structureVersion)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let t = entry.creationDate {
                    Text(Self.shortTime.string(from: t))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { detailEntry = entry }
        }
    }

    private static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private func delete(_ entry: LiveDescriptor) {
        deleteBusy = true
        resultNote = ""
        resultOK = nil
        // 删完自动刷新（有配对文件才做）：跟装后同一套——27.2 重启桌面、
        // 以下杀 PosterBoard；没配对提示手动上滑。都在后台线程跑。
        let pairingPath = hasPairing ? Self.pairingFilePath : ""
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                let del = ManagedWallpaperStore.deleteLive(entry)
                guard del.removed else { return (false, del.message) }
                var note = del.message
                if !pairingPath.isEmpty {
                    // 有配对就自动刷新：原话里的「上滑关掉海报应用」被刷新
                    // 结论取代，避免自相矛盾。
                    note = note
                        .replacingOccurrences(of: "上滑关掉海报应用（或刷新桌面）后生效。", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    note += " " + RestoreTest.refreshAfterDelete(pairingPath: pairingPath)
                }
                return (true, note)
            }.value
            // 提示带上名字、分清成败，删完一眼就知道结果。
            resultOK = outcome.0
            resultNote = "「\(entry.displayName)」\(outcome.1)"
            if outcome.0 {
                // 删成了：重扫一遍，列表以商店为准；账本也刷新一次。
                receipts = Array(InstallReceiptStore.receipts().reversed())
                liveEntries = nil
                scan(forceReload: false)
            }
            deleteBusy = false
        }
    }

    /// 配对文件在不在（跟状态页同一处沙盒路径）。
    private var hasPairing: Bool {
        FileManager.default.fileExists(atPath: Self.pairingFilePath)
    }
    private static let pairingFilePath: String = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("wallive-pairing.plist").path

    // 账本降级视图：实时扫没成时按老版显示（照旧能按回执删）。
    private func fallbackEntry(_ receipt: InstallReceipt) -> some View {
        let isPairing = receipt.method == "pairing"
        return VStack(alignment: .leading, spacing: 4) {
            Text(receipt.packageName ?? receipt.descriptorUUID)
                .font(.subheadline.weight(.semibold))
            if let build = receipt.buildNumber {
                Text("\(isPairing ? "配对隧道" : "本机直刷") · 构建 \(build)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("通道：\(isPairing ? "配对隧道" : "本机直刷")")
                .font(.caption).foregroundStyle(.secondary)
            Text(receipt.verified
                 ? "核验：已核验 · 文件 \(receipt.fileCount) 个"
                 : "核验：未确认显示")
                .font(.caption).foregroundStyle(.secondary)
            if !isPairing {
                Text("生效：写入后关闭 PosterBoard")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(Self.timeFormatter.string(from: receipt.date))
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("删除", role: .destructive) {
                    legacyDelete(receipt)
                }
                .disabled(deleteBusy)
                if deleteBusy { ProgressView() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 1))
    }

    private func legacyDelete(_ receipt: InstallReceipt) {
        deleteBusy = true
        resultNote = ""
        resultOK = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                RestoreTest.deleteByReceipt(receipt)
            }.value
            // 同样带上名字、分清成败。
            resultOK = result.removed
            resultNote = "「\(receipt.packageName ?? receipt.descriptorUUID)」\(result.message)"
            receipts = Array(InstallReceiptStore.receipts().reversed())
            deleteBusy = false
        }
    }
}
