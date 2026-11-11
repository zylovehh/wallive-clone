// ImportView.swift
// V6 导入安装合并页：导入库 + 详情二级页，不再单独占安装页签。
// 导入库：导过的包都存下来排成卡片（封面、名字、大小、日期），点应用打开详情安装，
// 点垃圾桶删掉本机存的这份；底部是导入壁纸和获取更多壁纸。
// 详情：壁纸包信息、图层信息、深景状态、制作深景包、安装壁纸。
// 安装：装完不重启桌面、不闪屏、不黑屏；写盘返回成功不代表图库已列出，
// 诊断区显示逐目录结果、读回核对（HouseArrest 通道）、登记条数与进程刷新。

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

/// 液态透明胶囊：iOS 26+ 用透明系统玻璃，低版本回退半透明白。
private struct LiquidGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear, in: Capsule())
        } else {
            content.background(.white.opacity(0.06)).clipShape(Capsule())
        }
    }
}

private extension View {
    func glassCapsule() -> some View { modifier(LiquidGlassCapsule()) }
}

/// 点动特效：点下缩一点、松开弹簧弹回，跟底部 dock 栏的点动一样。
private struct PressBounceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

struct ImportView: View {
    @EnvironmentObject private var state: AppState
    @State private var showPicker = false
    @State private var message = ""
    @State private var showPairingPicker = false
    @State private var pairingMessage = ""
    @State private var clearing = false
    @State private var clearResult = ""
    @State private var showDetail = false
    @State private var pkgToDelete: ImportedPackage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // 26 系统用：配对文件下载/导入入口，只在 iOS 26 的手机上显示。
                        if isIOS26 {
                            pairingSection
                        }
                        if state.importedPackages.isEmpty {
                            Text("还没导入包。点下面“导入壁纸”选本地 .tendies / .wallive，没加密的包导入时会自动转成 WALLIVE1 加密版（只有本 App 能装），加密包会自动解密后再检查。导过的包都存在这一页，随时能看、随时能装。")
                                .foregroundStyle(.secondary).font(.caption)
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                                ForEach(state.importedPackages) { pkg in
                                    ImportedPackageCard(
                                        pkg: pkg,
                                        thumbURL: state.importedThumbURL(pkg),
                                        onApply: { applyPackage(pkg) },
                                        onDelete: { pkgToDelete = pkg }
                                    )
                                }
                            }
                        }
                        if !clearResult.isEmpty {
                            Text(clearResult).font(.caption)
                        }
                        if let err = state.packageError {
                            Text(err).foregroundStyle(.red).font(.caption)
                        }
                        // 远端旧导入页底部的署名，合并页保留，不丢。
                        Text("王炸奓制作")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        if !message.isEmpty {
                            Text(message).foregroundStyle(.red).font(.caption)
                        }
                    }
                    .padding()
                }
                // 底部两个按钮：导入新的、去目录找更多。
                HStack(spacing: 12) {
                    Button("＋ 导入壁纸") { showPicker = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.blue)
                        .clipShape(Capsule())
                        .buttonStyle(PressBounceButtonStyle())
                    Button("获取更多壁纸") { state.selectedTab = 0 }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .glassCapsule()
                        .buttonStyle(PressBounceButtonStyle())
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(AppBackgroundView())
            .navigationTitle("已导入壁纸包")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清除已安装") {
                        Task { await clearInstalled() }
                    }
                    .disabled(clearing)
                }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker(contentTypes: AppUTTypes.wallpaperPackage) { url in
                    showPicker = false
                    Task { @MainActor in
                        do {
                            let data = try Data(contentsOf: url)
                            let fileName = url.deletingPathExtension().lastPathComponent
                            let name = fileName.isEmpty ? url.lastPathComponent : fileName
                            state.setPackage(data, displayName: fileName.isEmpty ? nil : fileName)
                            // 存进导入库：包文件 + 封面图存沙盒，记录记下来，下次打开还在。
                            if let stored = state.packageData {
                                let thumb = ImportThumbnailMaker.make(from: stored)
                                state.addImportedPackage(data: stored, displayName: name, thumbnail: thumb)
                            }
                        } catch {
                            message = "读文件失败：\(error.localizedDescription)"
                        }
                    }
                }
            }
            .sheet(isPresented: $showPairingPicker) {
                DocumentPicker(contentTypes: [.propertyList]) { url in
                    showPairingPicker = false
                    Task { @MainActor in
                        pairingMessage = ""
                        state.importPairingFile(from: url)
                        if state.pairingLoaded {
                            pairingMessage = "配对文件导入，可以装壁纸了。"
                        } else if !state.statusMessage.isEmpty {
                            pairingMessage = state.statusMessage
                        } else {
                            pairingMessage = "配对文件导入失败，请确认选的是电脑上生成的配对文件（.plist）。"
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $showDetail) {
                ImportDetailView()
            }
            .alert("删除这张导入的壁纸包？", isPresented: Binding(
                get: { pkgToDelete != nil },
                set: { if !$0 { pkgToDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let pkg = pkgToDelete { state.removeImportedPackage(pkg) }
                    pkgToDelete = nil
                }
                Button("取消", role: .cancel) { pkgToDelete = nil }
            } message: {
                Text("只删本机存的这份包，目录里的壁纸不受影响。")
            }
        }
    }

    /// 26 系统用配对区：26 的手机自己生成不了配对文件，27 不显示。
    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("配对文件（26 系统用）").font(.headline)
            Button("下载配置文件") { showPairingPicker = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28).padding(.vertical, 12)
                .glassCapsule()
                .buttonStyle(PressBounceButtonStyle())
            Text("26 的手机自己生成不了配对文件：先在电脑上连 USB 生成，传到手机上（隔空投送，或存到文件 App），再点上面按钮选那个 .plist 导进来。")
                .font(.caption).foregroundStyle(.secondary)
            if state.pairingLoaded {
                Text("配对文件已导入：\(state.pairingDescription)")
                    .font(.caption)
            } else if !pairingMessage.isEmpty {
                Text(pairingMessage).foregroundStyle(.red).font(.caption)
            }
        }
    }

    /// 应用一张导入的包：设为当前包，打开安装详情页。
    private func applyPackage(_ pkg: ImportedPackage) {
        guard let data = state.importedPackageData(pkg) else {
            message = "这个包的文件找不到了，重新导一次。"
            return
        }
        message = ""
        state.setPackage(data, displayName: pkg.displayName)
        showDetail = true
    }

    /// 只在 iOS 26 的手机上显示配对文件下载入口：26 的手机自己生成不了
    /// 配对文件，27 的手机能自己生成，不需要这步。用本机系统版本判断
    ///（App 就跑在这台手机上），不走 deviceInfo（没配对文件时读不到）。
    private var isIOS26: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
    }

    /// 清除已安装：只重索引，不直接删系统描述符文件。
    /// 先让用户在锁屏图库删掉那张再点它，图库才会刷新掉。
    private func clearInstalled() async {
        clearing = true
        clearResult = ""
        defer { clearing = false }
        if await state.clearInstalledRecords(host: "10.7.0.1") {
            clearResult = "已重索引：先在锁屏图库删掉那张再点它，去图库看看那张还在不在。"
        } else {
            clearResult = state.statusMessage.isEmpty ? "重索引未完成：请确认已导入配对记录、回环 VPN 已连接。" : state.statusMessage
        }
    }
}

