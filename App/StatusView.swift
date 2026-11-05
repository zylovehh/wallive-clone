// StatusView.swift
// 状态：卡片点进二级页看详情（回环 VPN、配对记录、已安装记录、诊断日志），主页面只做菜单。

import SwiftUI
import UIKit

/// 液态透明按钮样式：iOS 26+ 用透明系统玻璃，低版本回退半透明白胶囊。
private struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
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

struct StatusView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openURL) private var openURL
    // 内置 VPN 实例放主页面持有，二级页只观察，避免每次进二级页重建导致状态不对。
    @StateObject private var vpn = VPNManager()
    @State private var host = "10.7.0.1"
    @State private var portText = "62078"
    // QQ 卡渐变文字：细体，从左往右流动循环。

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    NavigationLink(destination: StatusVPNPage(vpn: vpn, host: $host, portText: $portText)) {
                        HStack {
                            Image(systemName: "network").foregroundStyle(.blue).font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("回环 VPN").font(.headline)
                                Text("内置 VPN 开关与回环连通检查").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }
                        .padding()
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    NavigationLink(destination: StatusPairingPage()) {
                        HStack {
                            Image(systemName: "key").foregroundStyle(.blue).font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("配对记录").font(.headline)
                                Text(state.pairingLoaded ? "已导入" : "未导入").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }
                        .padding()
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    NavigationLink(destination: StatusHistoryPage()) {
                        HStack {
                            Image(systemName: "archivebox").foregroundStyle(.blue).font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("已安装记录").font(.headline)
                                Text(state.installHistory.isEmpty ? "还没有成功安装的记录" : "共 \(state.installHistory.count) 条").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }
                        .padding()
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    NavigationLink(destination: StatusLogPage()) {
                        HStack {
                            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.blue).font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("应用失败异常诊断日志").font(.headline)
                                Text("查看和导出最近的安装记录").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }
                        .padding()
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
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
                    Text("说明：本 App 不含广告、不含会员与解锁逻辑；配对记录文件只存在 App 沙盒内，不会发给任何人。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // 说明最底下：App 版本号，跟目录页角标同一个来源，改版号只改一处。
                    Text("版本：\(AppBuild.tag)")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding()
                .background(AppBackgroundView())
                .navigationTitle("状态")
                .onAppear { state.refreshPairingStatus() }
            }
        }
    }
}

