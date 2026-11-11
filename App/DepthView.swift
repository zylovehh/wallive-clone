// DepthView.swift
// 管理页：刷入记录管理（按回执删）+ 进群入口。
// 深景包制作流程已按用户要求从本页拿掉（生成/分享/设为当前包/安装）。

import Foundation
import SwiftUI

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

struct DepthView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                // 刷入记录（Drift 同款入口）：管理页里看装过哪些、按回执删。
                VStack(alignment: .leading, spacing: 8) {
                    Text("刷入记录").font(.headline)
                    NavigationLink {
                        ReceiptManageView()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.title3).foregroundStyle(.blue)
                            Text("管理刷入的壁纸").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
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
            }
            .padding()
            .background(AppBackgroundView())
            .navigationTitle("管理")
        }
    }
}

/// 管理刷入的壁纸（Drift 同款页）：装过哪些、按回执删。
/// 列表来自回执账本（本机直写路装完落的那张账）；删除走 RestoreTest.deleteByReceipt
///（沙箱逃逸 + 三道保险 + 删后重枚举），清空只清账本不碰设备。
private struct ReceiptManageView: View {
    @State private var receipts: [InstallReceipt] = []
    @State private var deleteBusy = false
    @State private var resultNote = ""
    @State private var deleteTarget: InstallReceipt?
    @State private var showClearConfirm = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if receipts.isEmpty {
                    Text("还没有记录：装完一张壁纸，这里就有账。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(receipts, id: \.targetPath) { receipt in
                    entry(receipt)
                }
                if !resultNote.isEmpty {
                    Text(resultNote).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Button("清空记录", role: .destructive) { showClearConfirm = true }
                    .buttonStyle(.bordered)
                Text("普通记录只是历史；带删除按钮的回执条目删的是设备上的那个描述符。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("管理刷入的壁纸")
        .onAppear { receipts = Array(InstallReceiptStore.receipts().reversed()) }
        .alert("删除这张壁纸？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } })) {
            Button("删除", role: .destructive) {
                if let receipt = deleteTarget { delete(receipt) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("只删这次装进去的这张，系统自带的不碰。删完重新数一遍，删干净才算数。")
        }
        .alert("清空记录？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                InstallReceiptStore.clearAll()
                receipts = []
                resultNote = "记录清了；设备上的壁纸还在，要删单张用上面每条里的删除。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清这张账，设备上的壁纸不动。")
        }
    }

    private func entry(_ receipt: InstallReceipt) -> some View {
        let isPairing = receipt.method == "pairing"
        return VStack(alignment: .leading, spacing: 4) {
            Text(receipt.packageName ?? receipt.descriptorUUID)
                .font(.subheadline.weight(.semibold))
            if let build = receipt.buildNumber {
                Text("\(isPairing ? "配对隧道" : "本机直刷") · 构建 \(build)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("通道：\(isPairing ? "配对隧道" : "本机直刷")")
                .font(.caption).foregroundStyle(.secondary)
            Text(receipt.verified
                 ? "核验：已核验 · 文件 \(receipt.fileCount) 个"
                 : "核验：未确认显示")
                .font(.caption).foregroundStyle(.secondary)
            if !isPairing {
                Text("生效：写入后关闭 PosterBoard")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(Self.timeFormatter.string(from: receipt.date))
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("删除", role: .destructive) { deleteTarget = receipt }
                    .disabled(deleteBusy)
                if deleteBusy { ProgressView() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 1))
    }

    private func delete(_ receipt: InstallReceipt) {
        deleteBusy = true
        resultNote = ""
        Task {
            // 删除走沙箱逃逸，是阻塞调用，放到后台线程跑。
            let result = await Task.detached(priority: .userInitiated) {
                RestoreTest.deleteByReceipt(receipt)
            }.value
            resultNote = result.message
            receipts = Array(InstallReceiptStore.receipts().reversed())
            deleteBusy = false
        }
    }
}
