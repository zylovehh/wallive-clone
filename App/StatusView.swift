// StatusView.swift
// 状态：卡片点进二级页看详情（回环 VPN、配对记录、已安装记录、诊断日志），主页面只做菜单。

import SwiftUI
import UIKit

/// 高透液态玻璃按钮样式：iOS 26+ 系统玻璃，低版本回退半透明黑胶囊。
private struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background {
                if #available(iOS 26.0, *) {
                    Capsule().glassEffect(.regular.tint(.white.opacity(0.08)))
                } else {
                    Capsule().fill(.black.opacity(0.12))
                }
            }
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
    @State private var qqGradientX: CGFloat = 0

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
                                Text("进群领取视频教程")
                                    .font(.headline.weight(.light))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.cyan, .blue, .purple, .pink, .orange, .cyan, .blue, .purple, .pink, .orange, .cyan],
                                            startPoint: UnitPoint(x: qqGradientX, y: 0.5),
                                            endPoint: UnitPoint(x: qqGradientX + 2, y: 0.5)
                                        )
                                    )
                                    .animation(.linear(duration: 3).repeatForever(autoreverses: false), value: qqGradientX)
                                    .onAppear { qqGradientX = 1 }
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
                Text("内置 VPN").font(.headline)
                HStack {
                    Text(vpn.statusText).font(.caption)
                    Spacer()
                    if vpn.isConnected {
                        Button("关闭内置 VPN") { vpn.stop() }.buttonStyle(GlassButtonStyle())
                    } else {
                        Button("开启内置 VPN") { Task { await vpn.start() } }.buttonStyle(GlassButtonStyle())
                    }
                }
                if !vpn.lastError.isEmpty {
                    Text(vpn.lastError).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Text("第一次开启会弹系统提示，点“允许”。内置 VPN 只连本机（10.7.0.1），流量不出手机。开起来后，下面的检查和配对就能直接用，不用再装 LocalDevVPN。")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("回环 VPN 连通").font(.headline)
                HStack {
                    TextField("管家地址", text: $host).textFieldStyle(.roundedBorder)
                    TextField("端口", text: $portText).textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad).frame(width: 90)
                    Button("检查") {
                        Task { await check() }
                    }.buttonStyle(GlassButtonStyle())
                }
                if checking { ProgressView() }
                if !vpnResult.isEmpty {
                    Text(vpnResult).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                if generating || pairingChecking { ProgressView() }
                if pairingHost.running {
                    Button("取消") { pairingHost.softCancel() }.buttonStyle(GlassButtonStyle())
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
    /// 跳不过去就退到隐私与安全页，用户再点一下开发者模式。
    private func openDeveloperSettings() {
        if let url = URL(string: "App-Prefs:root=Privacy&path=DEVELOPER") {
            UIApplication.shared.open(url, options: [:]) { ok in
                if !ok, let fallback = URL(string: "App-Prefs:root=Privacy") {
                    UIApplication.shared.open(fallback)
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