private struct StatusVPNPage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var vpn: VPNManager
    @Binding var host: String
    @Binding var portText: String
    @State private var vpnResult = ""
    @State private var checking = false
    // 配对操作从配对记录页移过来：先连通 VPN 才能配对，放一页顺手。
    @ObservedObject private var pairingHost = PairingHost.shared
    @State private var generating = false
    @State private var generateResult = ""
    @State private var pairingCheckResult = ""
    @State private var pairingChecking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 卡片 1：内置 VPN
                VStack(alignment: .leading, spacing: 12) {
                    Text("内置 VPN").font(.headline)
                    Text(vpn.statusText).font(.caption).foregroundStyle(.secondary)
                    Text("第一次开启会弹系统提示，点“允许”。内置 VPN 只连本机（10.7.0.1），流量不出手机。开起来后，下面的检查和配对就能直接用。")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if vpn.isConnected {
                        Button { vpn.stop() } label: {
                            Text("关闭内置 VPN").frame(maxWidth: .infinity)
                        }.buttonStyle(GlassButtonStyle())
                    } else {
                        Button { Task { await vpn.start() } } label: {
                            Text("开启内置 VPN").frame(maxWidth: .infinity)
                        }.buttonStyle(GlassButtonStyle())
                    }
                    if !vpn.lastError.isEmpty {
                        Text(vpn.lastError).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                // 卡片 2：回环 VPN 连通
                VStack(alignment: .leading, spacing: 12) {
                    Text("回环 VPN 连通").font(.headline)
                    HStack(spacing: 10) {
                        TextField("管家地址", text: $host)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        TextField("端口", text: $portText)
                            .keyboardType(.numberPad).frame(width: 90)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Button { Task { await check() } } label: {
                        Text("检查").frame(maxWidth: .infinity)
                    }.buttonStyle(GlassButtonStyle())
                    if checking {
                        ProgressView().frame(maxWidth: .infinity, alignment: .center)
                    }
                    if !vpnResult.isEmpty {
                        Text(vpnResult).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                // 卡片 3：配对
                VStack(alignment: .leading, spacing: 12) {
                    Text("配对").font(.headline)
                    // 两个配对按钮并排、等宽，排版对齐。
                    HStack(spacing: 12) {
                        Button {
                            Task { await generate() }
                        } label: {
                            Text("生成配对文件").frame(maxWidth: .infinity)
                        }
                        .disabled(generating)
                        Button {
                            Task { await checkPairing() }
                        } label: {
                            Text("检查配对状态").frame(maxWidth: .infinity)
                        }
                        .disabled(pairingChecking)
                    }.buttonStyle(GlassButtonStyle())
                    if generating || pairingChecking {
                        ProgressView().frame(maxWidth: .infinity, alignment: .center)
                    }
                    if pairingHost.running {
                        Button { pairingHost.softCancel() } label: {
                            Text("取消").frame(maxWidth: .infinity)
                        }.buttonStyle(GlassButtonStyle())
                    }
                    if let pin = pairingHost.pairingPIN {
                        Text("配对 PIN：\(pin)")
                            .font(.title2.bold())
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text("去“设置 › 隐私与安全 › 开发者模式 › 与壁纸安装器配对”输入上面这串数字。")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !pairingHost.pairingStatus.isEmpty && pairingHost.pairingStatus != "未开始" {
                        Text(pairingHost.pairingStatus).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !generateResult.isEmpty {
                        Text(generateResult).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !pairingCheckResult.isEmpty {
                        Text(pairingCheckResult).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
            }
            .padding()
            .navigationTitle("回环 VPN")
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        let port = UInt16(portText) ?? 62078
        let ok = await state.checkVPN(host: host, port: port)
        vpnResult = ok ? "通：管家地址可达。" : "不通：请先确认回环 VPN 已安装并连接。"
    }

    /// 生成配对文件：先复用检查按钮的 VPN 连通逻辑，没连 VPN 就不配对；
    /// 连通才启动本机配对主机（后台等握手），同时自动跳到
    /// “设置 › 隐私与安全 › 开发者模式”，用户点“与壁纸安装器配对”，
    /// PIN 出现后回本 App 看一眼，再去设置里输 PIN。成功刷新状态，失败报真实原因。
    private func generate() async {
        guard !generating else { return }
        generating = true
        generateResult = "正在检查回环 VPN…"
        let port = UInt16(portText) ?? 62078
        let vpnOK = await state.checkVPN(host: host, port: port)
        guard vpnOK else {
            generating = false
            generateResult = "没连上回环 VPN：请先在上面开启内置 VPN，或连上 LocalDevVPN，再点生成。"
            return
        }
        generateResult = "正在启动本机配对…马上跳到设置里继续。"
        Task {
            do {
                _ = try await pairingHost.startAndWait()
                state.refreshPairingStatus()
                generateResult = "生成成功：配对文件已存好，可以去安装了。"
            } catch {
                generateResult = "生成失败：\(error.localizedDescription)"
            }
            generating = false
        }
        // 配对主机已在后台启动，直接跳设置 → 隐私与安全 → 开发者模式。
        openDeveloperSettings()
    }

    /// 自动跳到“设置 → 隐私与安全 → 开发者模式”。
    /// App-Prefs 是系统设置内部链接，侧载 App 能用（不上 App Store，不用过审）。
    /// 两个教训：open 必须在主线程调（后台线程调了没反应）；只试一个链接不够，
    /// 按顺序挨个试，哪个通了就停，全不通才告诉用户手动去。
    private func openDeveloperSettings() {
        let candidates = [
            "App-Prefs:root=Privacy&path=DEVELOPER",
            "prefs:root=Privacy&path=DEVELOPER",
            "App-Prefs:root=Privacy",
            "prefs:root=Privacy",
        ]
        Task { @MainActor in
            tryOpenSettings(candidates: candidates, index: 0)
        }
    }

    /// 按顺序试设置链接：打不开就试下一个，全打不开就告诉用户手动去哪。
    @MainActor
    private func tryOpenSettings(candidates: [String], index: Int) {
        guard index < candidates.count, let url = URL(string: candidates[index]) else {
            generateResult = "没跳过去：请手动去“设置 → 隐私与安全 → 开发者模式”，点“与壁纸安装器配对”输 PIN。"
            return
        }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok {
                Task { @MainActor in
                    self.tryOpenSettings(candidates: candidates, index: index + 1)
                }
            }
        }
    }

    /// 检查配对状态：用配对文件实打实连一次管家服务找容器，
    /// 只读不写。通说明配对本身没问题，安装失败就不是配对的事。
    private func checkPairing() async {
        guard !pairingChecking else { return }
        pairingChecking = true
        defer { pairingChecking = false }
        guard state.hasPairingFile else {
            pairingCheckResult = "没有配对记录文件：先点“生成配对文件”或导入一个。"
            return
        }
        do {
            _ = try await AirliftInstaller.checkPairing(
                pairingPath: state.pairingFileURL.path, targetHost: host)
            pairingCheckResult = "配对有效：能连上管家服务并找到 PosterBoard 容器。"
        } catch {
            pairingCheckResult = "配对无效：\(error.localizedDescription)"
        }
    }
}

private struct StatusPairingPage: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openURL) private var openURL
    @State private var showPairingPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(state.pairingDescription).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("导入配对记录文件") { showPairingPicker = true }
                    Button("删除") { state.removePairingFile() }
                }.buttonStyle(GlassButtonStyle())
                Button("下载 LocalDevVPN") {
                    if let url = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044") {
                        openURL(url)
                    }
                }.buttonStyle(GlassButtonStyle())
            }
            .padding()
            .navigationTitle("配对记录")
            .sheet(isPresented: $showPairingPicker) {
                DocumentPicker(contentTypes: [.propertyList]) { url in
                    showPairingPicker = false
                    Task { @MainActor in
                        state.importPairingFile(from: url)
                    }
                }
            }
        }
    }
}

private struct StatusHistoryPage: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.installHistory.isEmpty {
                    Text("还没有成功安装的记录。").foregroundStyle(.secondary).font(.caption)
                } else {
                    ForEach(state.installHistory, id: \.self) { uuid in
                        Text(uuid).font(.caption).textSelection(.enabled)
                    }
                }
            }
            .padding()
            .navigationTitle("已安装记录")
        }
    }
}

private struct StatusLogPage: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage).foregroundStyle(.red).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Text("安装日志（可长按复制）").font(.headline)
                Text(InstallLog.shared.tail(60))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .navigationTitle("应用失败异常诊断日志")
        }
    }
}
