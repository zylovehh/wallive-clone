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
                // QQ 群：企鹅图标去掉，左边渐变文字、右边加入 QQ 群按钮（绿色去掉），两个挨在一起放中间，点哪边都进群领视频教程。
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            if let url = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=153226955&card_type=group&source=qrcode") {
                                openURL(url)
                            }
                        } label: {
                            TimelineView(.animation) { timeline in
                                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                                Text("进群领取视频教程")
                                    .font(.headline.weight(.light))
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
                        Button("加入 QQ 群") {
                            if let url = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=153226955&card_type=group&source=qrcode") {
                                openURL(url)
                            }
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
            }
            .padding()
            .background(AppBackgroundView())
            .navigationTitle("管理")
        }
    }
}

// MARK: - 商店实时枚举（V1.44，Drift 同款）

/// 实时扫出来的一个在册描述符（Drift 同款口径）：不管是谁刷的、
/// 有没有回执，商店里在册就列出来。回执对上的把包名带上。
private struct LiveDescriptor: Identifiable {
    let uuid: String
    let extensionID: String
    let structureVersion: String
    let fullPath: String
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
                    entries.append(LiveDescriptor(uuid: d, extensionID: ext,
                                                  structureVersion: v, fullPath: full,
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
                    ForEach(entries) { entry in
                        liveEntry(entry)
                    }
                }
                if liveEntries != nil && !scanNote.isEmpty {
                    Text(scanNote).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !resultNote.isEmpty {
                    Text(resultNote).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("重新扫一遍") { scan(forceReload: true) }
                        .buttonStyle(.bordered)
                        .disabled(deleteBusy)
                    Button("清空记录", role: .destructive) { showClearConfirm = true }
                        .buttonStyle(.bordered)
                }
                Text("列表是实时扫出来的：商店里在册就显示，装的时候是谁刷的不影响。删除按当前路径删，删完重新数一遍，删干净才算数。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("管理刷入的壁纸")
        .onAppear { scan(forceReload: false) }
        .refreshable { scan(forceReload: true) }
        .alert("删除这张壁纸？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } })) {
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

    private func liveEntry(_ entry: LiveDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.displayName)
                .font(.subheadline.weight(.semibold))
            Text("扩展：\(entry.extensionID) · 版本 \(entry.structureVersion)")
                .font(.caption).foregroundStyle(.secondary)
            if let r = entry.receipt {
                Text("账本：\(r.method == "pairing" ? "配对隧道" : "本机直刷") · \(Self.timeFormatter.string(from: r.date))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("账本里没有这条的记录")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("UUID：\(entry.uuid)")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("删除", role: .destructive) { deleteTarget = entry }
                    .disabled(deleteBusy)
                if deleteBusy { ProgressView() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 1))
    }

    private func delete(_ entry: LiveDescriptor) {
        deleteBusy = true
        resultNote = ""
        Task {
            // 删除走沙箱逃逸，是阻塞调用，放到后台线程跑。
            let result = await Task.detached(priority: .userInitiated) {
                ManagedWallpaperStore.deleteLive(entry)
            }.value
            resultNote = result.message
            if result.removed {
                // 删成了：重扫一遍，列表以商店为准；账本也刷新一次。
                receipts = Array(InstallReceiptStore.receipts().reversed())
                liveEntries = nil
                scan(forceReload: false)
            }
            deleteBusy = false
        }
    }

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
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                RestoreTest.deleteByReceipt(receipt)
            }.value
            resultNote = result.message
            receipts = Array(InstallReceiptStore.receipts().reversed())
            deleteBusy = false
        }
    }
}