/// 导入库里一张卡：封面、名字、大小和日期，下面是删除圆钮和应用胶囊。
/// 点封面就应用这张（打开安装详情页）。
private struct ImportedPackageCard: View {
    let pkg: ImportedPackage
    let thumbURL: URL?
    let onApply: () -> Void
    let onDelete: () -> Void

    @State private var thumbImage: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onApply) {
                Group {
                    if let thumbImage {
                        Image(uiImage: thumbImage)
                            .resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
                // 卡片就是锁屏本身的比例 9:19.5，.fill 硬撑满这个框：
                // 锁屏上看到什么样，卡片里就是什么样，整张底图都看得到，
                // 不再只裁中间一段（9:11 裁掉山坡和人）。
                // .fill 不是 .fit：.fit 在滚动列表里按封面原图比例走，图有横有竖、
                // 卡片就高矮不一排不齐。
                .frame(maxWidth: .infinity)
                .aspectRatio(9 / 19.5, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            Text(pkg.displayName)
                .font(.subheadline).bold()
                .lineLimit(1)
            Text("\(sizeText(pkg.size)) · \(dateText(pkg.importedAt))")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .glassCapsule()
                }
                .buttonStyle(PressBounceButtonStyle())
                Button("应用", action: onApply)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .glassCapsule()
                    .buttonStyle(PressBounceButtonStyle())
            }
        }
        .task(id: pkg.id) {
            if let thumbURL, let data = try? Data(contentsOf: thumbURL),
               let image = UIImage(data: data) {
                thumbImage = image
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.quaternary)
            .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
    }

    private func sizeText(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000.0) }
        return "\(bytes) 字节"
    }

    private func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: date)
    }
}

