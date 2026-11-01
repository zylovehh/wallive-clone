// StatusView.swift
// 状态：回环 VPN 通不通、配对记录有没有、装过哪些，一目了然。

import SwiftUI

struct StatusView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openURL) private var openURL
    @State private var showPairingPicker = false
    @State private var host = "10.7.0.1"
    @State private var portText = "62078"
    @State private var vpnResult = ""
    @State private var checking = false
    @State private var generating = false
    @State private var generateResult = ""

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
                Button("下载 LocalDevVPN") {
                    if let url = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044") {
                        openURL(url)
                    }
                }.buttonStyle(.bordered)
                Text("三步走：1. 先装 LocalDevVPN App；2. 打开它点 Connect；3. 回来点下面的“生成配对文件”。注意：中国区 App Store 没有这个 App，中国区新人得走侧载重签路线。")
                    .font(.caption)
                HStack {
                    Button("生成配对文件") {
                        Task { await generate() }
                    }.disabled(generating)
                    if generating { ProgressView() }
                }.buttonStyle(.bordered)
                if !generateResult.isEmpty { Text(generateResult).font(.caption) }

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
    /// 连通才跟本机配对，成功刷新状态，失败报真实原因。
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
        do {
            _ = try await PairingGenerator.generate(
                host: host, port: port, targetURL: state.pairingFileURL,
                progress: { text in Task { @MainActor in generateResult = text } })
            state.refreshPairingStatus()
            generateResult = "生成成功：配对文件已存好，可以去安装了。"
        } catch {
            generateResult = "生成失败：\(error.localizedDescription)"
        }
    }
}
