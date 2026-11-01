// HelloView.swift
// 进软件时的 Hello 开场：按用户给的 Hello 预览图重做，不用视频了——
// 深蓝紫渐变底 + 左上蓝光、右下粉光，铺满全屏；白字 Hello 从左边一路跳跃进场，
// 落到中间后口号淡入；2 秒计时到点，主界面渐退进登入页（计时在 WalliveCloneApp 里）。
// 注意：旧 hello_splash.mp4 还在包里，但这里已经不再引用它。

import SwiftUI

struct HelloView: View {
    @State private var hopTrigger = false
    @State private var sloganOpacity = 0.0

    private var sloganGradient: LinearGradient {
        LinearGradient(
            colors: [.blue, .purple, .pink],
            startPoint: .leading, endPoint: .trailing)
    }

    /// 跳跃的起点和落点：x 从屏幕外左边到中间，y 原地弹跳。
    private struct HopValues {
        var x: CGFloat = 0
        var y: CGFloat = 0
    }

    var body: some View {
        ZStack {
            // 铺满全屏的底：深蓝紫渐变 + 两团光晕（左上蓝、右下粉），对齐预览图。
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.08, blue: 0.28),
                         Color(red: 0.04, green: 0.04, blue: 0.16)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            Circle()
                .fill(.blue.opacity(0.45))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: -140, y: -320)
            Circle()
                .fill(.pink.opacity(0.4))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: 150, y: 330)

            VStack(spacing: 10) {
                Spacer()
                // Hello：从左边跳跃进场，1.4 秒落到中间；弹跳幅度递减。
                Text("Hello")
                    .font(.system(size: 88, weight: .bold))
                    .foregroundStyle(.white)
                    .keyframeAnimator(
                        initialValue: HopValues(x: -UIScreen.main.bounds.width, y: 0),
                        trigger: hopTrigger
                    ) { content, values in
                        content.offset(x: values.x, y: values.y)
                    } keyframes: { _ in
                        KeyframeTrack(\.x) {
                            LinearKeyframe(0, duration: 1.4)
                        }
                        KeyframeTrack(\.y) {
                            LinearKeyframe(-45, duration: 0.25)
                            LinearKeyframe(0, duration: 0.25)
                            LinearKeyframe(-30, duration: 0.25)
                            LinearKeyframe(0, duration: 0.25)
                            LinearKeyframe(-15, duration: 0.2)
                            LinearKeyframe(0, duration: 0.2)
                        }
                    }
                VStack(spacing: 6) {
                    Text("换一张壁纸，换一个心情")
                        .font(.title3).bold()
                        .foregroundStyle(sloganGradient)
                    Text("你好我好大家好")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .opacity(sloganOpacity)
                Spacer()
            }
        }
        .onAppear {
            hopTrigger = true
            // Hello 落稳后再把口号淡入，2 秒内全部就位。
            withAnimation(.easeIn(duration: 0.5).delay(1.2)) {
                sloganOpacity = 1
            }
        }
    }
}
