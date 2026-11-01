// WalliveCloneApp.swift
// 复刻版 App 壳：SwiftUI 入口（干净重写，无广告 SDK、无会员逻辑）。
// 四个页签对应原版流程：导入 → 安装 → 深景 → 状态。

import SwiftUI

@main
struct WalliveCloneApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView(selection: $state.selectedTab) {
            ImportView()
                .tabItem { Label("导入", systemImage: "square.and.arrow.down") }
                .tag(0)
            InstallView()
                .tabItem { Label("安装", systemImage: "arrow.down.to.line") }
                .tag(1)
            DepthView()
                .tabItem { Label("深景", systemImage: "moon.stars") }
                .tag(2)
            StatusView()
                .tabItem { Label("状态", systemImage: "info.circle") }
                .tag(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
