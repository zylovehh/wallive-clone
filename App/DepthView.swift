// DepthView.swift
// 深景包制作：给标准包加渲染配置开关 + Clownfish 前缀（装机验证过的配方），
// 生成后可分享、可设为当前包再去安装，也能直接在本页安装。

import Foundation
import SwiftUI

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
    // QQ 卡渐变文字动画开关：出现即开始来回流动。
    @State private var qqGradientPhase = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if state.packageData == nil {
                    Text("还没选包：先去“导入”选本地包。")
                        .foregroundStyle(.secondary)
                } else {
                    Button("生成深景包") {
                        Task { await build() }
                    }.buttonStyle(GlassButtonStyle())
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
                                    state.selectedTab = 1
                                }
                            }
                        }.buttonStyle(GlassButtonStyle())
                        Button("安装壁纸") {
                            Task { await runDepthInstall() }
                        }.buttonStyle(GlassButtonStyle())
                        .disabled(installing)
                        if !installMessage.isEmpty {
                            Text(installMessage).font(.caption)
                        }
                    }
                }
                if !message.isEmpty {
                    Text(message).foregroundStyle(.red).font(.caption)
                }
                Spacer()
                // QQ 群：企鹅图标去掉，左边是渐变文字，右边是加入 QQ 群按钮（绿色去掉），点哪边都进群领视频教程。
                HStack {
                    Button {
                        if let url = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=153226955&card_type=group&source=qrcode") {
                            openURL(url)
                        }
                    } label: {
                        Text("进群领取视频教程")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.cyan, .blue, .purple, .pink, .orange, .cyan],
                                    startPoint: qqGradientPhase ? .topLeading : .bottomTrailing,
                                    endPoint: qqGradientPhase ? .bottomTrailing : .topLeading
                                )
                            )
                            .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: qqGradientPhase)
                            .onAppear { qqGradientPhase = true }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("加入 QQ 群") {
                        if let url = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=153226955&card_type=group&source=qrcode") {
                            openURL(url)
                        }
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
            }
            .padding()
            .background(AppBackgroundView())
            .navigationTitle("深景")
            .overlay {
                if installing {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在安装…")
                            Text("请稍等，不要退出").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
                        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.25), lineWidth: 1))
                        .shadow(radius: 20)
                    }
                }
            }
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
    // 装完不重启桌面、不闪，只导入图库，用户去图库手动设；没生成、没配对、VPN 没连时只显示提示，不会没反应。
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
            installMessage = "安装完成，描述符：\(uuid)。已导入图库，去锁屏长按进图库，找到新壁纸，点设为墙纸组合。"
        } else if !state.statusMessage.isEmpty {
            installMessage = state.statusMessage
        } else {
            installMessage = "安装未完成：请确认已导入配对记录、回环 VPN 已连接，再试一次。"
        }
    }
}
