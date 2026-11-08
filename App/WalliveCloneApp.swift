// WalliveCloneApp.swift
// 复刻版 App 壳：SwiftUI 入口（干净重写，无广告 SDK、无会员逻辑）。
// V6 四个页签：目录 → 导入 → 深景 → 状态（安装并进导入详情页）。

import SwiftUI
import UIKit

@main
struct WalliveCloneApp: App {
    @StateObject private var state = AppState()

    init() {
        // 留住 Grappa 令牌函数：安装时 Rust 层靠 dlsym 找这个符号，
        // 没有它，图书同步拿不到令牌，手机会回同步失败。
        _ = ALGetGrappaToken(0, 0, 0, nil, 0, nil, nil, 0)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                // #02：全 App 强制深色。背景是深色涂鸦图（AppBackgroundView），
                // 浅色模式的黑字/深灰字在黑底上看不见——Duo 截图里标题、次要文字、
                // 没选中的安装方式、底部页签全是这么糊住的。深色下标题白字、
                // 次要文字浅灰、玻璃按钮白字，全部可读；系统浅色/深色切换不再影响。
                .preferredColorScheme(.dark)
        }
    }
}

// Grappa 令牌函数在 GrappaHelper.m 里实现（随包编译进程序）；
// 这里只声明签名，让编译器留住这个符号，Rust 层才能靠 dlsym 找到它。
@_silgen_name("ALGetGrappaToken")
func ALGetGrappaToken(
    _ inVersion: UInt32,
    _ inDeviceType: UInt32,
    _ inProtocolVersion: UInt32,
    _ outBuf: UnsafeMutablePointer<UInt8>?,
    _ maxLen: Int,
    _ outLen: UnsafeMutablePointer<Int>?,
    _ errBuf: UnsafeMutablePointer<CChar>?,
    _ errLen: Int
) -> Int32

/// 全页背景：仓库里 App/app-background.jpg（网页上传的原图），
/// 各页根视图垫在它上面，卡片用半透明底，背景才透得出来。
/// 找不到图时回退纯黑，不会闪白屏。
/// 图只解一次：static 只初始化一次，第一次用到时解开，之后各页复用同一张，
/// 不再每次 body 都重新读盘解图（切页签时主线程上不再重复解图）。
struct AppBackgroundView: View {
    /// 背景图缓存：只解一次，之后直接复用；图找不到时是 nil，走纯黑回退。
    private static let backgroundImage: UIImage? = {
        guard let url = Bundle.main.url(forResource: "app-background", withExtension: "jpg"),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }()

    var body: some View {
        if let image = Self.backgroundImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

/// 进软件流程：Hello 动画 → 直接进主界面（别人不用登入）。
/// 登入入口在目录页右上角人头按钮，只给管理员（改置顶、增删）用。
private enum AppPhase {
    case hello, main
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var accountStore = AccountStore()
    @State private var phase: AppPhase = .hello

    var body: some View {
        ZStack {
            switch phase {
            case .hello:
                HelloView()
                    .transition(.opacity)
            case .main:
                mainTabs
            }
        }
        .task {
            // Hello 动画 3 秒，播完渐退直接进主界面（别人不用登入）。
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.easeOut(duration: 0.5)) {
                phase = .main
            }
        }
    }

    private var mainTabs: some View {
        TabView(selection: $state.selectedTab) {
            CatalogView()
                .tabItem { Label("目录", systemImage: "square.grid.2x2") }
                .tag(0)
            ImportView()
                .tabItem { Label("导入", systemImage: "square.and.arrow.down") }
                .tag(1)
            DepthView()
                .tabItem { Label("深景", systemImage: "moon.stars") }
                .tag(2)
            StatusView()
                .tabItem { Label("状态", systemImage: "info.circle") }
                .tag(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // iPad 布局：系统页签栏藏起来，底部改用一颗浮动药丸（跟原来顶部那颗一个样）。
        .modifier(PadFloatingTabPill())
        .environmentObject(accountStore)
    }
}

/// iPad 布局：系统页签栏藏起来，底部改用一颗浮动药丸（跟原来顶部那颗一个样）。
/// 只在 iPad 生效；iPhone 不动（本来就是底部标准页签）。
///
/// 顶栏为什么藏不住（V1 实测 + mollyiv.dev）：iPadOS 18 起系统页签栏改成顶部浮动药丸，
/// `.toolbar(.hidden, for: .tabBar)` 有已知 bug——编程式切页签（点底部药丸设 selectedTab）
/// 后顶栏会重新出现。iOS 18 起要用 `.toolbarVisibility(.hidden, for: .tabBar)` 才能真正藏住。
/// 两处都写上：18+ 走新 API，17 走老 API。顶栏藏不住是点导入/深景还卡的根源，务必藏掉。
private struct PadFloatingTabPill: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            Group {
                if #available(iOS 18.0, *) {
                    content
                        .toolbar(.hidden, for: .tabBar)
                        .toolbarVisibility(.hidden, for: .tabBar)
                } else {
                    content
                        .toolbar(.hidden, for: .tabBar)
                }
            }
            .overlay(alignment: .bottom) {
                FloatingTabPill()
            }
        } else {
            content
        }
    }
}

/// iPad 底部浮动药丸：四个字横排，选中的那段底色稍亮一点。
/// 点哪个就把 selectedTab 设成对应序号（0 目录、1 导入、2 深景、3 状态）。
private struct FloatingTabPill: View {
    @EnvironmentObject private var state: AppState

    private let labels = ["目录", "导入", "深景", "状态"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<labels.count, id: \.self) { index in
                Button(labels[index]) {
                    state.selectedTab = index
                }
                .font(.subheadline.weight(state.selectedTab == index ? .semibold : .regular))
                .foregroundStyle(state.selectedTab == index ? .white : .white.opacity(0.7))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background {
                    if state.selectedTab == index {
                        Capsule().fill(Color.white.opacity(0.25))
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
            }
        }
        .padding(4)
        // 药丸底改实在：深色不透底 + 细白边，任何背景上都一眼能看清、字能读清。
        // V1 的白 0.06 在深色涂鸦底上几乎隐形；glassEffect(.clear) 在 26 上也太透，都不用了。
        .background {
            Capsule()
                .fill(Color(white: 0.12).opacity(0.9))
                .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
        }
        .padding(.bottom, 16)
    }
}
