// StatusView.swift
// 状态：卡片点进二级页看详情（回环 VPN、配对记录、已安装记录、诊断日志），主页面只做菜单。

import SwiftUI
import UIKit
import AirliftFFI
import SQLite3

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
    /// 侧载 App 能用系统设置内部链接（不上 App Store，不用过审）。
    /// 两个教训：open 必须在主线程调（后台线程调了没反应）；只试一个链接不够，
    /// 按顺序挨个试，哪个通了就停，全不通才告诉用户手动去。
    /// 27.2 实测教训：iOS 27 改了设置内部链接，旧 prefs 写法在 27.2 上落到
    /// 设置 → App 列表，到不了开发者模式；新写法 settings-navigation:// 打头，
    /// 旧写法留着当后备。25 号真机验：Privacy 根名是错的，只跳到设置主页；
    /// 26.2 链接表里隐私与安全的根是 PrivacyAndSecurity，且表里根本没有
    /// “开发者模式”这一项，所以只跳隐私与安全页、不带子路径，落到那页滑
    /// 到底点开发者模式。DEVELOPER 是开完之后才出现的顶层“开发者”栏目，
    /// 在隐私页下没有这一项。
    /// 26 号真机验：光跳隐私与安全页也落到设置主页（27.0.1 上这条也不通）；
    /// Safari 里粘 settings-navigation 链接会报“网址无效”，Safari 认不出这
    /// 种系统链接，不能用 Safari 试，只能从 App 里调 open 来验。
    /// 27 号改法：按锁定模式那栏的写法类推（26.2 表里锁定模式是
    /// PrivacyAndSecurity#LOCKDOWN_MODE#LOCKDOWN_MODE，开发者模式就在它下
    /// 面同一栏），先试锚点式 #DEVELOPER_MODE#DEVELOPER_MODE，再试子路径式
    /// /DEVELOPER_MODE，最后才是光跳隐私与安全页。两条都不行就说明 27 上没
    /// 这条深链，不再为跳转单独编版。
    /// open 回 true 只代表设置打开了，不代表落到了那栏，所以打开成功后的指引
    /// 写成落地无关的版本：不管停在哪一页，都从设置主页找隐私与安全。
    private func openDeveloperSettings() {
        let candidates = [
            "settings-navigation://com.apple.Settings.PrivacyAndSecurity#DEVELOPER_MODE#DEVELOPER_MODE",
            "settings-navigation://com.apple.Settings.PrivacyAndSecurity/DEVELOPER_MODE",
            "settings-navigation://com.apple.Settings.PrivacyAndSecurity",
            "App-Prefs:root=Privacy&path=DEVELOPER_MODE",
            "prefs:root=Privacy&path=DEVELOPER_MODE",
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
            // 候选全不通，最后兜底：打开本 App 在设置里的页面，至少把设置打开。
            if let fallback = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(fallback, options: [:]) { ok in
                    Task { @MainActor in
                        self.generateResult = ok
                            ? "已打开设置：去隐私与安全，滑到最底点开发者模式，再点与壁纸安装器配对输 PIN。停在哪一页都没关系，从设置主页找隐私与安全就行。"
                            : "没跳过去：请手动去“设置 → 隐私与安全 → 开发者模式”，点“与壁纸安装器配对”输 PIN。"
                    }
                }
            } else {
                generateResult = "没跳过去：请手动去“设置 → 隐私与安全 → 开发者模式”，点“与壁纸安装器配对”输 PIN。"
            }
            return
        }
        UIApplication.shared.open(url, options: [:]) { ok in
            if ok {
                // 设置打开了，但系统不一定落到开发者模式那栏（27.2 上旧写法会落到 App 列表）。
                // 留一句指引，用户按着点就不会走错。
                Task { @MainActor in
                    self.generateResult = "已打开设置：去隐私与安全，滑到最底点开发者模式，再点与壁纸安装器配对输 PIN。停在哪一页都没关系，从设置主页找隐私与安全就行。"
                }
            } else {
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
    @State private var probing = false
    @State private var probeResult = ""
    @State private var probing2 = false
    @State private var probe2Result = ""
    @State private var probing3 = false
    @State private var probe3Result = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage).foregroundStyle(.red).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // 探针：只读读一次 PosterBoard 容器（HouseArrest vend_container），
                // 看容器能不能打开、表在不在、store 版本号是多少。
                // 只读：不写任何文件、不改任何表、不触发安装、不触发备份、不重启。
                // 失败也写清楚原文（比如 InstallationLookupFailed），不写含糊话。
                Text("PosterBoard 容器探针（只读）").font(.headline)
                Text("点一下读一次：配对 + 隧道通不通、容器能不能打开、里面有没有那张表、store 版本号是多少。只读，不写东西。完整结果写进下面日志框，长按可复制。")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Button("探针：读 PosterBoard 容器") {
                        Task { await runProbe() }
                    }.disabled(probing)
                    if probing { ProgressView() }
                }.buttonStyle(.bordered)
                if !probeResult.isEmpty {
                    Text(probeResult).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // 探针 2：只读试 AirTraffic 拷回通道能不能读到 PosterBoard
                // 那张现成的表。61 和 62 两个版本都试，成了再试 -wal。
                // 只验文件头 + 大小 + SHA-256，不存表；不写 PosterBoard、
                // 不改表、不动备份/安装逻辑。
                Text("PosterBoard 拷回探针 2（只读）").font(.headline)
                Text("点一下试一次：AirTraffic 能不能把那张表从 PosterBoard 容器里拷回来。61、62 各试一次，成了再试 -wal。只读，不存表。完整结果写进下面日志框，长按可复制。")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Button("探针 2：拷回 PosterBoard 的表") {
                        Task { await runProbe2() }
                    }.disabled(probing2)
                    if probing2 { ProgressView() }
                }.buttonStyle(.bordered)
                if !probe2Result.isEmpty {
                    Text(probe2Result).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // 探针 3：把表真正存下来。走探针 2 同一条 AirTraffic 拷回
                // 通道，只试 v61（真机已证实是 61），DB 和 -wal 存进安装器
                // 自己的 Documents/posterboard-table，文件名带时间、不覆盖；
                // 存完在 Swift 侧用系统 SQLite3 把 -wal 合进一份副本再验。
                // 只读 PosterBoard，不写它；Books.plist 照探针 2 那样还原。
                Text("PosterBoard 存表探针 3（只读 PosterBoard）").font(.headline)
                Text("点一下试一次：把那张表拷回来存进本 App 的 Documents/posterboard-table，只试 v61，DB 和 -wal 都存，存完合库验一下能不能打开、poster 有几行。完整结果写进下面日志框，长按可复制。")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Button("探针3：存下 PosterBoard 的表") {
                        Task { await runProbe3() }
                    }.disabled(probing3)
                    if probing3 { ProgressView() }
                }.buttonStyle(.bordered)
                if !probe3Result.isEmpty {
                    Text(probe3Result).font(.caption)
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

    /// 只读探针：走配对 + 隧道调一次 al_probe_posterboard_container。
    /// vend 只调一次（Rust 侧单次调用，不重试）；结果写进安装日志框，
    /// 本页只留一行结论。FFI 会阻塞，放后台线程跑。
    private func runProbe() async {
        guard !probing else { return }
        probing = true
        defer { probing = false }
        guard state.hasPairingFile else {
            probeResult = "探针没跑：没有配对记录文件，先在配对记录页生成或导入一个。"
            return
        }
        probeResult = "正在读 PosterBoard 容器…"
        let pairingPath = state.pairingFileURL.path
        let (rc, json, error) = await Task.detached(priority: .userInitiated) {
            "10.7.0.1".withCString { _ = al_set_target_host($0) }
            var outJson: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc = pairingPath.withCString { pairC in
                al_probe_posterboard_container(pairC, airliftLogCallback, nil, &outJson, &outError)
            }
            var json: String? = nil
            var error: String? = nil
            if let p = outJson { json = String(cString: p); al_string_free(p) }
            if let p = outError { error = String(cString: p); al_string_free(p) }
            return (rc, json, error)
        }.value
        if rc == 0, let json {
            probeResult = Self.probeSummary(json: json)
        } else {
            // 通道失败：写设备报的原文，不写含糊话。
            let detail = error ?? "未知错误"
            probeResult = "探针失败（通道不通）：\(detail)"
            InstallLog.shared.append("probe: FAILED \(detail)")
        }
    }

    /// 探针 JSON 宽松解析成一行中文结论；解析不出就把 JSON 原文贴出来。
    private static func probeSummary(json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            InstallLog.shared.append("probe: json=\(json)")
            return "探针跑完了，但结果解析不出来，原文已写进日志框：\(json)"
        }
        let versions = (obj["store_versions"] as? [String]) ?? []
        let versionText = versions.isEmpty ? "没列出版本号" : "store 版本：\(versions.joined(separator: "、"))"
        let dbExists = (obj["db_exists"] as? Bool) ?? false
        let dbSize = (obj["db_size"] as? NSNumber)?.intValue
        let isSqlite = (obj["db_is_sqlite"] as? Bool) ?? false
        let summary: String
        if dbExists {
            summary = "探针成功：容器能打开，\(versionText)，表找到了，大小 \(dbSize.map { "\($0) 字节" } ?? "未知")，SQLite 文件头\(isSqlite ? "对得上" : "对不上")。完整结果见下面日志框。"
        } else {
            summary = "探针跑完了：容器能打开，\(versionText)，但没找到那张表。完整结果见下面日志框。"
        }
        InstallLog.shared.append("probe: \(summary)")
        return summary
    }

    /// 只读探针 2：走配对 + 隧道调一次 al_probe_posterboard_export。
    /// 61、62 各试一次，成了再试那一版的 -wal；只在内存里验文件头，
    /// 不存盘。结果写进安装日志框，本页只留一行结论。FFI 会阻塞，
    /// 放后台线程跑。
    private func runProbe2() async {
        guard !probing2 else { return }
        probing2 = true
        defer { probing2 = false }
        guard state.hasPairingFile else {
            probe2Result = "探针 2 没跑：没有配对记录文件，先在配对记录页生成或导入一个。"
            return
        }
        probe2Result = "正在拷回 PosterBoard 的表…"
        let pairingPath = state.pairingFileURL.path
        let (rc, json, error) = await Task.detached(priority: .userInitiated) {
            "10.7.0.1".withCString { _ = al_set_target_host($0) }
            var outJson: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc = pairingPath.withCString { pairC in
                al_probe_posterboard_export(pairC, airliftLogCallback, nil, &outJson, &outError)
            }
            var json: String? = nil
            var error: String? = nil
            if let p = outJson { json = String(cString: p); al_string_free(p) }
            if let p = outError { error = String(cString: p); al_string_free(p) }
            return (rc, json, error)
        }.value
        if rc == 0, let json {
            probe2Result = Self.probe2Summary(json: json)
        } else {
            // 通道失败：写设备报的原文，不写含糊话。
            let detail = error ?? "未知错误"
            probe2Result = "探针 2 失败（通道不通）：\(detail)"
            InstallLog.shared.append("probe2: FAILED \(detail)")
        }
    }

    /// 探针 2 JSON 宽松解析成一行中文结论；解析不出就把 JSON 原文贴出来。
    private static func probe2Summary(json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            InstallLog.shared.append("probe2: json=\(json)")
            return "探针 2 跑完了，但结果解析不出来，原文已写进日志框：\(json)"
        }
        let success = (obj["success"] as? Bool) ?? false
        let dbVersion = (obj["db_version"] as? String) ?? "未知"
        let dbSize = (obj["db_size"] as? NSNumber)?.intValue
        let dbIsSqlite = (obj["db_is_sqlite"] as? Bool) ?? false
        let walOk = (obj["wal_is_wal"] as? Bool) ?? false
        let summary: String
        if success && dbIsSqlite {
            summary = "探针 2 成功：表拷回来了，store 版本 \(dbVersion)，大小 \(dbSize.map { "\($0) 字节" } ?? "未知")，SQLite 文件头对得上，-wal \(walOk ? "也拷回来了" : "没拷回来")。完整结果见下面日志框。"
        } else {
            summary = "探针 2 跑完了：AirTraffic 拷回没拿到可用的表（61、62 都没成）。完整结果见下面日志框。"
        }
        InstallLog.shared.append("probe2: \(summary)")
        return summary
    }

    /// 探针 3：走配对 + 隧道调一次 al_probe_posterboard_save。
    /// 只试 v61（探针 2 在真机上证实了 61），DB 和 -wal 存进本 App
    /// 的 Documents/posterboard-table，文件名带时间、不覆盖旧的；
    /// 存完在后台线程合库验库。只读 PosterBoard，不写它。FFI 会
    /// 阻塞，放后台线程跑；合库也在后台跑。
    private func runProbe3() async {
        guard !probing3 else { return }
        probing3 = true
        defer { probing3 = false }
        guard state.hasPairingFile else {
            probe3Result = "探针 3 没跑：没有配对记录文件，先在配对记录页生成或导入一个。"
            return
        }
        probe3Result = "正在拷回并存下 PosterBoard 的表…"
        let pairingPath = state.pairingFileURL.path
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destDir = docs.appendingPathComponent("posterboard-table").path
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmm"
            return f.string(from: Date())
        }()
        let (rc, json, error) = await Task.detached(priority: .userInitiated) {
            "10.7.0.1".withCString { _ = al_set_target_host($0) }
            var outJson: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc = pairingPath.withCString { pairC in
                destDir.withCString { destC in
                    stamp.withCString { stampC in
                        al_probe_posterboard_save(pairC, destC, stampC, airliftLogCallback, nil, &outJson, &outError)
                    }
                }
            }
            var json: String? = nil
            var error: String? = nil
            if let p = outJson { json = String(cString: p); al_string_free(p) }
            if let p = outError { error = String(cString: p); al_string_free(p) }
            return (rc, json, error)
        }.value
        if rc == 0, let json {
            // 合库验库是阻塞的 sqlite 活，也放后台线程跑。
            probe3Result = await Task.detached(priority: .userInitiated) {
                Self.probe3Summary(json: json)
            }.value
        } else {
            // 通道失败：写设备报的原文，不写含糊话。
            let detail = error ?? "未知错误"
            probe3Result = "探针 3 失败（通道不通）：\(detail)"
            InstallLog.shared.append("probe3: FAILED \(detail)")
        }
    }

    /// 探针 3 JSON 宽松解析成一行中文结论；表存下来后先合库验库，
    /// 再拼结论。解析不出就把 JSON 原文贴出来。
    private static func probe3Summary(json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            InstallLog.shared.append("probe3: json=\(json)")
            return "探针 3 跑完了，但结果解析不出来，原文已写进日志框：\(json)"
        }
        let savedOk = (obj["saved_db_ok"] as? Bool) ?? false
        let savedPath = (obj["saved_db_path"] as? String) ?? ""
        let savedSize = (obj["saved_db_size"] as? NSNumber)?.intValue
        let walOk = (obj["saved_wal_ok"] as? Bool) ?? false
        guard (obj["success"] as? Bool) ?? false, savedOk else {
            let summary = "探针 3 跑完了：表没存下来（v61 没拷回来，或存盘校验没过）。完整结果见下面日志框。"
            InstallLog.shared.append("probe3: \(summary) json=\(json)")
            return summary
        }
        // 合 -wal、验库：只动刚存的副本，原文件不动。
        let merge = probe3Merge(dbPath: savedPath, walPath: obj["saved_wal_path"] as? String)
        var mergedObj = obj
        mergedObj["merge"] = merge
        if let mergedData = try? JSONSerialization.data(withJSONObject: mergedObj, options: [.sortedKeys]),
           let mergedJson = String(data: mergedData, encoding: .utf8) {
            InstallLog.shared.append("probe3: json=\(mergedJson)")
        } else {
            InstallLog.shared.append("probe3: json=\(json)")
        }
        let mergedOk = (merge["merged_ok"] as? Bool) ?? false
        let tables = (merge["tables"] as? [String]) ?? []
        let posterRows = (merge["poster_rows"] as? NSNumber)?.intValue
        let posterTable = (merge["poster_table"] as? String) ?? ""
        let integrity = (merge["integrity_check"] as? String) ?? ""
        let checkpointOk = (merge["checkpoint_ok"] as? Bool) ?? false
        if mergedOk {
            let sizeText = savedSize.map { "\($0) 字节" } ?? "大小未知"
            let tableText = tables.isEmpty ? "没列出来" : tables.joined(separator: "、")
            let posterText = posterTable.isEmpty
                ? "没找到名字里带 poster 的表"
                : "\(posterTable) 有 \(posterRows.map { "\($0)" } ?? "未知") 行"
            return "探针 3 成功：表存下来了，\(savedPath)，\(sizeText)，-wal \(walOk ? "也存下来了" : "没存下来")；合库 \(checkpointOk ? "过了" : "没过")，integrity_check：\(integrity.isEmpty ? "没读到" : integrity)，表：\(tableText)，poster：\(posterText)。完整结果见下面日志框。"
        }
        let err = (merge["error"] as? String) ?? "未知错误"
        return "探针 3：表存下来了（\(savedPath)，\(savedSize.map { "\($0) 字节" } ?? "大小未知")），但合库验库没过：\(err)。完整结果见下面日志框。"
    }

    /// 把探针 3 存下来的表复制一份成 merged.sqlite3（原文件不动），
    /// 把同名 -wal 拷到它旁边，打开后执行一次 checkpoint 把 -wal 合进
    /// 主库，再读表名列表、做 integrity_check、数 poster 那张表有几行。
    /// 表名按实际查到的写，poster 那张按名字里含 "poster" 找，找不到
    /// 就如实报 null，不硬编。返回字典，调用方拼进日志 JSON 和一行结论。
    private static func probe3Merge(dbPath: String, walPath: String?) -> [String: Any] {
        let fm = FileManager.default
        let dir = (dbPath as NSString).deletingLastPathComponent
        let merged = (dir as NSString).appendingPathComponent("merged.sqlite3")
        try? fm.removeItem(atPath: merged)
        try? fm.removeItem(atPath: merged + "-wal")
        try? fm.removeItem(atPath: merged + "-shm")
        do {
            try fm.copyItem(atPath: dbPath, toPath: merged)
        } catch {
            return ["merged_ok": false, "error": "复制 DB 到 merged.sqlite3 失败：\(error.localizedDescription)"]
        }
        if let wal = walPath, fm.fileExists(atPath: wal) {
            try? fm.copyItem(atPath: wal, toPath: merged + "-wal")
        }
        var db: OpaquePointer?
        let openRc = merged.withCString { sqlite3_open($0, &db) }
        guard openRc == SQLITE_OK, let db = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "打不开 merged.sqlite3"
            if let db = db { sqlite3_close(db) }
            return ["merged_ok": false, "error": msg]
        }
        defer { sqlite3_close(db) }
        var out: [String: Any] = ["merged_path": merged]
        // checkpoint：把 -wal 合进主库并截断。
        let ckRc = "PRAGMA wal_checkpoint(TRUNCATE);".withCString {
            sqlite3_exec(db, $0, nil, nil, nil)
        }
        out["checkpoint_ok"] = (ckRc == SQLITE_OK)
        // 表名列表（按实际查到的写）。
        var tables: [String] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;", -1, &stmt, nil) == SQLITE_OK,
           let stmt = stmt {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let t = sqlite3_column_text(stmt, 0) {
                    tables.append(String(cString: t))
                }
            }
            sqlite3_finalize(stmt)
        }
        out["tables"] = tables
        // integrity_check：第一行是 "ok" 才算库没坏。
        var integrity = ""
        if sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK,
           let stmt = stmt {
            if sqlite3_step(stmt) == SQLITE_ROW, let t = sqlite3_column_text(stmt, 0) {
                integrity = String(cString: t)
            }
            sqlite3_finalize(stmt)
        }
        out["integrity_check"] = integrity
        // poster 行数：找名字里含 "poster" 的第一张表，找不到就留空。
        if let posterTable = tables.first(where: { $0.lowercased().contains("poster") }) {
            out["poster_table"] = posterTable
            let sql = "SELECT COUNT(*) FROM \"\(posterTable.replacingOccurrences(of: "\"", with: "\"\""))\";"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
               let stmt = stmt {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    out["poster_rows"] = Int(sqlite3_column_int64(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
        }
        out["merged_ok"] = true
        if let size = (try? fm.attributesOfItem(atPath: merged)[.size] as? NSNumber)?.intValue {
            out["merged_size"] = size
        }
        return out
    }
}
