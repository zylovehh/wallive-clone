// StatusView.swift
// 状态：回环 VPN 通不通、配对记录有没有、装过哪些，一目了然。

import SwiftUI

struct StatusView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openURL) private var openURL
    @ObservedObject private var pairingHost = PairingHost.shared
    @State private var showPairingPicker = false
    @State private var host = "10.7.0.1"
    @State private var portText = "62078"
    @State private var vpnResult = ""
    @State private var checking = false
    @State private var generating = false
    @State private var generateResult = ""
    @State private var pairingCheckResult = ""
    @State private var pairingChecking = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("回环 VPN 连通").font(.headline)
                HStack {
                    TextField("管家地址", text: $host).textFieldStyle(.roundedBorder)
                    TextField("端口", text: $portText).textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad).frame(width: 90)
                    Button("检查") {
                        Task { await check() }
                    }.buttonStyle(.bordered)
                }
                if checking { ProgressView() }
                if !vpnResult.isEmpty { Text(vpnResult).font(.caption) }

                Text("配对记录").font(.headline)
                Text(state.pairingDescription).font(.caption)
                HStack {
                    Button("导入配对记录文件") { showPairingPicker = true }
                    Button("删除") { state.removePairingFile() }
                }.buttonStyle(.bordered)
                HStack {
                    Button("检查配对状态") {
                        Task { await checkPairing() }
                    }.disabled(pairingChecking)
                    if pairingChecking { ProgressView() }
                }.buttonStyle(.bordered)
                if !pairingCheckResult.isEmpty {
                    Text(pairingCheckResult).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Button("下载 LocalDevVPN") {
                    if let url = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044") {
                        openURL(url)
                    }
                }.buttonStyle(.bordered)
                Text("三步走：1. 先装 LocalDevVPN App；2. 打开它点 Connect；3. 回来点下面的“生成配对文件”，等界面出现 6 位 PIN 后，去“设置 › 隐私与安全 › 开发者模式 › 与壁纸安装器配对”输 PIN。注意：中国区 App Store 没有这个 App，中国区新人得走侧载重签路线。")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Button("生成配对文件") {
                        Task { await generate() }
                    }.disabled(generating)
                    if generating { ProgressView() }
                    if pairingHost.running {
                        Button("取消") { pairingHost.softCancel() }
                    }
                }.buttonStyle(.bordered)
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

                Text("已安装（本机记录）").font(.headline)
                if state.installHistory.isEmpty {
                    Text("还没有成功安装的记录。").foregroundStyle(.secondary).font(.caption)
                } else {
                    ForEach(state.installHistory, id: \.self) { uuid in
                        Text(uuid).font(.caption)
                    }
                }

                Text("说明：本 App 不含广告、不含会员与解锁逻辑；配对记录文件只存在 App 沙盒内，不会发给任何人。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding()
            .navigationTitle("状态")
            .onAppear { state.refreshPairingStatus() }
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

    private func check() async {
        checking = true
        defer { checking = false }
        let port = UInt16(portText) ?? 62078
        let ok = await state.checkVPN(host: host, port: port)
        vpnResult = ok ? "通：管家地址可达。" : "不通：请先确认回环 VPN 已安装并连接。"
    }

    /// 生成配对文件：先复用检查按钮的 VPN 连通逻辑，没连 VPN 就不配对；
    /// 连通才启动本机配对主机，界面出现 6 位 PIN 后用户去设置里输 PIN，
    /// 成功刷新状态，失败报真实原因。
    private func generate() async {
        guard !generating else { return }
        generating = true
        defer { generating = false }
        generateResult = "正在检查回环 VPN…"
        let port = UInt16(portText) ?? 62078
        let vpnOK = await state.checkVPN(host: host, port: port)
        guard vpnOK else {
            generateResult = "没连上回环 VPN：请先在设置里连上 LocalDevVPN，再点生成。"
            return
        }
        generateResult = "正在启动本机配对…随后界面会出现 6 位 PIN。"
        do {
            _ = try await pairingHost.startAndWait()
            state.refreshPairingStatus()
            generateResult = "生成成功：配对文件已存好，可以去安装了。"
        } catch {
            generateResult = "生成失败：\(error.localizedDescription)"
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
