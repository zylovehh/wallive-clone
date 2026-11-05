// ImportView.swift
// V6 导入安装合并页：列表页 + 详情二级页，不再单独占安装页签。
// 列表：已导入壁纸包、右上角清除已安装、＋导入新的壁纸包、左滑删除。
// 详情：壁纸包信息、图层信息、深景状态、制作深景包、安装壁纸。
// 安装：装完不重启桌面、不闪屏、不黑屏；写盘返回成功不代表图库已列出，
// 诊断区显示逐目录结果，目标落地尚未核对（读回接口未就位）。

import Foundation
import SwiftUI

/// 高透液态玻璃胶囊：iOS 26+ 用系统玻璃，低版本回退半透明黑。
private struct LiquidGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.white.opacity(0.08)), in: Capsule())
        } else {
            content.background(.black.opacity(0.12)).clipShape(Capsule())
        }
    }
}

private extension View {
    func glassCapsule() -> some View { modifier(LiquidGlassCapsule()) }
}

struct ImportView: View {
    @EnvironmentObject private var state: AppState
    @State private var showPicker = false
    @State private var message = ""
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
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

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
                    Text("还没导入包。点上面按钮选本地 .tendies / .wallive，WALLIVE1 加密包会自动解密后再检查。")
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
                            state.setPackage(data)
                        } catch {
                            message = "读文件失败：\(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    private func packageName(from info: TendiesPackageInfo) -> String {
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
    @State private var installLogText = ""
    @State private var showFullLog = false

    // 详情页两个按钮同宽：按最长的“制作深景包”定。
    private let buttonWidth: CGFloat = 220

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
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Button("安装壁纸") { Task { await runInstall() } }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: buttonWidth).padding(.vertical, 12).glassCapsule()
                            .disabled(state.packageData == nil || !state.pairingLoaded || installing)
                        Spacer()
                    }
                    if !installResult.isEmpty { Text(installResult).font(.caption) }
                    if !state.statusMessage.isEmpty {
                        Text(state.statusMessage).foregroundStyle(.red).font(.caption)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("核对已安装").font(.headline)
                        if let report = installReport {
                            Text("描述符：\(report.descriptorUUID)").font(.caption).textSelection(.enabled)
                            ForEach(report.injectResults.indices, id: \.self) { index in
                                let result = report.injectResults[index]
                                Text("\(shortTargetDir(result.targetParentDir))：\(result.ok ? "成功" : "失败")\(result.error.map { "（\($0)）" } ?? "")").font(.caption).textSelection(.enabled)
                            }
                            Text("偏好写入：\(report.preferencesWritten ? "成功" : "未写入")").font(.caption)
                            Text("尚未核对目标落地（读回接口未就位，写盘成功不代表图库已列出）。").font(.caption).foregroundStyle(.secondary)
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
                            Text("尚未安装，暂无核对结果。写盘成功不代表图库已列出，目标落地尚未核对（读回接口未就位）。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("去锁屏长按进图库核对新壁纸是否出现，出现后再点设为墙纸组合；没出现就把诊断区的结果和日志发来排查。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("还没选包：先回列表导入一个包。").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("壁纸包详情")
        .overlay {
            if installing {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在安装…")
                        Text("请稍等，不要退出").font(.caption).foregroundStyle(.secondary)
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

    private func value(_ info: TendiesPackageInfo) -> String {
        let name = (info.wallpaperDirectory as NSString).lastPathComponent
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

    /// 详情页直接安装：装完不重启桌面、不闪屏、不黑屏；返回成功只代表
    /// 写盘函数返回成功，不代表图库已列出。成功文案分两档：第一档是写盘结果，
    /// 第二档（目标落地已核对）在读回接口就位之前不得出现。
    private func runInstall() async {
        installing = true
        installResult = ""
        installReport = nil
        installLogText = ""
        defer { installing = false }
        if let report = await state.installWithReport(host: "10.7.0.1") {
            installReport = report
            installLogText = InstallLog.shared.tail(60)
            let dirLines = report.injectResults.map { result in
                let short = shortTargetDir(result.targetParentDir)
                return result.ok ? "\(short)：成功" : "\(short)：失败（\(result.error ?? "未知错误")）"
            }.joined(separator: "；")
            installResult = "已写入设备：描述符 \(report.descriptorUUID)。已写目录：\(dirLines)。偏好写入：\(report.preferencesWritten ? "成功" : "未写入")。注意：这只代表写盘函数返回成功，不代表图库已列出。尚未核对目标落地（读回接口未就位）。"
        } else if state.statusMessage.isEmpty {
            installResult = "安装未完成：请确认已导入配对记录、回环 VPN 已连接，再试一次。"
        }
    }

    /// 折叠时框里只显示日志最后 5 行，点展开看全部。
    private var logPreviewText: String {
        let lines = installLogText.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(5).joined(separator: "\n")
    }

    private func shortTargetDir(_ path: String) -> String {
        if let range = path.range(of: "Extensions/") {
            return String(path[range.lowerBound...])
        }
        return path
    }
}