/// 从壁纸包里抠一张封面图（给导入库的卡片用）：封面尽量是锁屏上看到的那张底图。
/// 包是 WALLIVE1 加密包先解密再翻；最长边压到 720。
/// 目录下载也用它从包里抠封面（不另外走网络），所以不加 private。
enum ImportThumbnailMaker {
    /// 封面尽量是锁屏底图：1. 背景画布（Background.ca）里的图就是锁屏底图，
    /// 挑其中最像的；2. 没有背景画布（整包都在 Floating 里）就挑 assets 里
    /// 最像的；3. 连 assets 都没有，翻全包挑最像的。
    /// “最像” = 像素最大那批里最亮的那张：整幅场景图几乎总是最大的，
    /// 人物抠图、装饰小图都比它小；白天那张底图又总比夜里那张亮
    ///（波妞：白天蓝天和夜里星空一样大，亮度一比就分出来了；
    /// 之前按顺序拿，第一张是人物抠图，白底两小孩）。
    static func make(from packageData: Data) -> Data? {
        let zip = ZipFoundationAdapter()
        let plain: Data
        if Wallive1Crypto.isWallive1(packageData) {
            guard let decrypted = try? Wallive1Crypto.decrypt(packageData) else { return nil }
            plain = decrypted
        } else {
            plain = packageData
        }
        guard let entries = try? zip.listEntries(in: plain) else { return nil }
        let imageExts = ["jpeg", "jpg", "png", "heic", "heif", "webp", "tiff", "bmp", "gif"]
        let isImageEntry = { (path: String) -> Bool in
            imageExts.contains((path as NSString).pathExtension.lowercased())
        }
        let assetImages = entries.filter { isImageEntry($0) && $0.lowercased().contains("assets") }
        if let image = bestLockScreenImage(in: assetImages.filter { $0.lowercased().contains("background") }, zip: zip, plain: plain) {
            return compress(image)
        }
        if let image = bestLockScreenImage(in: assetImages, zip: zip, plain: plain) {
            return compress(image)
        }
        if let image = bestLockScreenImage(in: entries.filter(isImageEntry), zip: zip, plain: plain) {
            return compress(image)
        }
        return nil
    }

    /// 在一串图片里挑最像锁屏底图的那张：先按像素筛出最大那批（不小于最大的一半），
    /// 再在其中挑最亮的——白天那张底图总比夜里那张亮。
    private static func bestLockScreenImage(in paths: [String], zip: ZipFoundationAdapter, plain: Data) -> UIImage? {
        var sized: [(image: UIImage, pixels: CGFloat)] = []
        var maxPixels: CGFloat = 0
        for path in paths {
            guard let data = try? zip.readEntry(path, in: plain),
                  let image = UIImage(data: data) else { continue }
            let pixels = image.size.width * image.size.height * image.scale
            maxPixels = max(maxPixels, pixels)
            sized.append((image, pixels))
        }
        guard maxPixels > 0 else { return nil }
        var best: UIImage?
        var bestLuma: CGFloat = -1
        for (image, pixels) in sized where pixels >= maxPixels * 0.5 {
            let luma = meanLuminance(image)
            if luma > bestLuma { bestLuma = luma; best = image }
        }
        return best ?? sized.max(by: { $0.pixels < $1.pixels })?.image
    }

