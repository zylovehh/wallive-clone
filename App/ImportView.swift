// ImportView.swift
// V6 导入安装合并页：列表页 + 详情二级页，不再单独占安装页签。
// 列表：已导入壁纸包、右上角清除已安装、＋导入新的壁纸包、左滑删除。
// 详情：壁纸包信息、图层信息、深景状态、制作深景包、安装壁纸。
// 安装：装完不重启桌面、不闪屏、不黑屏；写盘返回成功不代表图库已列出，
// 诊断区显示逐目录结果、读回核对（HouseArrest 通道）、登记条数与进程刷新。

import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

    var body: some View {
        NavigationStack {
            List {
                // 导入新包入口：放列表上边，不然没地方导新包。
                HStack {
                    Spacer()
                    Button("＋ 导入新的壁纸包") { showPicker = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 12)
                        .glassCapsule()
                        .buttonStyle(PressBounceButtonStyle())
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // 26 系统用：配对文件下载/导入入口，只在 iOS 26 的手机上显示。
                // 26 的手机自己生成不了配对文件，得电脑连 USB 生成、传到手机上再导进来；
                // 27 的手机能自己生成，不需要这步，所以 27 不显示。
                if isIOS26 {
                    Section("配对文件（26 系统用）") {
                        HStack {
                            Spacer()
                            Button("下载配置文件") { showPairingPicker = true }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 28).padding(.vertical, 12)
                                .glassCapsule()
                                .buttonStyle(PressBounceButtonStyle())
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        Text("26 的手机自己生成不了配对文件：先在电脑上连 USB 生成，传到手机上（隔空投送，或存到文件 App），再点上面按钮选那个 .plist 导进来。")
                            .font(.caption).foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                        if state.pairingLoaded {
                            Text("配对文件已导入：\(state.pairingDescription)")
                                .font(.caption)
                                .listRowBackground(Color.clear)
                        } else if !pairingMessage.isEmpty {
                            Text(pairingMessage).foregroundStyle(.red).font(.caption)
                                .listRowBackground(Color.clear)
                        }
                    }
                }

                if let info = state.packageInfo {
                    Section("1 个壁纸包") {
                        NavigationLink(destination: ImportDetailView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill").foregroundStyle(.blue).font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(packageName(from: info)).font(.headline).lineLimit(1)
                                    Text("Collections · 1 项壁纸内容").font(.caption).foregroundStyle(.secondary)
                                    Text("\(sizeText()) · \(importDateText())").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                state.packageData = nil
                                state.packageInfo = nil
                                state.packageError = nil
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                } else {
                    Text("还没导入包。点上面按钮选本地 .tendies / .wallive，没加密的包导入时会自动转成 WALLIVE1 加密版（只有本 App 能装），加密包会自动解密后再检查。")
                        .foregroundStyle(.secondary).font(.caption)
                        .listRowBackground(Color.clear)
                }

                if !clearResult.isEmpty {
                    Text(clearResult).font(.caption).listRowBackground(Color.clear)
                }
                if let err = state.packageError {
                    Text(err).foregroundStyle(.red).font(.caption).listRowBackground(Color.clear)
                }
                // 远端旧导入页底部的署名，合并页保留，不丢。
                Text("王炸奓制作")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                if !message.isEmpty {
                    Text(message).foregroundStyle(.red).font(.caption).listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
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
                DocumentPicker(contentTypes: [AppUTTypes.tendies, .zip]) { url in
                    showPicker = false
                    Task { @MainActor in
                        do {
                            let data = try Data(contentsOf: url)
                            // 名称行显示用户选的文件名（去后缀），不是包里的技术名。
                            let fileName = url.deletingPathExtension().lastPathComponent
                            state.setPackage(data, displayName: fileName.isEmpty ? nil : fileName)
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
                            pairingMessage = "配对文件已导入，可以装壁纸了。"
                        } else if !state.statusMessage.isEmpty {
                            pairingMessage = state.statusMessage
                        } else {
                            pairingMessage = "配对文件导入失败，请确认选的是电脑上生成的配对文件（.plist）。"
                        }
                    }
                }
            }
        }
    }

    /// 只在 iOS 26 的手机上显示配对文件下载入口：26 的手机自己生成不了
    /// 配对文件，27 的手机能自己生成，不需要这步。用本机系统版本判断
    ///（App 就跑在这台手机上），不走 deviceInfo（没配对文件时读不到）。
    private var isIOS26: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
    }

    private func packageName(from info: TendiesPackageInfo) -> String {
        // 目录下载的中文名 / 直接导入的文件名优先，包里的技术名只做兜底。
        if let name = state.packageDisplayName, !name.isEmpty { return name }
        let dir = info.wallpaperDirectory
        let name = (dir as NSString).lastPathComponent
        return name.hasSuffix(".wallpaper") ? String(name.dropLast(".wallpaper".count)) : name
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
    @State private var installProgress = 0.0
    /// 正在跑的安装任务，进度框里的"停止"按钮用它取消。
    @State private var installTask: Task<Void, Never>?
    @State private var showRebootConfirm = false
    @State private var rebooting = false
    @State private var rebootResult = ""

    // 详情页两个按钮同宽：按最长的“制作深景包”定。
    private let buttonWidth: CGFloat = 220

    /// 这次安装实际走哪条路（按三态选择 + 设备版本解析）。
    /// 设备版本读不到时按备份算（fail closed），不猜版本走直写。
    private var effectiveMode: PosterBoardApplyMode {
        state.applyChoice.resolvedMode(
            deviceVersion: state.deviceInfo?.productVersion ?? "",
            buildVersion: state.deviceInfo?.buildVersion ?? "")
    }

    /// 模式提示行：这次实际会用的模式 + 为什么。
    private var modeHintText: String {
        state.applyChoice.hintText(
            deviceVersion: state.deviceInfo?.productVersion ?? "",
            buildVersion: state.deviceInfo?.buildVersion ?? "")
    }

    /// 核对区折叠时只显示的一行摘要：描述符短号 + 注入/偏好/登记/刷新各一词。
    /// 备份路没有读回核对 / 登记那几项，折叠行只写模式；要不要重启看下面的结论行。
    private var verifySummaryLine: String {
        guard let report = installReport else { return "尚未安装，暂无核对结果。" }
        if report.mode == .backup {
            return "描述符 \(String(report.descriptorUUID.prefix(8))) · 备份还原"
        }
        let inject = report.injectResults.allSatisfy(\.ok) ? "注入成功" : "注入有失败"
        let prefs = report.preferencesWritten ? "偏好成功" : "偏好未写入"
        let reg = report.registration.map { "登记 \($0.remoteRecords)/\($0.packageRecords)/\($0.names)" } ?? "登记未执行"
        let refresh: String
        if let r = report.refresh {
            refresh = r.confirmed ? "刷新已确认" : "刷新未确认"
        } else {
            refresh = "刷新未执行"
        }
        return "描述符 \(String(report.descriptorUUID.prefix(8))) · \(inject) · \(prefs) · \(reg) · \(refresh)"
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("安装方式").font(.headline)
                        Picker("安装方式", selection: $state.applyChoice) {
                            ForEach(ApplyModeChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(installing)
                        Text(modeHintText)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button("安装壁纸") { installTask = Task { await runInstall() } }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: buttonWidth).padding(.vertical, 12).glassCapsule()
                            .buttonStyle(PressBounceButtonStyle())
                            .disabled(state.packageData == nil || !state.pairingLoaded || installing)
                        Spacer()
                    }
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
                        if !installLogText.isEmpty {
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
                    if installReport?.mode == .backup {
                        Text("安装成功，再去锁屏长按进图库核对新壁纸是否出现，出现后再点设为墙纸组合。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("备份还原装完要重启手机，壁纸才会进图库。点一下直接重启，不用手动关机再开机。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("重启手机") { showRebootConfirm = true }
                                    .disabled(rebooting || !state.hasPairingFile)
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
                            Text("重启后 PosterBoard 会重新读取新表，壁纸才会出现在图库里。重启大概要一分钟，期间别碰手机。")
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
        .task { await state.refreshDeviceInfo() }
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
            if report.mode == .backup {
                // 备份路现在也写偏好、也调刷新（RestoreTest 里做的）；读回核对和
                // 登记这两项没有，核对看日志框。成功只写四个字，载荷数、行数、
                // 描述符这些长日志留在日志框里，不显示在结果区。
                installResult = "安装成功"
            } else {
                let dirLines = report.injectResults.map { result in
                    let short = shortTargetDir(result.targetParentDir)
                    return result.ok ? "\(short)：成功" : "\(short)：失败（\(result.error ?? "未知错误")）"
                }.joined(separator: "；")
                let verifySummary: String
                if report.verifyResults.isEmpty {
                    verifySummary = "读回核对未执行。"
                } else if report.verifyResults.allSatisfy({ $0.allPresent }) {
                    verifySummary = "已在设备上核对到：每个目标的描述符目录、Wallpaper.plist、标识文件均在。"
                } else if report.verifyResults.contains(where: { $0.channelUnavailable }) {
                    verifySummary = "读回通道不可用（系统不放行容器直读），核对不到目标，不代表描述符缺失。"
                } else {
                    let missing = report.verifyResults.filter { !$0.allPresent }.map { shortTargetDir($0.targetParentDir) }.joined(separator: "、")
                    verifySummary = "读回核对有缺失（\(missing)），写盘成功不代表图库已列出。"
                }
                let refreshSummary: String
                if let refresh = report.refresh {
                    if refresh.confirmed {
                        refreshSummary = "进程刷新：已确认 PosterBoard 进程已重启（旧 pid \(refresh.oldPid.map { "\($0)" } ?? "?") → 新 pid \(refresh.newPid.map { "\($0)" } ?? "?")）。"
                    } else {
                        let refreshErrorText = refresh.error.map { "（\($0)）" } ?? ""
                        refreshSummary = "进程刷新：未确认\(refreshErrorText)。"
                    }
                } else {
                    refreshSummary = "进程刷新：未执行。"
                }
                installResult = "已写入设备：描述符 \(report.descriptorUUID)。已写目录：\(dirLines)。偏好写入：\(report.preferencesWritten ? "成功" : "未写入")。注意：这只代表写盘函数返回成功，不代表图库已列出。\(verifySummary) \(refreshSummary)"
                }
        } else if Task.isCancelled {
            // 用户点了停止（`try?` 把取消错误吞成了 nil）。备份路只报“已停止”，
            // 直写那条路的文案不动。
            installResult = effectiveMode == .backup ? "已停止" : "已停止取备份。下次取备份如果一直连不上，重启手机一次再试。"
            installLogText = InstallLog.shared.tail(60)
        } else if effectiveMode == .backup && !state.statusMessage.isEmpty {
            // 备份路失败：结果区写失败原因，核对区也进失败那版。
            installResult = state.statusMessage
            installFailedReason = backupFailureReason(from: state.statusMessage)
            installLogText = InstallLog.shared.tail(60)
        } else if state.statusMessage.isEmpty {
            installResult = "安装未完成：请确认已导入配对记录、回环 VPN 已连接，再试一次。"
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

    /// 备份路失败原因：statusMessage 是“备份安装失败：<原因>”，核对区只留 <原因>。
    private func backupFailureReason(from statusMessage: String) -> String {
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
