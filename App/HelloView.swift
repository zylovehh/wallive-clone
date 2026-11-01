// HelloView.swift
// 进软件时的 Hello 开场：直接播一段 2 秒的液态金属 Hello 动画——
// 黑底、字母一笔一笔写出来、最后亮光扫过、带倒影。
// 口号也留着，压在视频下边：上边一行蓝紫粉渐变，下边一行白字。
// 视频本身无声，播完停在最后一帧；主界面 2 秒计时到点就渐退进登入页。
// 注意：hello_splash.mp4 必须打进包里（Resources），不然这里找不到文件就只剩黑底。

import SwiftUI
import AVKit

struct HelloView: View {
    @State private var player: AVPlayer?
    @State private var sloganOpacity = 0.0

    private var sloganGradient: LinearGradient {
        LinearGradient(
            colors: [.blue, .purple, .pink],
            startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .disabled(true)  // 纯开场，不让点按暂停或快进
            }
            VStack {
                Spacer()
                VStack(spacing: 6) {
                    Text("换一张壁纸，换一个心情")
                        .font(.title3).bold()
                        .foregroundStyle(sloganGradient)
                    Text("你好我好大家好")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .opacity(sloganOpacity)
                .padding(.bottom, 60)
            }
        }
        .onAppear {
            if let player {
                player.seek(to: .zero)
                player.play()
            } else if let url = Bundle.main.url(forResource: "hello_splash", withExtension: "mp4") {
                let p = AVPlayer(url: url)
                p.isMuted = true
                player = p
                p.play()
            }
            withAnimation(.easeIn(duration: 0.5).delay(0.2)) {
                sloganOpacity = 1
            }
        }
        .onDisappear { player?.pause() }
    }
}
