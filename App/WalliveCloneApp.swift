// WalliveCloneApp.swift
// 复刻版 App 壳：SwiftUI 入口（干净重写，无广告 SDK、无会员逻辑）。
// 五个页签：目录 → 导入 → 安装 → 深景 → 状态。

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
    }
}