    /// 平均亮度：缩到 32×32 再取平均，够分白天黑夜就行。
    /// 透明的地方算黑，所以人物抠图（大面积透明）亮度天然就低。
    private static func meanLuminance(_ image: UIImage) -> CGFloat {
        let w = 32, h = 32
        guard let cg = image.cgImage else { return 0 }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var sum: CGFloat = 0
        for i in 0..<(w * h) {
            let r = CGFloat(ptr[i * 4]), g = CGFloat(ptr[i * 4 + 1]), b = CGFloat(ptr[i * 4 + 2])
            sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return sum / CGFloat(w * h) / 255.0
    }

    /// 最长边压到 720，控制封面图体积。
    private static func compress(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 720
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = min(1, maxSide / max(longest, 1))
        let scaled = UIGraphicsImageRenderer(size: CGSize(width: size.width * scale, height: size.height * scale)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        }
        return scaled.jpegData(compressionQuality: 0.85)
    }
}

private struct ImportDetailView: View {
    @EnvironmentObject private var state: AppState
    @State private var installing = false
    @State private var installResult = ""
    @State private var installReport: InstallReport?
    /// 备份路这次失败的原因（没失败就是 nil）：核对区失败那版用它写，
    /// 成功那版不沾它。直写那条路不走它，原样不动。
    @State private var installFailedReason: String?
    @State private var installLogText = ""
    @State private var showFullLog = false
    @State private var showFullResult = false
    @State private var showFullVerify = false
    @State private var installStep = "正在安装…"
    @State private var desktopRefreshNote = ""
    @State private var installProgress = 0.0
    /// 正在跑的安装任务，进度框里的"停止"按钮用它取消。
    @State private var installTask: Task<Void, Never>?
    @State private var showRebootConfirm = false
    @State private var rebooting = false
    @State private var rebootResult = ""

    // 详情页两个按钮同宽：按最长的“制作深景包”定。
    private let buttonWidth: CGFloat = 220

    /// 备份路装完要重启手机才进图库（装完本地刷新没成时）：显示“重启手机”按钮。
    private var needsRebootButton: Bool {
        installReport?.mode == .backup
    }

