// ImportView.swift
// 包导入：选本地 .tendies/.wallive，检查结构，显示三层与深景标记。

import Foundation
import SwiftUI

struct ImportView: View {
    @EnvironmentObject private var state: AppState
    @State private var showPicker = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Button("选择 .tendies / .wallive 文件") { showPicker = true }
                    .buttonStyle(.borderedProminent)
                if let info = state.packageInfo {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("描述符 UUID：\(info.descriptorUUID)").font(.caption)
                        Text("背景：\(info.backgroundFile ?? "无")").font(.caption)
                        Text("漂浮：\(info.floatingFile ?? "无")").font(.caption)
                        Text("前景：\(info.foregroundFile ?? "无")").font(.caption)
                        Text(info.hasRenderingConfiguration ? "已有深景开关" : "无深景开关")
                        Text(info.floatingHasClownfishPrefix ? "漂浮层已有 Clownfish 前缀" : "漂浮层无 Clownfish 前缀")
                    }
                    HStack {
                        Button("制作深景包") { state.selectedTab = 3 }
                        Button("去安装") { state.selectedTab = 2 }
                    }.buttonStyle(.bordered)
                } else {
                    Text("还没选包。WALLIVE1 加密包会自动解密后再检查。")
                        .foregroundStyle(.secondary)
                }
                if let err = state.packageError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
                if !message.isEmpty {
                    Text(message).foregroundStyle(.red).font(.caption)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("导入")
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
}
