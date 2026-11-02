// HelloView.swift
// 进软件时的 Hello 开场：按用户给的视频重做——
// 深蓝紫渐变底 + 左上蓝光、右下粉光，铺满全屏（背景不变）；
// 口号不变（渐变口号 + 白字，压在 Hello 下边）；
// Hello 改成小写 hello，白字先亮 → 每个字母亮起霓虹色、带光晕、微微转开散开 →
// 再收回白字，整个动画 3 秒播完，主界面渐退进目录（计时在 WalliveCloneApp 里）。

import SwiftUI

struct HelloView: View {
    @State private var neon = false
    @State private var sloganOpacity = 0.0

    private var sloganGradient: LinearGradient {
        LinearGradient(
            colors: [.blue, .purple, .pink],
            startPoint: .leading, endPoint: .trailing)
    }

    /// 每个字母的霓虹色、散开时的角度和位移（对齐视频里那股劲）。
    private struct NeonLetter {
        let char: String
        let color: Color
        let angle: Double
        let dx: CGFloat
        let dy: CGFloat
    }

    private let letters: [NeonLetter] = [
        NeonLetter(char: "h", color: .cyan, angle: -8, dx: 0, dy: -6),
        NeonLetter(char: "e", color: .pink, angle: 6, dx: 0, dy: 4),
        NeonLetter(char: "l", color: Color(red: 0.5, green: 0.8, blue: 1.0), angle: -4, dx: 0, dy: -2),
        NeonLetter(char: "l", color: .yellow, angle: 10, dx: 0, dy: 6),
        NeonLetter(char: "o", color: Color(red: 1.0, green: 0.3, blue: 0.7), angle: -6, dx: 0, dy: -4),
    ]

    var body: some View {
        ZStack {
            // 铺满全屏的底：深蓝紫渐变 + 两团光晕（左上蓝、右下粉），跟之前一样。
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
                // hello：白字 → 霓虹散开 → 收回白字。
                HStack(spacing: 2) {
                    ForEach(letters.indices, id: \.self) { idx in
                        let letter = letters[idx]
                        Text(letter.char)
                            .font(.system(size: 88, weight: .bold))
                            .foregroundStyle(neon ? letter.color : .white)
                            .rotationEffect(.degrees(neon ? letter.angle : 0))
                            .offset(x: neon ? letter.dx : 0, y: neon ? letter.dy : 0)
                            .shadow(color: neon ? letter.color : .clear, radius: neon ? 18 : 0)
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
            // 0.5 秒后亮起霓虹散开，1.8 秒后收回白字，2.4 秒前回到干净白字。
            withAnimation(.easeInOut(duration: 0.6).delay(0.5)) {
                neon = true
            }
            withAnimation(.easeInOut(duration: 0.6).delay(1.8)) {
                neon = false
            }
            withAnimation(.easeIn(duration: 0.5).delay(1.2)) {
                sloganOpacity = 1
            }
        }
    }
}