    /// 核对区折叠时只显示的一行摘要：描述符短号 + 注入/偏好/登记/刷新各一词。
    /// 备份路没有读回核对 / 登记那几项，折叠行只写模式；要不要重启看下面的结论行。
    private var verifySummaryLine: String {
        guard let report = installReport else { return "尚未安装，暂无核对结果。" }
        return "描述符 \(String(report.descriptorUUID.prefix(8))) · 27.2"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let info = state.packageInfo {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("壁纸包信息").font(.headline)
                        row("名称", value(info))
                        row("文件大小", sizeText())
                        row("壁纸内容", "1 项")
                        row("导入时间", importDateText())
                        row("描述符", info.descriptorUUID)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("图层信息").font(.headline)
                        row("背景", info.backgroundFile ?? "无")
                        row("漂浮", info.floatingFile ?? "无")
                        row("前景", info.foregroundFile ?? "空壳")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("深景状态").font(.headline)
                        Text(info.hasRenderingConfiguration ? "已有深景开关" : "无深景开关")
                        Text(info.floatingHasClownfishPrefix ? "漂浮层已有 Clownfish 前缀" : "漂浮层无 Clownfish 前缀")
                    }
                    .font(.caption)

                    HStack {
                        Spacer()
                        Button("制作深景包") { state.selectedTab = 2 }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: buttonWidth).padding(.vertical, 12).glassCapsule()
                            .buttonStyle(PressBounceButtonStyle())
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Button("安装壁纸") { installTask = Task { await runInstall() } }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: buttonWidth).padding(.vertical, 12).glassCapsule()
                            .buttonStyle(PressBounceButtonStyle())
                            // 不配对也能装：按钮只看包和安装状态。
                            .disabled(state.packageData == nil || installing)
                        Spacer()
                    }
                    Text("支持 iOS 27.0 – 27.2")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    if !installResult.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("安装结果").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(showFullResult ? "收起" : "展开全部") { showFullResult.toggle() }
                                    .font(.caption)
                            }
                            Text(installResult)
                                .font(.caption)
                                .lineLimit(showFullResult ? nil : 1)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 1))
                    }
                    if !state.statusMessage.isEmpty {
                        Text(state.statusMessage).foregroundStyle(.red).font(.caption)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("核对已安装").font(.headline)
                            Spacer()
                            Button(showFullVerify ? "收起" : "展开全部") { showFullVerify.toggle() }
                                .font(.caption)
                        }
                        if showFullVerify {
                        if let report = installReport {
                            Text("描述符：\(report.descriptorUUID)").font(.caption).textSelection(.enabled)
                            if let summary = report.backupSummary {
                                Text(summary).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(report.injectResults.indices, id: \.self) { index in
                                let result = report.injectResults[index]
                                Text("\(shortTargetDir(result.targetParentDir))：\(result.ok ? "成功" : "失败")\(result.error.map { "（\($0)）" } ?? "")").font(.caption).textSelection(.enabled)
                            }
                            Text("偏好写入：\(report.preferencesWritten ? "成功" : "未写入")").font(.caption)
                            ForEach(report.verifyResults.indices, id: \.self) { index in
                                let v = report.verifyResults[index]
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("读回核对 \(shortTargetDir(v.targetParentDir))：").font(.caption).textSelection(.enabled)
                                    if v.channelUnavailable {
                                        Text("读回通道不可用（系统不放行容器直读），核对不到目标，不代表描述符缺失。\(v.error ?? "")").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("描述符目录：\(v.descriptorDirExists ? "在" : "缺失")\(v.descriptorDirEntries.map { "（\($0) 项）" } ?? "")；Wallpaper.plist：\(v.wallpaperPlistExists ? "在" : "缺失")\(v.wallpaperPlistSize.map { "（\($0) 字节）" } ?? "")；标识文件：\(v.identifierExists ? "在" : "缺失")\(v.identifierContent.map { "（内容 \($0)）" } ?? "")").font(.caption).textSelection(.enabled)
                                        if let err = v.error {
                                            Text(err).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            if let reg = report.registration {
                                Text("登记：远程记录 \(reg.remoteRecords) 条、包记录 \(reg.packageRecords) 条、名称 \(reg.names) 条\(reg.error.map { "（\($0)）" } ?? "")").font(.caption)
                            }
                            if let refresh = report.refresh {
                                if refresh.confirmed {
                                    Text("进程刷新：已确认 PosterBoard 进程已重启（旧 pid \(refresh.oldPid.map { "\($0)" } ?? "?") → 新 pid \(refresh.newPid.map { "\($0)" } ?? "?")，重连验证 pid \(refresh.verifiedPid.map { "\($0)" } ?? "?")）。").font(.caption)
                                } else {
                                    Text("进程刷新：未确认\(refresh.error.map { "（\($0)）" } ?? "")").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("图库里有没有：未验证——去锁屏长按进图库看，出现后再点设为墙纸组合。").font(.caption).foregroundStyle(.secondary)
                            }
                            if !report.verifyResults.isEmpty && report.verifyResults.allSatisfy({ $0.allPresent }) {
                                Text("已在设备上核对到：每个目标的描述符目录、Wallpaper.plist、标识文件均在。").font(.caption)
                            } else if report.verifyResults.contains(where: { !$0.channelUnavailable }) {
                                Text("读回核对有缺失：写盘成功不代表图库已列出，缺失项见上面。").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("尚未安装，暂无核对结果。写盘成功不代表图库已列出。").font(.caption).foregroundStyle(.secondary)
                        }
                        // 成功不铺日志：只在失败时显示完整日志，成功时诊断区已够用。
                        if !installLogText.isEmpty && installFailedReason != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("安装日志（可长按复制）").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button(showFullLog ? "收起" : "展开全部") { showFullLog.toggle() }
                                        .font(.caption)
                                }
                                Text(showFullLog ? installLogText : logPreviewText)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 1))
                        }
                        } else {
                            Text(verifySummaryLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if needsRebootButton {
                        Text("安装成功，再去锁屏长按进图库核对新壁纸是否出现，出现后再点设为墙纸组合。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if state.hasPairingFile {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("27.2装完要重启手机，壁纸才会进图库。点一下直接重启，不用手动关机再开机。")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button("重启手机") { showRebootConfirm = true }
                                        .disabled(rebooting)
                                    if rebooting { ProgressView() }
                                }.buttonStyle(.bordered)
                                if !rebootResult.isEmpty {
                                    Text(rebootResult).font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                            .alert("重启手机？", isPresented: $showRebootConfirm) {
                                Button("重启手机", role: .destructive) {
                                    Task { await runReboot() }
                                }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("重启后 PosterBoard 会重新读取描述符，壁纸才会出现在图库里。重启大概要一分钟，期间别碰手机。")
                            }
                        } else {
                            // 没配对（V1.10 起）：跟人家一样刷新桌面，不再让重启手机。
                            VStack(alignment: .leading, spacing: 8) {
                                Text("没配对装完跟人家一样：点「刷新桌面」，桌面会黑一下自己回来（App 闪退属正常），回来后锁屏长按进图库看。")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button("刷新桌面") {
                                        desktopRefreshNote = "网页已加载，桌面马上会黑一下自己回来。20 秒后桌面还在的话就是这招没成，再点一次；还不行就重启手机。"
                                        DesktopRestart.trigger()
                                    }
                                }.buttonStyle(.bordered)
                                if !desktopRefreshNote.isEmpty {
                                    Text(desktopRefreshNote).font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    } else if let reason = installFailedReason {
                        Text("安装失败：\(reason)。再去锁屏长按进图库核对新壁纸是否出现，出现后再点设为墙纸组合；没出现就把诊断区的结果和日志发来排查。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("去锁屏长按进图库核对新壁纸是否出现，出现后再点设为墙纸组合；没出现就把诊断区的结果和日志发来排查。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("还没选包：先回列表导入一个包。").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(AppBackgroundView())
        .navigationTitle("壁纸包详情")
        .overlay {
            if installing {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView(value: installProgress)
                            .frame(width: 200)
                        Text(installStep)
                            .foregroundStyle(.white)
                        Text("\(Int(installProgress * 100))%")
                            // #02：弹窗里的百分比和提示原来是次要灰，灰底上看不清，写死浅白字。
                            .font(.caption).foregroundStyle(.white.opacity(0.85))
                        Text("请稍等，不要退出").font(.caption).foregroundStyle(.white.opacity(0.85))
                        Button("停止") { installTask?.cancel() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(radius: 20)
                }
            }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).lineLimit(1).textSelection(.enabled)
        }
    }

    /// 名称行：目录下载的包直接显示中文名；直接导入的文件，清理包里的技术名再显示。
    private func value(_ info: TendiesPackageInfo) -> String {
        if let name = state.packageDisplayName, !name.isEmpty { return name }
        var name = (info.wallpaperDirectory as NSString).lastPathComponent
        if name.hasSuffix(".wallpaper") { name = String(name.dropLast(".wallpaper".count)) }
        // 去编号前缀：7926.SpiderManDepth-... -> SpiderManDepth-...
        if let dot = name.firstIndex(of: ".") {
            let head = name[name.startIndex..<dot]
            if head.allSatisfy({ $0.isNumber }) { name = String(name[name.index(after: dot)...]) }
        }
        // 去尺寸后缀：-390w-844h@3x~iphone
        if let range = name.range(of: "-\\d+w-\\d+h@\\dx~iphone$", options: .regularExpression) {
            name.removeSubrange(range)
        }
        // 去深景后缀：SpiderManDepth -> SpiderMan
        if name.hasSuffix("Depth") { name = String(name.dropLast("Depth".count)) }
        return name.isEmpty ? info.descriptorUUID : name
    }

    private func sizeText() -> String {
        let bytes = state.packageData?.count ?? 0
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000.0) }
        return "\(bytes) 字节"
    }

    private func importDateText() -> String {
        guard let date = state.packageImportedAt else { return "本次导入" }
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日 H:mm"
        return f.string(from: date)
    }

    /// 详情页直接安装：装完不重启桌面、不闪屏、不黑屏；返回成功只代表
    /// 写盘函数返回成功，不代表图库已列出。成功文案分两档：第一档是写盘结果，
    /// 第二档（目标落地已核对）只有读回核对全部通过时才出现；通道不可用或
    /// 有缺失时，第二档不出现，页面如实写通道不可用或缺失。
    private func runInstall() async {
        installing = true
        installStep = "正在准备安装包…"
        installProgress = 0
        installResult = ""
        installReport = nil
        installFailedReason = nil
        installLogText = ""
        defer { installing = false }
        if let report = try? await state.installWithReport(host: "10.7.0.1", onProgress: { step, fraction in
            Task { @MainActor in
                installStep = step
                installProgress = fraction
            }
        }) {
            installReport = report
            installLogText = InstallLog.shared.tail(60)
            // 统一一条路：成功只写四个字，载荷数、描述符这些长日志留在日志框里。
            installResult = "安装成功"
            // 装完本地刷新没成时：有配对让用户重启手机；没配对跟人家一样
            // 自动刷新桌面，详情页另留手动按钮。
            if !(report.refresh?.confirmed ?? false) {
                if state.hasPairingFile {
                    installResult = "安装成功：刷新没确认。重启手机，然后锁屏长按进图库查看。"
                } else {
                    installResult = "安装成功：只写了描述符目录，表和偏好没碰。正在刷新桌面（跟人家一样）——桌面会黑一下自己回来，回来后锁屏长按进图库看。"
                    DesktopRestart.trigger()
                }
            }
        } else if Task.isCancelled {
            // 用户点了停止（`try?` 把取消错误吞成了 nil）。
            installResult = "已停止"
            installLogText = InstallLog.shared.tail(60)
        } else if !state.statusMessage.isEmpty {
            // 安装失败：结果区写失败原因，核对区也进失败那版。
            installResult = state.statusMessage
            installFailedReason = installFailureReason(from: state.statusMessage)
            installLogText = InstallLog.shared.tail(60)
        } else if state.statusMessage.isEmpty {
            installResult = "安装未完成：再试一次；还不行就看提示和下面日志框里的原因。"
        }
    }

    /// 一键重启手机：备份路装完必须重启一次壁纸才会进图库（27.2 上
    /// 杀 PosterBoard 刷不动，只能重启）。用户亲手点确认才发指令，
    /// 绝不自动重启。指令发出后手机自己重启，重启完去锁屏长按进图库看。
    private func runReboot() async {
        guard !rebooting else { return }
        rebooting = true
        defer { rebooting = false }
        guard state.hasPairingFile else {
            rebootResult = "重启没发：没有配对记录文件，先在配对记录页生成或导入一个。"
            return
        }
        rebootResult = "正在发重启指令…"
        let ok = await RestoreTest.deviceReboot(pairingPath: state.pairingFileURL.path)
        if ok {
            rebootResult = "已发送重启指令，手机正在重启。重启后去锁屏长按进图库看有没有这张壁纸。"
        } else {
            rebootResult = "重启指令没发出去，原因见下面日志。也可以手动关机再开机。"
        }
    }

    /// 折叠时框里只显示日志最后 3 行，点展开看全部。
    private var logPreviewText: String {
        let lines = installLogText.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(3).joined(separator: "\n")
    }

    /// 安装失败原因：statusMessage 是“备份安装失败：<原因>”，核对区只留 <原因>。
    private func installFailureReason(from statusMessage: String) -> String {
        if let range = statusMessage.range(of: "备份安装失败：") {
            return String(statusMessage[range.upperBound...])
        }
        return statusMessage
    }

    private func shortTargetDir(_ path: String) -> String {
        if let range = path.range(of: "Extensions/") {
            return String(path[range.lowerBound...])
        }
        return path
    }
}
