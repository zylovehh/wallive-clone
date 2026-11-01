// InstallView.swift
// 安装：当前包 + 配对记录 → 经特权通道写盘并登记，显示进度与结果。

import SwiftUI

struct InstallView: View {
    @EnvironmentObject private var state: AppState
    @State private var host = "10.7.0.1"
    @State private var installing = false
    @State private var result = ""
    @State private var installLog = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let info = state.packageInfo {
                    Text("待安装：\(info.descriptorUUID)").font(.caption)
                    Text(info.hasRenderingConfiguration ? "含深景开关" : "不含深景开关").font(.caption)
                } else {
                    Text("还没选包：先去“导入”选本地包。")
                        .foregroundStyle(.secondary)
                }
                Text("配对记录：\(state.pairingDescription)").font(.caption)
                    .onAppear { state.refreshPairingStatus() }
                HStack {
                    TextField("管家地址", text: $host).textFieldStyle(.roundedBorder)
                }
                Button("安装到锁屏") {
                    Task { await runInstall() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.packageData == nil || !state.pairingLoaded || installing)
                if installing { ProgressView("正在安装…") }
                if !result.isEmpty { Text(result).font(.caption) }
                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage).foregroundStyle(.red).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !installLog.isEmpty {
                    Text("安装日志（可长按复制）").font(.headline)
                    ScrollView {
                        Text(installLog)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("安装")
        }
    }

    private func runInstall() async {
        installing = true
        result = ""
        installLog = ""
        defer { installing = false }
        if let uuid = await state.install(host: host) {
            result = "安装完成，描述符 UUID：\(uuid)。请到锁屏查看。"
        } else if state.statusMessage.isEmpty {
            result = "安装未完成：请确认已选包、已生成配对记录、回环 VPN 已连接。"
        }
        installLog = InstallLog.shared.tail(60)
    }
}
