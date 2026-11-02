// WalliveCloneApp.swift
// 复刻版 App 壳：SwiftUI 入口（干净重写，无广告 SDK、无会员逻辑）。
// 五个页签：目录 → 导入 → 安装 → 深景 → 状态。

import SwiftUI

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
            InstallView()
                .tabItem { Label("安装", systemImage: "arrow.down.to.line") }
                .tag(2)
            DepthView()
                .tabItem { Label("深景", systemImage: "moon.stars") }
                .tag(3)
            StatusView()
                .tabItem { Label("状态", systemImage: "info.circle") }
                .tag(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(accountStore)
    }
}
