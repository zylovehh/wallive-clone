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
                // 分享进来的壁纸包：别人手机上分享 .tendies 选壁纸匣，
                // 直接进这张壁纸的安装页（导入详情页），不用再去导入库里找。
                // 认 .tendies / .wallive / .tendiesx / .tendiex 四种，
                // 后两种和 .tendies 里面是一样的东西（zip 或 WALLIVE1 加密），只是换了个后缀。
                .onOpenURL { url in
                    Task { @MainActor in
                        let ext = url.pathExtension.lowercased()
                        guard ext == "tendies" || ext == "wallive" || ext == "tendiesx" || ext == "tendiex" else { return }
                        let didAccess = url.startAccessingSecurityScopedResource()
                        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                        guard let data = try? Data(contentsOf: url) else { return }
                        let fileName = url.deletingPathExtension().lastPathComponent
                        let name = fileName.isEmpty ? url.lastPathComponent : fileName
                        state.setPackage(data, displayName: fileName.isEmpty ? nil : fileName)
                        if let stored = state.packageData {
                            let thumb = ImportThumbnailMaker.make(from: stored)
                            state.addImportedPackage(data: stored, displayName: name, thumbnail: thumb)
                        }
                        state.selectedTab = 1
                        state.showImportDetail = true
                    }
                }
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
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                // iPad：不用 TabView——系统顶栏药丸（iPadOS 18 浮动 tab bar）藏不住。
                // `.toolbar(.hidden)` 切页后会重新冒出来（已知 bug），
                // `.toolbarVisibility(.hidden)` 在 V2 真机上也证实不管用（mollyiv.dev：
                // “没有官方 API 能藏住默认 tab bar”）。而且 V2 在 iPad 上点导入/
                // 深景/状态会整 App 卡死、只有目录能点——三页进页时做的事都不会
                // 冻主线程（导入没配对文件直接返回，深景只是渐变文字动画，状态
                // 只是读个 plist），卡死只能是 TabView 编程式切页签那一步本身
                // 在 iPadOS 18 上的毛病。顶栏还在和切页卡死是同一个根因。
                // 改用自定义容器：四个页按 selectedTab 显示，没有 TabView 就没有
                // 系统顶栏、也没有 TabView 切页那步，两处一起治。底部药丸自己切页。
                // 只渲染当前选中的一页：之前四个页都留在层级里（只改透明度和可点），
                // 藏着的页也在跑东西——深景页的 TimelineView(.animation) 每秒刷 60 次、
                // 导入页的 List、状态页的内容全在后台跑，点着点着主线程就被拖死了，
                // V6 真机上深景/导入就是这么卡住的。只留选中页，藏着的页彻底拿掉，
                // 不跑动画、不跑任务。切页会重建页面（@State 会丢），但重要数据都在
                // AppState 里（包数据、包信息），重进还在。iPhone 不动，走原来的 TabView。
                ZStack(alignment: .bottom) {
                    Group {
                        switch state.selectedTab {
                        case 0:
                            CatalogView()
                        case 1:
                            ImportView()
                        case 2:
                            DepthView()
                        case 3:
                            StatusView()
                        default:
                            CatalogView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    FloatingTabPill()
                }
            } else {
                TabView(selection: $state.selectedTab) {
                    CatalogView()
                        .tabItem { Label("目录", systemImage: "square.grid.2x2") }
                        .tag(0)
                    ImportView()
                        .tabItem { Label("导入", systemImage: "square.and.arrow.down") }
                        .tag(1)
                    DepthView()
                        .tabItem { Label("管理", systemImage: "moon.stars") }
                        .tag(2)
                    StatusView()
                        .tabItem { Label("状态", systemImage: "info.circle") }
                        .tag(3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environmentObject(accountStore)
    }
}

/// iPad 底部浮动药丸：四个字横排，选中的那段底色稍亮一点。
/// 点哪个就把 selectedTab 设成对应序号（0 目录、1 导入、2 深景、3 状态）。
private struct FloatingTabPill: View {
    @EnvironmentObject private var state: AppState

    private let labels = ["目录", "导入", "管理", "状态"]

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
