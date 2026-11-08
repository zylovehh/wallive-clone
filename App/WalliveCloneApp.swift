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
        // iPad 布局：iOS 18 起 iPad 的页签默认飘在顶部，改回底部。
        .modifier(PadBottomTabs())
        .environmentObject(accountStore)
    }
}

/// iPad 布局：iOS 18 起 iPad 的页签默认飘在顶部胶囊，强制回到底部 dock 栏。
/// 只在 iPad + iOS 18+ 生效；iPhone 和 iOS 17 以下不动（本来就在底部）。
private struct PadBottomTabs: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad {
            content.tabViewStyle(.tabBarOnly)
        } else {
            content
        }
    }
}
