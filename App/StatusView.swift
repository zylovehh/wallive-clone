// StatusView.swift
// 状态：卡片点进二级页看详情（回环 VPN、配对记录、已安装记录、诊断日志），主页面只做菜单。

import SwiftUI
import UIKit

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
                    // 作者入口：圆形头像 + 名字，点进去是作者页（抖音主页）。
                    NavigationLink(destination: AuthorPage()) {
                        HStack {
                            Image("AuthorAvatar")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text("作者").font(.headline)
                                Text("王炸奓").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }
                        .padding()
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
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
    @State private var probeRunning = false
    @State private var probeProgress = ""
    @State private var probeResult = ""
    @State private var probeTask: Task<Void, Never>?
    @State private var springboardRunning = false
    @State private var springboardResult = ""
    @State private var appGroupResult = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage).foregroundStyle(.red).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // 探针拿表：不装壁纸，单独把那张表拿下来存好。
                // 探针 2 那次拿到的表只存在内存里、没存盘，丢了；这个按钮就是补
                // 这个缺：点一下，单独跑一遍探针 3 那条拷回通道拿表、校验、存成
                // 已存表（merged.sqlite3），以后装就有兜底了。
                // 旧的探针按钮（探针 3、列出行、还原测试）已拿掉，正式版备份还原
                // 走导入页的安装按钮（BackupInstallFlow），拿表、插行、写回那套
                // 引擎还在 RestoreTest.swift 里。
                VStack(alignment: .leading, spacing: 12) {
                    Text("探针拿表").font(.headline)
                    Text("不装壁纸，单独把那张表拿下来存好（以后装就有兜底了）。走探针 3 那条拷回通道，30 秒超时。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button {
                            runProbeFetch()
                        } label: {
                            Text("探针拿表").frame(maxWidth: .infinity)
                        }
                        .disabled(probeRunning || !state.hasPairingFile)
                        if probeRunning {
                            Button {
                                stopProbeFetch()
                            } label: {
                                Text("停止").frame(maxWidth: .infinity)
                            }
                        }
                    }.buttonStyle(GlassButtonStyle())
                    if !state.hasPairingFile {
                        Text("没有配对记录文件：先去配对记录页导入一个。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if probeRunning {
                        ProgressView().frame(maxWidth: .infinity, alignment: .center)
                    }
                    if probeRunning && !probeProgress.isEmpty {
                        Text(probeProgress).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !probeResult.isEmpty {
                        Text(probeResult).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                // SpringBoard 重启测试：DVT 杀 SpringBoard 进程、等桌面重起重读，
                // 跟换语言时系统重启桌面一个道理（只重启桌面、不重启手机）。
                // 27.2 上 PosterBoard 杀掉后回不来，表对了也不回来，就测桌面重启
                // 这条路能不能让它重读新表。点一下屏幕会黑几秒再回来；黑屏超
                // 过 1 分钟没回来，长按电源键强制重启。App 可能在桌面重启时被
                // 系统一起杀掉，那时这行字看不到，直接看屏幕就行，日志在下面
                // 安装日志里（落盘了），重开 App 还能看。
                VStack(alignment: .leading, spacing: 12) {
                    Text("SpringBoard 重启测试").font(.headline)
                    Text("只重启桌面、不重启手机。点一下屏幕会黑几秒，桌面回来就是成了；黑屏超过 1 分钟没回来，长按电源键强制重启。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        runSpringboardRespring()
                    } label: {
                        Text("重启 SpringBoard（测试）").frame(maxWidth: .infinity)
                    }
                    .disabled(springboardRunning || !state.hasPairingFile)
                    if !state.hasPairingFile {
                        Text("没有配对记录文件：先去配对记录页导入一个。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if springboardRunning {
                        ProgressView().frame(maxWidth: .infinity, alignment: .center)
                    }
                    if !springboardResult.isEmpty {
                        Text(springboardResult).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                // App Group 测试：27.2 新路子（worse_query）要一个普通 App Group
                // 才能进 SystemGroup。这卡只测一件事：全能签签出来的包里到底有
                // 没有 App Group 权限。点一下，调系统公开接口拿 App Group 容器
                // 路径；拿到了就是通了，拿不到（nil）就是签名里没这个权限，27.2
                // 那条路走不通。不用配对，不用联网，点完结果写进下面安装日志。
                VStack(alignment: .leading, spacing: 12) {
                    Text("App Group 测试").font(.headline)
                    Text("测全能签签出来的包里有没有 App Group 权限（27.2 新路子要用到）。不用配对，点一下就行，结果会写进下面安装日志。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        runAppGroupTest()
                    } label: {
                        Text("测试 App Group").frame(maxWidth: .infinity)
                    }
                    if !appGroupResult.isEmpty {
                        Text(appGroupResult).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
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

    /// 探针拿表：后台跑 RestoreTest.probeFetchTable（同步阻塞，放后台线程）。
    /// 停止按钮取消的是上层 Task，后台那路看不到取消标记，所以用取消盒中转：
    /// 上层取消时轮询立刻抛、关进度，不等后台回来；后台在下一步边界查到取消
    /// 标记就自己停。跟 BackupInstallFlow 那套一样的接法。
    private func runProbeFetch() {
        guard !probeRunning else { return }
        guard state.hasPairingFile else {
            probeResult = "没有配对记录文件：先去配对记录页导入一个。"
            return
        }
        probeRunning = true
        probeProgress = "正在拿表…"
        probeResult = ""
        let pairingPath = state.pairingFileURL.path
        probeTask = Task {
            let cancelBox = ProbeFetchCancelBox()
            let outcomeBox = ProbeFetchOutcomeBox()
            _ = Task.detached(priority: .userInitiated) {
                let outcome = RestoreTest.probeFetchTable(
                    pairingPath: pairingPath,
                    onProgress: { text, _ in
                        Task { @MainActor in self.probeProgress = text }
                    },
                    isCancelled: { cancelBox.isCancelled })
                outcomeBox.finish(outcome)
            }
            do {
                let outcome = try await withTaskCancellationHandler {
                    try await waitForProbeOutcome(outcomeBox)
                } onCancel: {
                    cancelBox.cancel()
                }
                await MainActor.run {
                    probeResult = outcome.summary
                    probeProgress = ""
                    probeRunning = false
                }
            } catch {
                cancelBox.cancel()
                await MainActor.run {
                    probeResult = "已停止。"
                    probeProgress = ""
                    probeRunning = false
                }
            }
        }
    }

    private func stopProbeFetch() {
        probeTask?.cancel()
    }

    /// App Group 测试：调系统公开接口拿 App Group 容器路径。同步调用，马上
    /// 出结果。拿到了就是签名里有 App Group 权限（27.2 新路子能走）；返回
    /// nil 就是签名里没这个权限（全能签没加上），27.2 那条路走不通。结果
    /// 同时写进安装日志，重启 App 还能看。
    private func runAppGroupTest() {
        let groupID = "group.com.usc.1787713824"
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            appGroupResult = "通了：App Group 容器路径 \(url.path)"
            InstallLog.shared.append("appgroup: OK \(url.path)")
        } else {
            appGroupResult = "没通：拿不到 App Group 容器路径（nil），签名里没有 App Group 权限。"
            InstallLog.shared.append("appgroup: FAILED nil（签名里没有 App Group 权限）")
        }
    }

    /// SpringBoard 重启测试：后台调 RestoreTest.springboardRespring。
    /// App 可能在桌面重启时被系统一起杀掉，那时结果回不来、这行字也
    /// 看不到，用户直接看屏幕：黑屏后桌面回来就是成了；黑屏超过 1 分钟
    /// 没回来，长按电源键强制重启。日志在 InstallLog 里，重启 App 还能看。
    private func runSpringboardRespring() {
        guard !springboardRunning else { return }
        guard state.hasPairingFile else {
            springboardResult = "没有配对记录文件：先去配对记录页导入一个。"
            return
        }
        springboardRunning = true
        springboardResult = "已发送重启指令，桌面正在重启，观察屏幕…"
        let pairingPath = state.pairingFileURL.path
        Task {
            let outcome = await RestoreTest.springboardRespring(pairingPath: pairingPath)
            await MainActor.run {
                springboardRunning = false
                if let confirmed = outcome["confirmed"] as? Bool, confirmed {
                    springboardResult = "桌面已重启回来（旧进程 \(outcome["old_pid"] ?? "?") → 新进程 \(outcome["new_pid"] ?? "?")），去图库看壁纸在不在。"
                } else if let error = outcome["error"] as? String {
                    springboardResult = "没确认：\(error)"
                } else {
                    springboardResult = "没确认：桌面没在 30 秒内回来，观察屏幕；黑屏超过 1 分钟没回来，长按电源键强制重启。"
                }
            }
        }
    }

    /// 等后台 probeFetchTable 写结果盒：先看盒里有没有，没有再查取消、
    /// 睡 0.2 秒再看；上层 Task 取消（点了停止）就立刻抛，不等后台回来。
    private func waitForProbeOutcome(_ box: ProbeFetchOutcomeBox) async throws -> RestoreTest.ProbeFetchOutcome {
        while true {
            if let outcome = box.outcome { return outcome }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}

/// 探针拿表的取消标记盒：上层 Task 取消时置位，后台阻塞调用在步骤之间查。
private final class ProbeFetchCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = true
    }
}

/// 探针拿表的结果盒：后台线程写完、轮询循环读。
private final class ProbeFetchOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcome: RestoreTest.ProbeFetchOutcome?
    var outcome: RestoreTest.ProbeFetchOutcome? {
        lock.lock(); defer { lock.unlock() }
        return _outcome
    }
    func finish(_ outcome: RestoreTest.ProbeFetchOutcome) {
        lock.lock(); defer { lock.unlock() }
        _outcome = outcome
    }
}

/// 作者页：大圆头像 + 名字王炸奓 + 蓝色“抖音主页”按钮，点按钮跳用户自己的抖音主页。
/// 二维码那块用户没给图，先不做。
private struct AuthorPage: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image("AuthorAvatar")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 140, height: 140)
                    .clipShape(Circle())
                Text("王炸奓")
                    .font(.title2.bold())
                Button {
                    if let url = URL(string: "https://v.douyin.com/cXKCgf4lvc8/") {
                        openURL(url)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note")
                        Text("抖音主页")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding()
            .navigationTitle("作者")
        }
    }
}
