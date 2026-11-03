// DepthView.swift
// 深景包制作：给标准包加渲染配置开关 + Clownfish 前缀（装机验证过的配方），
// 生成后可分享、可设为当前包再去安装，也能直接在本页安装。

import Foundation
import SwiftUI

struct DepthView: View {
    @EnvironmentObject private var state: AppState
    // 管理员账号：分享深景包只给管理员，没登入不显示分享按钮，别人拿不到导出的包。
    // 生成和安装不动，人人都能用。
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.openURL) private var openURL
    @State private var depthData: Data?
    @State private var depthInfo: TendiesPackageInfo?
    @State private var shareURL: URL?
    @State private var message = ""
    @State private var installing = false
    @State private var installMessage = ""

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
                            if let url = shareURL, accountStore.currentUser != nil {
                                ShareLink("分享深景包", item: url)
                            }
                            Button("设为当前包并去安装") {
                                if let data = depthData {
                                    state.setPackage(data)
                                    state.selectedTab = 2
                                }
                            }
                        }.buttonStyle(.bordered)
                        Button("安装壁纸") {
                            Task { await runDepthInstall() }
                        }.buttonStyle(.borderedProminent)
                        .disabled(installing)
                        if installing {
                            ProgressView("正在安装…")
                        }
                        if !installMessage.isEmpty {
                            Text(installMessage).font(.caption)
                        }
                    }
                }
                if !message.isEmpty {
                    Text(message).foregroundStyle(.red).font(.caption)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text("QQ 交流群").font(.headline)
                    HStack {
                        Button("加入 QQ 群") {
                            if let url = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=153226955&card_type=group&source=qrcode") {
                                openURL(url)
                            }
                        }.buttonStyle(.bordered)
                        Text("群号：153226955").font(.caption).textSelection(.enabled)
                    }
                    Text("点按钮直接跳到 QQ 群；没装 QQ 时复制群号手动搜。").font(.caption).foregroundStyle(.secondary)
                }
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

    // 深景页直接安装：先把刚生成的深景包设为当前包，再装，装的就是深景包不是原包。
    // 装完显示结果；没生成、没配对、VPN 没连时只显示提示，不会没反应。
    private func runDepthInstall() async {
        guard let data = depthData else {
            installMessage = "先点“生成深景包”，生成好了再装。"
            return
        }
        installing = true
        installMessage = ""
        defer { installing = false }
        state.setPackage(data)
        if let uuid = await state.install(host: "10.7.0.1") {
            installMessage = "安装完成，描述符：\(uuid)。去锁屏看看，换上去了就是成了。"
        } else if !state.statusMessage.isEmpty {
            installMessage = state.statusMessage
        } else {
            installMessage = "安装未完成：请确认已导入配对记录、回环 VPN 已连接，再试一次。"
        }
    }
}
