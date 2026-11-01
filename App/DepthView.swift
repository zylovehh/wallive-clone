// DepthView.swift
// 深景包制作：给标准包加渲染配置开关 + Clownfish 前缀（装机验证过的配方），
// 生成后可分享、可设为当前包再去安装。

import Foundation
import SwiftUI

struct DepthView: View {
    @EnvironmentObject private var state: AppState
    @State private var depthData: Data?
    @State private var depthInfo: TendiesPackageInfo?
    @State private var shareURL: URL?
    @State private var message = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if state.packageData == nil {
                    Text("还没选包：先去“导入”选本地包。")
                        .foregroundStyle(.secondary)
                } else {
                    Button("生成深景包") {
                        Task { await build() }
                    }.buttonStyle(.borderedProminent)
                    if let info = depthInfo {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("新包大小：\(depthData?.count ?? 0) 字节").font(.caption)
                            Text(info.hasRenderingConfiguration ? "已有深景开关" : "仍无深景开关").font(.caption)
                            Text(info.floatingHasClownfishPrefix ? "漂浮层已有 Clownfish 前缀" : "漂浮层无 Clownfish 前缀").font(.caption)
                        }
                        HStack {
                            if let url = shareURL {
                                ShareLink("分享深景包", item: url)
                            }
                            Button("设为当前包并去安装") {
                                if let data = depthData {
                                    state.setPackage(data)
                                    state.selectedTab = 1
                                }
                            }
                        }.buttonStyle(.bordered)
                    }
                }
                if !message.isEmpty {
                    Text(message).foregroundStyle(.red).font(.caption)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("深景")
        }
    }

    private func build() async {
        guard let data = state.packageData else { return }
        do {
            let out = try DepthPackageBuilder.addingDepthConfiguration(to: data, zip: ZipFoundationAdapter())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("wallive-depth.tendies")
            try out.write(to: url)
            depthData = out
            depthInfo = try TendiesPackage.inspect(out, zip: ZipFoundationAdapter())
            shareURL = url
            message = ""
        } catch {
            message = "生成失败：\(error.localizedDescription)"
        }
    }
}
