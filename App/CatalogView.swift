// CatalogView.swift
// 目录页：iPhone 页（目录）+ iPad 页（已下载），卡片列表 + 搜索 + 分类 + 下载。
// 卡片左上角播放键点一下播预览视频（AVKit 系统播放器），平时只显示静态缩略图。
// 下载完直接把包交给安装页（AppState.setPackage + 切到“安装”页），不另起安装逻辑。
// 红心收藏的排前面（只影响本机显示，目录表不动）。
// 管理员登入后卡片上有置顶图钉；点卡片进详情页，管理区里有加视频/换视频、换壁纸、换名字、换标签、删除壁纸（推到公开目录仓库，靠本机钥匙串里的 GitHub 钥匙）。

import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// 发版角标：用于一眼确认手机上装的是哪个版本。tag 来自 BuildInfo，
/// 编包时由 Codemagic 按“日期-构建号”盖戳（见 codemagic.yaml），
/// 本地没盖戳时用 BuildInfo.swift 里的 fallback。
enum AppBuild {
    static let version = "V6"
    static let tag = BuildInfo.tag
}

struct CatalogView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var accountStore: AccountStore
    @StateObject private var store = CatalogStore()
    @StateObject private var favorites = FavoritesStore()
    @State private var segment = 0 // 0 iPhone，1 iPad
    @Namespace private var segmentNS
    @State private var query = ""
    @State private var selectedCategory = "全部"
    @State private var previewItem: CatalogItem?
    @State private var showingAccount = false
    @State private var adminBusy = false
    @State private var adminMessage = ""
    @State private var adminMessageIsError = false
    @State private var showingAdd = false
    @State private var itemToDelete: CatalogItem?
    @State private var videoReplaceItem: CatalogItem?

    /// 列数：手机 2 列；iPad 按页分：iPhone 页横屏 6 列、竖屏 4 列，
    /// iPad 页的卡片再小一号——横屏 8 列、竖屏 6 列。
    /// 不用 adaptive（实测 adaptive 在 iPad 上会算出宽窄不一的列，卡片一大一小对不齐），
    /// 直接按屏宽算死每列宽，列列等宽。
    private var catalogColumnCount: Int {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let landscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
            if segment == 1 { return landscape ? 8 : 6 }
            return landscape ? 6 : 4
        } else {
            return 2
        }
    }

    private var catalogCardWidth: CGFloat {
        (UIScreen.main.bounds.width - 32 - CGFloat(catalogColumnCount - 1) * 12) / CGFloat(catalogColumnCount)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(catalogCardWidth), spacing: 12), count: catalogColumnCount)
    }

    /// 全部分类：全部 + 目录里出现过的标签。
    private var categories: [String] {
        var seen = Set<String>()
        var result = ["全部"]
        for item in store.items {
            for tag in item.tags where !seen.contains(tag) {
                seen.insert(tag)
                result.append(tag)
            }
        }
        return result
    }

    /// 搜标题或标签 + 分类筛选后的卡片，收藏的排前面（只影响本机显示，目录表不动）。
    private var filteredItems: [CatalogItem] {
        let _ = favorites.version // 订阅收藏变化：点红心就重排，不用切页才生效。
        let filtered = store.items.filter { item in
            // iPhone 页只显示 iPhone 壁纸（没 device 字段的老条目默认就是 iPhone）。
            guard item.device == "iphone" else { return false }
            let categoryOK = selectedCategory == "全部"
                || item.tags.contains(selectedCategory)
            let queryOK = query.isEmpty
                || item.title.localizedCaseInsensitiveContains(query)
                || item.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            return categoryOK && queryOK
        }
        // 收藏的在前，其余保持目录原顺序（enumerated 保证排序稳定）。
        return filtered.enumerated().sorted { a, b in
            let aFav = favorites.isFavorite(a.element.id)
            let bFav = favorites.isFavorite(b.element.id)
            if aFav != bFav { return aFav }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// iPad 页的壁纸：目录里 device 是 ipad 的条目，同样按分类/搜索过滤、收藏排前面。
    private var ipadItems: [CatalogItem] {
        let _ = favorites.version
        let filtered = store.items.filter { item in
            guard item.device == "ipad" else { return false }
            let categoryOK = selectedCategory == "全部"
                || item.tags.contains(selectedCategory)
            let queryOK = query.isEmpty
                || item.title.localizedCaseInsensitiveContains(query)
                || item.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            return categoryOK && queryOK
        }
        return filtered.enumerated().sorted { a, b in
            let aFav = favorites.isFavorite(a.element.id)
            let bFav = favorites.isFavorite(b.element.id)
            if aFav != bFav { return aFav }
            return a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        NavigationStack {
            // iPad 上间距收紧一点，iPhone 页上边空隙小一点；iPhone 不动。
            VStack(spacing: UIDevice.current.userInterfaceIdiom == .pad ? 4 : 8) {
                // iPhone / iPad：高透液态玻璃分段条，选中的那段稍亮一点。
                HStack(spacing: 4) {
                    ForEach([(0, "iPhone"), (1, "iPad")], id: \.0) { value, label in
                        Button(label) { segment = value }
                            .font(.subheadline.weight(segment == value ? .semibold : .regular))
                            .foregroundStyle(segment == value ? .white : .white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            // 选中那段放大一下再弹回：回弹要看得见，不能只靠药丸滑动。
                            .scaleEffect(segment == value ? 1.1 : 1.0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.4), value: segment)
                            .background {
                                if segment == value {
                                    Capsule()
                                        .fill(Color.white.opacity(0.18))
                                        .matchedGeometryEffect(id: "segmentPill", in: segmentNS)
                                }
                            }
                            .buttonStyle(PressBounceButtonStyle())
                            .contentShape(Capsule())
                    }
                }
                .padding(4)
                .modifier(LiquidGlassSegmented())
                // 回弹要明显：弹簧放慢、阻尼放小，药丸滑过去带一点过冲。
                .animation(.spring(response: 0.5, dampingFraction: 0.4), value: segment)
                .padding(.horizontal)
                // iPad 上分段条不拉满屏：最多 560 宽，居中放。
                .frame(maxWidth: 560)

                if segment == 0 {
                    discoverView
                } else {
                    myView
                }
            }
            .background(AppBackgroundView())
            // 顶部不留大黑边：不用系统大标题，改用一行小标题，整个目录往上贴。
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // iPad 上不显示“目录”两个字，只留右上角人头按钮，顶部往上贴。
                if UIDevice.current.userInterfaceIdiom != .pad {
                    ToolbarItem(placement: .principal) {
                        Text("目录").font(.headline)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingAccount = true } label: {
                        Image(systemName: "person.circle")
                    }
                }
            }
            .sheet(isPresented: $showingAccount) {
                AccountView(store: accountStore)
            }
            .task { await store.fetch() }
            .navigationDestination(for: String.self) { id in
                if let item = store.items.first(where: { $0.id == id }) {
                    CatalogDetailView(
                        item: item,
                        store: store,
                        favorites: favorites,
                        isAdmin: accountStore.currentUser != nil,
                        adminBusy: adminBusy,
                        onPreview: {
                            if let live = store.items.first(where: { $0.id == id }) { previewItem = live }
                        },
                        onDownload: {
                            if let live = store.items.first(where: { $0.id == id }) {
                                await downloadAndInstall(live)
                            }
                        },
                        onTogglePin: { Task { await adminTogglePin(item) } },
                        onDelete: {
                            itemToDelete = store.items.first(where: { $0.id == id }) ?? item
                        },
                        onReplaceVideo: {
                            videoReplaceItem = store.items.first(where: { $0.id == id }) ?? item
                        }
                    )
                } else {
                    Text("这张壁纸已经不在目录里了。")
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(item: $previewItem) { item in
                PreviewPlayerView(item: item)
            }
            .sheet(isPresented: $showingAdd) {
                AddWallpaperView(store: store, onAdded: { showingAdd = false })
            }
            .sheet(item: $videoReplaceItem) { item in
                ReplaceVideoView(store: store, item: item, onDone: {
                    videoReplaceItem = nil
                    adminMessage = "视频已换好。"
                    adminMessageIsError = false
                })
            }
            .alert("删除这张壁纸？", isPresented: Binding(
                get: { itemToDelete != nil },
                set: { if !$0 { itemToDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let item = itemToDelete { Task { await adminDelete(item) } }
                }
                Button("取消", role: .cancel) { itemToDelete = nil }
            } message: {
                Text("只从目录表里删掉这条，仓库里的文件还留着。")
            }
        }
    }

    // MARK: - iPhone 页

    private var discoverView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索标题或标签", text: $query)
                    .textInputAutocapitalization(.never)
            }
            .padding(8)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            // iPad 上搜索框不拉满屏：最多 560 宽，居中放。
            .frame(maxWidth: 560)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { category in
                        Button(category) { selectedCategory = category }
                            .buttonStyle(.bordered)
                            .tint(selectedCategory == category ? .accentColor : .secondary)
                    }
                }
                .padding(.horizontal)
            }

            // 管理员行：只有登入的管理员能看到（别人看不到、也点不到）。
            if accountStore.currentUser != nil {
                HStack(spacing: 12) {
                    Button("增加壁纸") { showingAdd = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(adminBusy)
                    if adminBusy { ProgressView() }
                    Spacer()
                }
                .padding(.horizontal)
                if !adminMessage.isEmpty {
                    Text(adminMessage)
                        .font(.caption)
                        .foregroundStyle(adminMessageIsError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                }
            }

            if store.loading && store.items.isEmpty {
                ProgressView("正在拉目录…")
                Spacer()
            } else if store.items.isEmpty {
                Text("目录是空的或没拉到，请检查网络后重试。")
                    .foregroundStyle(.secondary)
                Button("重新拉取") { Task { await store.fetch() } }
                    .buttonStyle(.bordered)
                Spacer()
            } else if filteredItems.isEmpty {
                Text("没有符合的壁纸，换个关键词或分类试试。")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredItems) { item in
                            NavigationLink(value: item.id) {
                                CatalogCard(
                                    item: item,
                                    downloaded: store.isDownloaded(item),
                                    downloading: store.downloadingIDs.contains(item.id),
                                    favorites: favorites,
                                    isAdmin: accountStore.currentUser != nil,
                                    adminBusy: adminBusy,
                                    onPreview: { previewItem = item },
                                    onDownload: { await downloadAndInstall(item) },
                                    onTogglePin: { Task { await adminTogglePin(item) } }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            if !store.errorMessage.isEmpty {
                Text(store.errorMessage).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal)
            }
        }
    }

    /// 下载完直接交安装页：设当前包 + 切到“安装”页，用户在那点安装。
    /// 标 @MainActor：里面要调 AppState（MainActor）的设包和切页。
    @MainActor
    private func downloadAndInstall(_ item: CatalogItem) async {
        if store.isDownloaded(item),
           let data = try? Data(contentsOf: store.localURL(for: item)) {
            state.setPackage(data, displayName: item.title)
            addToLibrary(displayName: item.title)
            state.selectedTab = 1
            return
        }
        if let data = await store.download(item) {
            state.setPackage(data, displayName: item.title)
            addToLibrary(displayName: item.title)
            state.selectedTab = 1
        }
    }

    /// 目录下载完顺手放进导入库：导入页只认库里的包，光 setPackage 不进库，
    /// 之前从目录下的包在导入页就看不到。封面直接从包里抠，不另外走网络。
    /// 同一个名字已经在库里就不重复加（目录里一个标题只对应一张包）。
    private func addToLibrary(displayName: String) {
        guard let stored = state.packageData else { return }
        if state.importedPackages.contains(where: { $0.displayName == displayName }) { return }
        let thumb = ImportThumbnailMaker.make(from: stored)
        state.addImportedPackage(data: stored, displayName: displayName, thumbnail: thumb)
    }

    // MARK: - 管理员改目录（推到公开目录仓库）

    /// 改置顶：把这张的 pinned 翻一下，整表推到仓库；没钥匙先提示去管理员页保存。
    @MainActor
    private func adminTogglePin(_ item: CatalogItem) async {
        guard let token = accountStore.loadToken() else {
            adminMessage = "先在管理员页保存 GitHub 钥匙。"
            adminMessageIsError = true
            return
        }
        adminBusy = true
        defer { adminBusy = false }
        // 先查最新那条：详情页改名后，旧 item 里的标题还是改之前的，照旧推会把新名字盖回去。
        let live = store.items.first { $0.id == item.id } ?? item
        let toggled = CatalogItem(
            id: live.id, title: live.title, tags: live.tags,
            thumbnailURL: live.thumbnailURL, previewURL: live.previewURL,
            packageURL: live.packageURL, pinned: !live.pinned, downloads: live.downloads, device: live.device)
        let newItems = store.items.map { $0.id == item.id ? toggled : $0 }
        do {
            try await store.pushCatalog(newItems, token: token)
            adminMessage = toggled.pinned ? "已置顶。" : "已取消置顶。"
            adminMessageIsError = false
        } catch {
            adminMessage = "没推上去：\(error.localizedDescription)"
            adminMessageIsError = true
        }
    }

    /// 删目录条目：只从目录表里去掉这条，仓库里的文件还留着（以后想恢复再加回来）。
    @MainActor
    private func adminDelete(_ item: CatalogItem) async {
        itemToDelete = nil
        guard let token = accountStore.loadToken() else {
            adminMessage = "先在管理员页保存 GitHub 钥匙。"
            adminMessageIsError = true
            return
        }
        adminBusy = true
        defer { adminBusy = false }
        let newItems = store.items.filter { $0.id != item.id }
        do {
            try await store.pushCatalog(newItems, token: token)
            adminMessage = "已从目录删除（文件还留在仓库里）。"
            adminMessageIsError = false
        } catch {
            adminMessage = "没推上去：\(error.localizedDescription)"
            adminMessageIsError = true
        }
    }

    // MARK: - iPad 页

    /// iPad 页：目录里 device 是 ipad 的壁纸，用跟 iPhone 页一样的卡片网格显示；
    /// 管理员在“增加壁纸”里选 iPad 传上来的就出现在这里。
    private var myView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.loading && store.items.isEmpty {
                ProgressView("正在拉目录…")
                Spacer()
            } else if ipadItems.isEmpty {
                Text("这里还没有 iPad 壁纸，去“增加壁纸”里选 iPad 传一张吧。")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(ipadItems) { item in
                            NavigationLink(value: item.id) {
                                CatalogCard(
                                    item: item,
                                    downloaded: store.isDownloaded(item),
                                    downloading: store.downloadingIDs.contains(item.id),
                                    favorites: favorites,
                                    isAdmin: accountStore.currentUser != nil,
                                    adminBusy: adminBusy,
                                    onPreview: { previewItem = item },
                                    onDownload: { await downloadAndInstall(item) },
                                    onTogglePin: { Task { await adminTogglePin(item) } }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .padding(.horizontal)
        // iPad 上 iPad 页满宽显示，不再缩在中间窄窄一条；iPhone 不动。
        .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? .infinity : nil, alignment: .leading)
        .overlay(alignment: .bottom) {
            Text("构建 \(AppBuild.tag)")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.bottom, 4)
        }
    }
}

// MARK: - 卡片

/// 收藏仓库：红心只存本机（UserDefaults），键名沿用以前的 favorite-<id>，以前点的红心都还在。
/// 点一下红心就发一次变化，目录页收到就把收藏的排前面（只影响本机显示，目录表不动）。
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var version = 0

    func isFavorite(_ id: String) -> Bool {
        UserDefaults.standard.bool(forKey: "favorite-\(id)")
    }

    func toggle(_ id: String) {
        let key = "favorite-\(id)"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        version += 1
    }
}

/// 一张壁纸卡片，对齐原版“交互壁纸”页样式：
/// 全幅图进圆角手机框（9:19.5，缩略图本身就是全幅图，不再是黑底抠图或带时钟的锁屏截图），
/// 标题、标签、下载条都压在图内底部，左上播放键、右上收藏心。
/// 卡片高度只由图片比例定，两列卡片上下对齐，不再一高一低。
private struct CatalogCard: View {
    let item: CatalogItem
    let downloaded: Bool
    let downloading: Bool
    @ObservedObject var favorites: FavoritesStore
    let isAdmin: Bool
    let adminBusy: Bool
    let onPreview: () -> Void
    let onDownload: () async -> Void
    let onTogglePin: () -> Void

    /// 封面视频：封面地址本身是视频就用它；否则预览是视频的也直接拿预览当封��播。
    private var coverVideoURL: URL? {
        if Self.isVideoPath(item.thumbnailURL), let url = URL(string: item.thumbnailURL) {
            return url
        }
        if !item.previewURL.isEmpty, Self.isVideoPath(item.previewURL),
           let url = URL(string: item.previewURL) {
            return url
        }
        return nil
    }

    var body: some View {
        // 统一规格：所有封面（图、视频）都按同一个 9:19.5 框铺满裁切，
        // 卡片高度一致、两列对齐，圆角统一。
        Color.clear
            .aspectRatio(9 / 19.5, contentMode: .fit)
            .overlay {
                ZStack {
                    if let url = coverVideoURL {
                        // 有视频的：卡片里静音循环播放当封面，对齐原版样式。
                        InlineVideoCover(url: url)
                    } else if let url = URL(string: item.thumbnailURL) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                placeholder
                            }
                        }
                    } else {
                        placeholder
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottom) {
            // 底部渐变罩，让压在图上的白字在亮图上也看得清。
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 150)
        }
        .overlay(alignment: .top) {
            HStack {
                // 没给视频的静态壁纸不显示播放键（静态预览图就是缩略图本身）。
                if !item.previewURL.isEmpty, URL(string: item.previewURL) != nil {
                    Button(action: onPreview) {
                        Image(systemName: "play.fill")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(RoundGlassButtonStyle())
                }
                Spacer()
                Button {
                    favorites.toggle(item.id)
                } label: {
                    Image(systemName: favorites.isFavorite(item.id) ? "heart.fill" : "heart")
                        .foregroundStyle(favorites.isFavorite(item.id) ? .red : .white)
                }
                .buttonStyle(RoundGlassButtonStyle())
                // 管理员图钉：同排圆钮，也换高透玻璃，保持一排样式一致。
                if isAdmin {
                    Button(action: onTogglePin) {
                        Image(systemName: item.pinned ? "pin.fill" : "pin")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(RoundGlassButtonStyle())
                    .disabled(adminBusy)
                }
            }
            .padding(8)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.subheadline).bold()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if item.pinned {
                        Text("置顶")
                            .font(.caption2).bold()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text(item.tags.map { "#\($0)" }.joined(separator: " ")
                    + (item.downloads > 0 ? " · 下载 \(item.downloads) 次" : ""))
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                // 下载条：液态玻璃胶囊，压在预览图下方（图内底部），样式对齐用户给的参考图：
                // 两头全圆的胶囊、更透的玻璃、圆体字、圆圈箭头图标。
                Button {
                    Task { await onDownload() }
                } label: {
                    HStack {
                        Spacer()
                        if downloading {
                            ProgressView().tint(.white)
                        } else {
                            Label(downloaded ? "已下载" : "下载", systemImage: "arrow.down.circle")
                                .foregroundStyle(.white)
                                .font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .modifier(LiquidGlassBar())
                }
                .buttonStyle(PressBounceButtonStyle())
                .disabled(downloading)
            }
            .padding(10)
            .fontDesign(.rounded)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.quaternary)
            .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
    }

    /// 封面地址指到视频文件（.mp4/.mov）时，卡片直接播视频当封面。
    static func isVideoPath(_ path: String) -> Bool {
        ["mp4", "mov", "m4v"].contains((path as NSString).pathExtension.lowercased())
    }
}

/// 卡片内嵌视频封面：静音、无控件、无缝循环播放。
private struct InlineVideoCover: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIView {
        let view = PlayerContainerView()
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        let item = AVPlayerItem(url: url)
        context.coordinator.looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        context.coordinator.player = queuePlayer
        // App 切到后台（锁屏也算）就停播，回来再播：封面视频不能在后台还占着播放器，
        // 不然锁屏上会冒出一个“未在播放”的播放器。
        context.coordinator.observeBackground(queuePlayer)
        queuePlayer.play()
        let layer = AVPlayerLayer(player: queuePlayer)
        layer.videoGravity = .resizeAspectFill
        layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1) // layoutSubviews 会铺满
        view.layer.addSublayer(layer)
        view.playerLayer = layer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var looper: AVPlayerLooper?
        var player: AVQueuePlayer?
        private var observers: [NSObjectProtocol] = []

        /// 后台停播、回前台续播（只管自己的播放器）。
        func observeBackground(_ player: AVQueuePlayer) {
            guard observers.isEmpty else { return }
            observers.append(NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { _ in player.pause() })
            observers.append(NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { _ in player.play() })
        }

        deinit {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }
    }

    /// 容器视图：铺满父视图时同步把播放层也铺满。
    final class PlayerContainerView: UIView {
        var playerLayer: AVPlayerLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer?.frame = bounds
        }
    }
}

/// 液态透明圆钮：播放、收藏、图钉共用。
private struct LiquidGlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear, in: Circle())
        } else {
            content.background(.white.opacity(0.06)).clipShape(Circle())
        }
    }
}

/// 液态透明分段条外框：iPhone / iPad 共用。
private struct LiquidGlassSegmented: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear, in: Capsule())
        } else {
            content.background(.white.opacity(0.06)).clipShape(Capsule())
        }
    }
}

/// 液态透明条：iOS 26+ 用透明系统液态玻璃，低版本回退半透明白条。
/// 形状是两头全圆的胶囊，玻璃透明，让底下的壁纸透出来。
private struct LiquidGlassBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear, in: Capsule())
        } else {
            content
                .background(.white.opacity(0.06))
                .clipShape(Capsule())
        }
    }
}

/// 点动特效：点下缩一点、松开弹簧弹回，跟底部 dock 栏的点动一样。
private struct PressBounceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .opacity(configuration.isPressed ? 0.65 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// 圆钮：玻璃 + 点动合一，直接当 buttonStyle 用。
/// 玻璃不套在 label 里层（之前那样点按没反应），44pt 实心命中区。
private struct RoundGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .modifier(LiquidGlassCircle())
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.65 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

// MARK: - 增加壁纸（管理员）

/// 增加壁纸表单：标题、标签、选 .tendies 文件、选缩略图，按顺序传包、传图、追加条目并推表。
/// 只有登入的管理员能打开（入口在 iPhone 页管理员行）；推表靠本机钥匙串里的 GitHub 钥匙。
private struct AddWallpaperView: View {
    @ObservedObject var store: CatalogStore
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.dismiss) private var dismiss
    let onAdded: () -> Void

    @State private var title = ""
    @State private var tags = "动漫"
    /// 壁纸给哪个设备：iphone 或 ipad，选 ipad 的传上去就进 iPad 页。
    @State private var device = "iphone"
    @State private var tendiesName = ""
    @State private var tendiesData: Data?
    @State private var thumbItem: PhotosPickerItem?
    @State private var thumbImage: UIImage?
    @State private var thumbData: Data?
    @State private var videoItem: PhotosPickerItem?
    @State private var videoData: Data?
    // 选一次记一次数：相册选中项的编号在没授权时是空的，靠编号触发读取根本启动不了，
    // 所以改靠次数触发——选了就加一，次数一变读取任务就启动，不管有没有编号。
    @State private var thumbPickVersion = 0
    @State private var videoPickVersion = 0
    @State private var showingTendiesPicker = false
    @State private var message = ""
    // 出错时的错误代码与原始细节：长按可选，或点“复制错误代码”一键复制发给灵光。
    @State private var errorDetail = ""
    @State private var copiedError = false
    @State private var busy = false
    // 上传进度（0~1）；nil 表示当前不在上传（读文件/推表阶段可能暂时没有）。
    @State private var uploadProgress: Double?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("标题", text: $title)
                    .textFieldStyle(.roundedBorder)
                TextField("标签（逗号或顿号分隔）", text: $tags)
                    .textFieldStyle(.roundedBorder)
                Picker("给哪个设备", selection: $device) {
                    Text("iPhone").tag("iphone")
                    Text("iPad").tag("ipad")
                }
                .pickerStyle(.segmented)
                .disabled(busy)
                Button(tendiesName.isEmpty ? "选 .tendies 文件" : "已选：\(tendiesName).tendies") {
                    showingTendiesPicker = true
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                PhotosPicker(selection: Binding(
                    get: { thumbItem },
                    set: { newValue in
                        thumbItem = newValue
                        if newValue != nil { thumbPickVersion += 1 }
                    }
                ), matching: .images) {
                    Text(thumbImage == nil ? "选缩略图（可不选）" : "已选缩略图")
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                if let thumbImage {
                    Image(uiImage: thumbImage)
                        .resizable().scaledToFit().frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                PhotosPicker(selection: Binding(
                    get: { videoItem },
                    set: { newValue in
                        videoItem = newValue
                        if newValue != nil { videoPickVersion += 1 }
                    }
                ), matching: .videos) {
                    Text(videoData == nil ? "选预览视频" : "已选预览视频")
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                if busy {
                    ProgressView()
                    if let uploadProgress {
                        ProgressView(value: uploadProgress)
                            .progressViewStyle(.linear)
                        Text("正在上传 \(Int((uploadProgress * 100).rounded()))%，大文件传得慢是正常的")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if (thumbItem != nil && thumbData == nil) || (videoItem != nil && videoData == nil) {
                    // 图/视频还在从相册读取：转圈动画提示，读完自动消失并放开上传按钮。
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("图/视频还在读取，读完自动放开上传按钮。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if !errorDetail.isEmpty {
                        Text(errorDetail)
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(copiedError ? "已复制，去聊天里粘贴给灵光" : "复制错误代码") {
                            UIPasteboard.general.string = errorDetail
                            copiedError = true
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }
                Text("缩略图和预览视频都可选：选了视频就用视频当封面（卡片里直接循环播放）；没视频才会用图或包里的图自动生成封面；预览视频不选也能下载安装。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("增加到目录") { Task { await add() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty
                              || tendiesData == nil
                              || (thumbItem != nil && thumbData == nil)
                              || (videoItem != nil && videoData == nil))
                Text("构建 \(AppBuild.tag)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("增加壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            // 不用 SwiftUI fileImporter：部分系统版本上它会把自定义后缀整排置灰点不动。
            // 改用 UIDocumentPicker（asCopy 取副本，免安全域处理），public.item 收一切文件。
            .sheet(isPresented: $showingTendiesPicker) {
                DocumentPicker(contentTypes: [.item]) { url in
                    guard let data = try? Data(contentsOf: url) else {
                        fail("没读到文件，重新选一次。", code: "E-101 壁纸包读取-无内容")
                        return
                    }
                    // 后缀不限死：.tendies 直接收；其他后缀按内容认（WALLIVE1 魔数或标准 zip 都算）。
                    let looksLikeZip = data.count > 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
                    let looksLikeTendies = url.pathExtension.lowercased() == "tendies"
                        || Wallive1Crypto.isWallive1(data)
                        || looksLikeZip
                    guard looksLikeTendies else {
                        fail("这个文件认不出是壁纸包，重新选一次。", code: "E-102 壁纸包读取-内容不识别")
                        return
                    }
                    tendiesName = url.deletingPathExtension().lastPathComponent
                    tendiesData = data
                    message = ""
                    errorDetail = ""
                }
            }
            .task(id: thumbPickVersion) {
                guard let item = thumbItem else { return }
                do {
                    let data = try await Self.loadImageData(from: item)
                    if let image = UIImage(data: data),
                       let jpeg = image.jpegData(compressionQuality: 0.85) {
                        thumbImage = image
                        thumbData = jpeg
                    } else {
                        thumbItem = nil
                        fail("这张图没读到，重新选一次。", code: "E-201 图片读取-无内容")
                    }
                } catch is CancellationError {
                    // 换了新选择或离开页面导致的取消，不算失败，安静退出。
                    return
                } catch {
                    if Task.isCancelled { return }
                    thumbItem = nil
                    fail("图片 30 秒没读出来，已停止等待。重新选一次；反复失败就重启手机再试。", code: "E-203 图片读取-超时", detail: String(describing: error))
                }
            }
            .task(id: videoPickVersion) {
                guard let item = videoItem else { return }
                do {
                    videoData = try await Self.loadVideoData(from: item)
                } catch is CancellationError {
                    // 换了新选择或离开页面导致的取消，不算失败，安静退出。
                    return
                } catch {
                    // 旧任务超时后才回来、用户已经换了新选择时，不清新选择、不报错。
                    if Task.isCancelled { return }
                    videoItem = nil
                    fail("视频 30 秒没读出来，已停止等待。先在相册里把视频点开播一遍（最好连 WiFi），再重新选一次。", code: "E-204 视频读取-超时", detail: String(describing: error))
                }
            }
        }
    }

    /// 视频读取（视频当预览用，绝不跳过）：先走文件导出，系统把视频拷到临时文件再读，
    /// 不整段往内存里塞，本地小视频这条路最稳；导出文件读不到再回数据直读。
    /// 两通道都不行就抛超时，绝不让界面无限转圈。
    private static func loadVideoData(from item: PhotosPickerItem) async throws -> Data {
        if let url = try await withReadTimeout(seconds: 30, work: {
            try await item.loadTransferable(type: URL.self)
        }) {
            if let data = try? Data(contentsOf: url) {
                return data
            }
        }
        if let data = try await withReadTimeout(seconds: 30, work: {
            try await item.loadTransferable(type: Data.self)
        }) {
            return data
        }
        throw URLError(.timedOut)
    }

    /// 图片读取（防干等版）：与视频同款，数据直读 30 秒，超时换导出文件通道再 30 秒。
    private static func loadImageData(from item: PhotosPickerItem) async throws -> Data {
        if let data = try await withReadTimeout(seconds: 30, work: {
            try await item.loadTransferable(type: Data.self)
        }) {
            return data
        }
        if let url = try await withReadTimeout(seconds: 30, work: {
            try await item.loadTransferable(type: URL.self)
        }) {
            return try Data(contentsOf: url)
        }
        throw URLError(.timedOut)
    }

    /// 给可能卡死的读取操作加真超时：到点就报错返回，不等卡住的任务。
    /// 旧版用任务组等第一个结果，卡住的子任务不响应取消时组会一直等，
    /// 所以 30 秒到了界面还在转；新版用“谁先到谁赢、输家直接丢弃”的办法，
    /// 超时到了就报错，卡住的后台任务不再挡界面。
    /// 超时和读取都用独立任务跑，不跟主界面抢道，保证到点一定能报错。
    private actor TimeoutGate {
        private var done = false
        func claim() -> Bool {
            if done { return false }
            done = true
            return true
        }
    }

    private static func withReadTimeout<T: Sendable>(seconds: TimeInterval,
                                                     work: @escaping @Sendable () async throws -> T?) async throws -> T? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
            let gate = TimeoutGate()
            Task.detached {
                do {
                    let result = try await work()
                    if await gate.claim() {
                        continuation.resume(returning: result)
                    }
                } catch {
                    if await gate.claim() {
                        continuation.resume(throwing: error)
                    }
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if await gate.claim() {
                    continuation.resume(throwing: URLError(.timedOut))
                }
            }
        }
    }

    /// 统一报错：正文说人话，附上错误代码和原始细节，方便一键复制发回给灵光。
    private func fail(_ text: String, code: String, detail: String = "") {
        message = text
        errorDetail = detail.isEmpty ? code : "\(code) | \(detail)"
        copiedError = false
    }

    /// 增加流程：传包 → （选了视频传视频当封面，否则传图）→ 追加条目并推表。
    @MainActor
    private func add() async {
        guard let token = accountStore.loadToken() else {
            fail("先在管理员页保存 GitHub 钥匙。", code: "E-301 增加壁纸-缺少钥匙")
            return
        }
        guard let packageData = tendiesData else { return }
        // 封面优先级：选了视频 → 视频直接当封面（不抽帧）；没视频才找图（选的图 > 包里的图）。
        var imageData: Data?
        if videoData == nil {
            imageData = thumbData ?? Self.autoThumbnail(from: packageData)
        }
        guard videoData != nil || imageData != nil else {
            fail("封面没着落：这个包里没找到图，点上方\"选缩略图\"手动选一张。", code: "E-302 增加壁纸-无封面来源")
            return
        }
        let id = CatalogStore.safeID(from: tendiesName)
        guard !store.items.contains(where: { $0.id == id }) else {
            fail("已有同名壁纸，换个文件名。", code: "E-303 增加壁纸-条目重名")
            return
        }
        busy = true
        defer { busy = false; uploadProgress = nil }
        let parsedTags = tags
            .components(separatedBy: CharacterSet(charactersIn: ",，、"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let finalTags = parsedTags.isEmpty ? ["动漫"] : parsedTags
        do {
            try await store.uploadWallpaperFile(name: "\(id).tendies", data: packageData, token: token,
                                                progress: { value in Task { @MainActor in uploadProgress = value } })
            // 视频优先：选了视频就不传静态封面图，thumbnail 和 preview 都指这个视频。
            var thumbnailURL = ""
            var previewURL = ""
            if let videoData {
                let videoName = "\(id)-preview.\(Self.videoExtension(for: videoItem))"
                try await store.uploadWallpaperFile(name: videoName, data: videoData, token: token,
                                                    progress: { value in Task { @MainActor in uploadProgress = value } })
                previewURL = CatalogStore.wallpapersRawBase + videoName
                thumbnailURL = previewURL
            } else {
                try await store.uploadWallpaperFile(name: "\(id)-thumb.jpg", data: imageData!, token: token,
                                                    progress: { value in Task { @MainActor in uploadProgress = value } })
                thumbnailURL = CatalogStore.wallpapersRawBase + "\(id)-thumb.jpg"
            }
            let newItem = CatalogItem(
                id: id, title: title.trimmingCharacters(in: .whitespaces), tags: finalTags,
                thumbnailURL: thumbnailURL,
                previewURL: previewURL,
                packageURL: CatalogStore.wallpapersRawBase + "\(id).tendies",
                pinned: false, downloads: 0, device: device)
            // 新传的放第一个非置顶位置（置顶后面、其他旧条目前面），不再追加到最后。
            var updatedItems = store.items
            let insertAt = updatedItems.firstIndex(where: { !$0.pinned }) ?? updatedItems.endIndex
            updatedItems.insert(newItem, at: insertAt)
            try await store.pushCatalog(updatedItems, token: token)
            onAdded()
        } catch {
            fail("没推上去，请点“复制错误代码”发给灵光。", code: "E-304 上传目录-失败", detail: String(describing: error))
        }
    }

    /// 预览视频扩展名：按所选视频的格式来，默认 mp4。
    private static func videoExtension(for item: PhotosPickerItem?) -> String {
        guard let item = item else { return "mp4" }
        if item.supportedContentTypes.contains(.mpeg4Movie) { return "mp4" }
        if item.supportedContentTypes.contains(.quickTimeMovie) { return "mov" }
        return "mp4"
    }

    /// 没选缩略图时的兜底：从包里挑背景层的图自动压一张。
    /// 找图条件放宽：assets 路径大小写不敏感、前后缀不限，常见图片格式都认；
    /// 实在没命中就全包逐张试解，挑像素最大的当封面，尽量不卡在封面这步。
    private static func autoThumbnail(from packageData: Data) -> Data? {
        let zip = ZipFoundationAdapter()
        // 包可能是 WALLIVE1 加密包，先还原成明文 zip 再翻资产。
        let plain: Data
        if Wallive1Crypto.isWallive1(packageData) {
            guard let decrypted = try? Wallive1Crypto.decrypt(packageData) else { return nil }
            plain = decrypted
        } else {
            plain = packageData
        }
        guard let entries = try? zip.listEntries(in: plain) else { return nil }
        let imageExts = ["jpeg", "jpg", "png", "heic", "heif", "webp", "tiff", "bmp", "gif"]
        let isImageEntry = { (path: String) -> Bool in
            imageExts.contains((path as NSString).pathExtension.lowercased())
        }
        // 资产图片里优先背景层，其次 assets 下第一张；
        // 都没有就把全包的图挨个解开，挑像素面积最大的那张。
        let assetImages = entries.filter { isImageEntry($0) && $0.lowercased().contains("assets") }
        if let picked = assetImages.first(where: { $0.lowercased().contains("background") })
            ?? assetImages.first,
            let data = try? zip.readEntry(picked, in: plain),
            let image = UIImage(data: data) {
            return Self.compressThumbnail(image)
        }
        var bestImage: UIImage?
        var bestPixels: CGFloat = 0
        for path in entries.filter(isImageEntry) {
            guard let data = try? zip.readEntry(path, in: plain),
                  let image = UIImage(data: data) else { continue }
            let pixels = image.size.width * image.size.height * image.scale
            if pixels > bestPixels {
                bestPixels = pixels
                bestImage = image
            }
            if bestPixels > 2_000_000 { break } // 够大就收手，别把大包全翻一遍。
        }
        guard let image = bestImage else { return nil }
        return Self.compressThumbnail(image)
    }

    /// 最长边压到 720，控制封面图体积。
    private static func compressThumbnail(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 720
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = min(1, maxSide / max(longest, 1))
        let scaled = UIGraphicsImageRenderer(size: CGSize(width: size.width * scale, height: size.height * scale)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        }
        return scaled.jpegData(compressionQuality: 0.85)
    }
}

// MARK: - 预览播放器

/// 系统视频播放器播预览视频，关掉页面就停。
private struct PreviewPlayerView: View {
    let item: CatalogItem
    @State private var player: AVPlayer?

    var body: some View {
        VStack {
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                Text("预览暂不可用").foregroundStyle(.secondary)
            }
        }
        // 关掉预览就把播放器彻底放掉：只暂停不释放，锁屏上还会留一个“未在播放”的播放器。
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
        .onAppear {
            if let url = URL(string: item.previewURL) {
                player = AVPlayer(url: url)
            }
        }
    }
}


// MARK: - 换视频（管理员）

/// 给已有壁纸换预览视频：选一个视频传到仓库，覆盖同名预览文件，
/// 再把这条的预览和封面地址改成新视频，推表。
/// 没视频的条目也能用，按钮会显示“加视频”。
/// 只有登入的管理员能打开（入口在卡片上）；推表靠本机钥匙串里的 GitHub 钥匙。
private struct ReplaceVideoView: View {
    @ObservedObject var store: CatalogStore
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.dismiss) private var dismiss
    let item: CatalogItem
    let onDone: () -> Void

    @State private var videoItem: PhotosPickerItem?
    @State private var videoData: Data?
    // 选一次记一次数：相册选中项的编号在没授权时是空的，靠编号触发读取根本启动不了，
    // 所以改靠次数触发——选了就加一，次数一变读取任务就启动，不管有没有编号。
    @State private var videoPickVersion = 0
    @State private var message = ""
    // 出错时的错误代码与原始细节：长按可选，或点“复制错误代码”一键复制发给灵光。
    @State private var errorDetail = ""
    @State private var copiedError = false
    @State private var busy = false
    // 上传进度（0~1）；nil 表示当前不在上传。
    @State private var uploadProgress: Double?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("给「\(item.title)」换视频")
                    .font(.headline)
                Text(item.previewURL.isEmpty
                     ? "这张现在没有预览视频，选一个传上去，卡片就播视频当封面。"
                     : "选一个新视频传上去，旧的预览文件会被同名覆盖。")
                    .font(.caption).foregroundStyle(.secondary)
                PhotosPicker(selection: Binding(
                    get: { videoItem },
                    set: { newValue in
                        videoItem = newValue
                        if newValue != nil { videoPickVersion += 1 }
                    }
                ), matching: .videos) {
                    Text(videoData == nil ? "选预览视频" : "已选预览视频")
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                if busy {
                    ProgressView()
                    if let uploadProgress {
                        ProgressView(value: uploadProgress)
                            .progressViewStyle(.linear)
                        Text("正在上传 \(Int((uploadProgress * 100).rounded()))%，大文件传得慢是正常的")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if videoItem != nil && videoData == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("视频还在读取，读完自动放开上传按钮。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if !errorDetail.isEmpty {
                        Text(errorDetail)
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(copiedError ? "已复制，去聊天里粘贴给灵光" : "复制错误代码") {
                            UIPasteboard.general.string = errorDetail
                            copiedError = true
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }
                Button(item.previewURL.isEmpty ? "加视频到目录" : "换视频并更新目录") { Task { await replace() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || videoData == nil)
                Text("构建 \(AppBuild.tag)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("换视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task(id: videoPickVersion) {
                guard let pickerItem = videoItem else { return }
                do {
                    videoData = try await Self.loadVideoData(from: pickerItem)
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    videoItem = nil
                    fail("视频 30 秒没读出来，已停止等待。先在相册里把视频点开播一遍（最好连 WiFi），再重新选一次。", code: "E-304 换视频-视频读取超时", detail: String(describing: error))
                }
            }
        }
    }

    /// 换视频流程：传视频（同名覆盖）→ 改这条的预览和封面地址 → 推表。
    @MainActor
    private func replace() async {
        guard let token = accountStore.loadToken() else {
            fail("先在管理员页保存 GitHub 钥匙。", code: "E-301 换视频-缺少钥匙")
            return
        }
        guard let videoData else { return }
        busy = true
        defer { busy = false; uploadProgress = nil }
        do {
            let videoName = "\(item.id)-preview.\(Self.videoExtension(for: videoItem))"
            try await store.uploadWallpaperFile(name: videoName, data: videoData, token: token,
                                                progress: { value in Task { @MainActor in uploadProgress = value } })
            let videoURL = CatalogStore.wallpapersRawBase + videoName
            let live = store.items.first { $0.id == item.id } ?? item
            let updated = CatalogItem(
                id: live.id, title: live.title, tags: live.tags,
                thumbnailURL: videoURL, previewURL: videoURL,
                packageURL: live.packageURL, pinned: live.pinned, downloads: live.downloads, device: live.device)
            let newItems = store.items.map { $0.id == item.id ? updated : $0 }
            try await store.pushCatalog(newItems, token: token)
            onDone()
            dismiss()
        } catch {
            fail("没换上去，请点“复制错误代码”发给灵光。", code: "E-305 换视频-上传失败", detail: String(describing: error))
        }
    }

    /// 预览视频扩展名：按所选视频的格式来，默认 mp4。
    private static func videoExtension(for pickerItem: PhotosPickerItem?) -> String {
        guard let pickerItem else { return "mp4" }
        if pickerItem.supportedContentTypes.contains(.mpeg4Movie) { return "mp4" }
        if pickerItem.supportedContentTypes.contains(.quickTimeMovie) { return "mov" }
        return "mp4"
    }

    /// 视频读取（视频当预览用，绝不跳过）：先走文件导出，系统把视频拷到临时文件再读，
    /// 不整段往内存里塞，本地小视频这条路最稳；导出文件读不到再回数据直读。
    /// 两通道都不行就抛超时，绝不让界面无限转圈。
    private static func loadVideoData(from pickerItem: PhotosPickerItem) async throws -> Data {
        if let url = try await withReadTimeout(seconds: 30, work: {
            try await pickerItem.loadTransferable(type: URL.self)
        }) {
            if let data = try? Data(contentsOf: url) {
                return data
            }
        }
        if let data = try await withReadTimeout(seconds: 30, work: {
            try await pickerItem.loadTransferable(type: Data.self)
        }) {
            return data
        }
        throw URLError(.timedOut)
    }

    /// 给可能卡死的读取操作加真超时：到点就报错返回，不等卡住的任务。
    private actor TimeoutGate {
        private var done = false
        func claim() -> Bool {
            if done { return false }
            done = true
            return true
        }
    }

    private static func withReadTimeout<T: Sendable>(seconds: TimeInterval,
                                                     work: @escaping @Sendable () async throws -> T?) async throws -> T? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
            let gate = TimeoutGate()
            Task.detached {
                do {
                    let result = try await work()
                    if await gate.claim() {
                        continuation.resume(returning: result)
                    }
                } catch {
                    if await gate.claim() {
                        continuation.resume(throwing: error)
                    }
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if await gate.claim() {
                    continuation.resume(throwing: URLError(.timedOut))
                }
            }
        }
    }

    /// 统一报错：正文说人话，附上错误代码和原始细节，方便一键复制发回给灵光。
    private func fail(_ text: String, code: String, detail: String = "") {
        message = text
        errorDetail = detail.isEmpty ? code : "\(code) | \(detail)"
        copiedError = false
    }
}

// MARK: - 详情页（点卡片打开的二级页）

/// 点卡片打开的详情页：大封面、名字、标签、下载按钮；
/// 管理员在下面看到管理区：加视频/换视频、换壁纸、换名字、换标签、删除壁纸，
/// 按钮都是液态玻璃胶囊（下载条同款）。
/// 显示的名字、标签都从目录表里现查（live），详情页里改名、换标签后页面立刻跟着变；
/// 条目被删了就自动退回目录页。
private struct CatalogDetailView: View {
    let item: CatalogItem
    @ObservedObject var store: CatalogStore
    @ObservedObject var favorites: FavoritesStore
    @Environment(\.dismiss) private var dismiss
    let isAdmin: Bool
    let adminBusy: Bool
    let onPreview: () -> Void
    let onDownload: () async -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let onReplaceVideo: () -> Void

    @State private var showingReplacePackage = false
    @State private var showingRename = false
    @State private var showingRetag = false
    @State private var adminMessage = ""
    @State private var adminMessageIsError = false
    /// 分享壁纸：下好的包写进临时文件后调系统分享单。
    @State private var shareFileURL: URL?
    @State private var sharing = false

    /// 目录表里最新那条（改名、换标签、换视频后都从这里读，不用打开时那份旧的）。
    private var live: CatalogItem {
        store.items.first { $0.id == item.id } ?? item
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                coverSection
                HStack(spacing: 6) {
                    Text(live.title)
                        .font(.title3).bold()
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if live.pinned {
                        Text("置顶")
                            .font(.caption2).bold()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text(live.tags.map { "#\($0)" }.joined(separator: " ")
                    + (live.downloads > 0 ? " · 下载 \(live.downloads) 次" : ""))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                Button {
                    Task { await onDownload() }
                } label: {
                    HStack {
                        Spacer()
                        if store.downloadingIDs.contains(live.id) {
                            ProgressView().tint(.white)
                        } else {
                            Label(store.isDownloaded(live) ? "已下载" : "下载", systemImage: "arrow.down.circle")
                                .foregroundStyle(.white)
                                .font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .modifier(LiquidGlassBar())
                }
                .buttonStyle(PressBounceButtonStyle())
                .disabled(store.downloadingIDs.contains(live.id))
                if isAdmin {
                    Text("管理").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        adminButton(live.previewURL.isEmpty ? "加视频" : "换视频", action: onReplaceVideo)
                        adminButton("换壁纸") { showingReplacePackage = true }
                        adminButton("换名字") { showingRename = true }
                        adminButton("换标签") { showingRetag = true }
                        adminButton("分享壁纸") { shareWallpaper() }
                    }
                    Button("删除壁纸", action: onDelete)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .modifier(LiquidGlassBar())
                        .buttonStyle(PressBounceButtonStyle())
                        .disabled(adminBusy)
                }
                if !adminMessage.isEmpty {
                    Text(adminMessage)
                        .font(.caption)
                        .foregroundStyle(adminMessageIsError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .background(AppBackgroundView())
        .navigationTitle(live.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReplacePackage) {
            ReplacePackageView(store: store, item: live, onDone: {
                showingReplacePackage = false
                adminMessage = "壁纸包已换好。"
                adminMessageIsError = false
            })
        }
        .sheet(isPresented: $showingRename) {
            RenameView(store: store, item: live, onDone: {
                showingRename = false
                adminMessage = "名字已换好。"
                adminMessageIsError = false
            })
        }
        .sheet(isPresented: $showingRetag) {
            RetagView(store: store, item: live, onDone: {
                showingRetag = false
                adminMessage = "标签已换好。"
                adminMessageIsError = false
            })
        }
        .sheet(isPresented: Binding(
            get: { shareFileURL != nil },
            set: { if !$0 { shareFileURL = nil } }
        )) {
            if let shareFileURL {
                ShareSheet(activityItems: [shareFileURL])
            }
        }
        .onReceive(store.$items) { items in
            if !items.contains(where: { $0.id == item.id }) { dismiss() }
        }
    }

    /// 大封面：有视频播视频当封面，否则播缩略图；右上播放、收藏、图钉。
    private var coverSection: some View {
        ZStack(alignment: .top) {
            Group {
                if let url = coverVideoURL {
                    InlineVideoCover(url: url)
                } else if let url = URL(string: live.thumbnailURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            RoundedRectangle(cornerRadius: 20)
                                .fill(.quaternary)
                                .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                        }
                    }
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.quaternary)
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
            }
            .aspectRatio(9 / 11, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            HStack {
                if !live.previewURL.isEmpty, URL(string: live.previewURL) != nil {
                    Button(action: onPreview) {
                        Image(systemName: "play.fill")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(RoundGlassButtonStyle())
                }
                Spacer()
                Button {
                    favorites.toggle(live.id)
                } label: {
                    Image(systemName: favorites.isFavorite(live.id) ? "heart.fill" : "heart")
                        .foregroundStyle(favorites.isFavorite(live.id) ? .red : .white)
                }
                .buttonStyle(RoundGlassButtonStyle())
                if isAdmin {
                    Button(action: onTogglePin) {
                        Image(systemName: live.pinned ? "pin.fill" : "pin")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(RoundGlassButtonStyle())
                    .disabled(adminBusy)
                }
            }
            .padding(8)
        }
    }

    /// 管理区按钮：液态玻璃胶囊，白字，跟下载条同款。
    private func adminButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .modifier(LiquidGlassBar())
            .buttonStyle(PressBounceButtonStyle())
            .disabled(adminBusy)
    }

    /// 分享壁纸（管理员）：把这张的 .tendies 包下下来（已下好的直接拿缓存），
    /// 写进临时文件调系统分享单。对方收到文件点开、选壁纸匣，就直接进安装页。
    private func shareWallpaper() {
        guard !sharing else { return }
        Task {
            sharing = true
            defer { sharing = false }
            var data: Data?
            if store.isDownloaded(live),
               let cached = try? Data(contentsOf: store.localURL(for: live)) {
                data = cached
            } else {
                data = await store.download(live)
            }
            guard let data else {
                adminMessage = "分享失败：壁纸包没下下来。"
                adminMessageIsError = true
                return
            }
            let base = live.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "\\", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let fileName = (base.isEmpty ? live.id : base) + ".tendies"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            do {
                try data.write(to: url, options: .atomic)
                shareFileURL = url
            } catch {
                adminMessage = "分享失败：\(error.localizedDescription)"
                adminMessageIsError = true
            }
        }
    }

    /// 封面视频：封面地址本身是视频就用它；否则预览是视频的也直接拿预览当封面播。
    private var coverVideoURL: URL? {
        if Self.isVideoPath(live.thumbnailURL), let url = URL(string: live.thumbnailURL) {
            return url
        }
        if !live.previewURL.isEmpty, Self.isVideoPath(live.previewURL),
           let url = URL(string: live.previewURL) {
            return url
        }
        return nil
    }

    /// 封面地址指到视频文件（.mp4/.mov）时，卡片直接播视频当封面。
    static func isVideoPath(_ path: String) -> Bool {
        ["mp4", "mov", "m4v"].contains((path as NSString).pathExtension.lowercased())
    }
}

// MARK: - 换壁纸（管理员）

/// 给已有壁纸换壁纸包：选一个新 .tendies 包传到仓库，覆盖同名包文件；
/// 目录里的名字、标签、预览都不变，不用推表。
/// 只有登入的管理员能打开（入口在详情页管理区）；推表靠本机钥匙串里的 GitHub 钥匙。
private struct ReplacePackageView: View {
    @ObservedObject var store: CatalogStore
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.dismiss) private var dismiss
    let item: CatalogItem
    let onDone: () -> Void

    @State private var showingPicker = false
    @State private var packageName = ""
    @State private var packageData: Data?
    @State private var message = ""
    @State private var errorDetail = ""
    @State private var copiedError = false
    @State private var busy = false
    @State private var uploadProgress: Double?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("给「\(item.title)」换壁纸包")
                    .font(.headline)
                Text("选一个新 .tendies 包传上去，覆盖这张原来的包文件；目录里的名字、标签、预览都不变。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(packageData == nil ? "选 .tendies 文件" : "已选：\(packageName)") {
                    showingPicker = true
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                if busy {
                    ProgressView()
                    if let uploadProgress {
                        ProgressView(value: uploadProgress)
                            .progressViewStyle(.linear)
                        Text("正在上传 \(Int((uploadProgress * 100).rounded()))%，大文件传得慢是正常的")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if !errorDetail.isEmpty {
                        Text(errorDetail)
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(copiedError ? "已复制，去聊天里粘贴给灵光" : "复制错误代码") {
                            UIPasteboard.general.string = errorDetail
                            copiedError = true
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }
                Button("换壁纸包") { Task { await replace() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || packageData == nil)
                Text("构建 \(AppBuild.tag)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("换壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            // 不用 SwiftUI fileImporter：部分系统版本上它会把自定义后缀整排置灰点不动。
            // 改用 UIDocumentPicker（asCopy 取副本，免安全域处理），public.item 收一切文件。
            .sheet(isPresented: $showingPicker) {
                DocumentPicker(contentTypes: [.item]) { url in
                    guard let data = try? Data(contentsOf: url) else {
                        fail("没读到文件，重新选一次。", code: "E-401 换壁纸-无内容")
                        return
                    }
                    // 后缀不限死：.tendies 直接收；其他后缀按内容认（WALLIVE1 魔数或标准 zip 都算）。
                    let looksLikeZip = data.count > 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
                    let looksLikeTendies = url.pathExtension.lowercased() == "tendies"
                        || Wallive1Crypto.isWallive1(data)
                        || looksLikeZip
                    guard looksLikeTendies else {
                        fail("这个文件认不出是壁纸包，重新选一次。", code: "E-402 换壁纸-内容不识别")
                        return
                    }
                    packageName = url.deletingPathExtension().lastPathComponent
                    packageData = data
                    message = ""
                    errorDetail = ""
                }
            }
        }
    }

    /// 换壁纸包流程：按原来包的文件名传上去覆盖（同名覆盖不用推表）。
    @MainActor
    private func replace() async {
        guard let token = accountStore.loadToken() else {
            fail("先在管理员页保存 GitHub 钥匙。", code: "E-403 换壁纸-缺少钥匙")
            return
        }
        guard let packageData else { return }
        busy = true
        defer { busy = false; uploadProgress = nil }
        do {
            let fileName = (item.packageURL as NSString).lastPathComponent
            try await store.uploadWallpaperFile(name: fileName, data: packageData, token: token,
                                                progress: { value in Task { @MainActor in uploadProgress = value } })
            onDone()
            dismiss()
        } catch {
            fail("没换上去，请点“复制错误代码”发给灵光。", code: "E-404 换壁纸-上传失败", detail: String(describing: error))
        }
    }

    /// 统一报错：正文说人话，附上错误代码和原始细节，方便一键复制发回给灵光。
    private func fail(_ text: String, code: String, detail: String = "") {
        message = text
        errorDetail = detail.isEmpty ? code : "\(code) | \(detail)"
        copiedError = false
    }
}

// MARK: - 换名字（管理员）

/// 给已有壁纸换标题：改完推表，详情页上的名字立刻跟着变。
/// 只有登入的管理员能打开（入口在详情页管理区）；推表靠本机钥匙串里的 GitHub 钥匙。
private struct RenameView: View {
    @ObservedObject var store: CatalogStore
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.dismiss) private var dismiss
    let item: CatalogItem
    let onDone: () -> Void

    @State private var title = ""
    @State private var message = ""
    @State private var errorDetail = ""
    @State private var copiedError = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("给「\(item.title)」换名字")
                    .font(.headline)
                TextField("新名字", text: $title)
                    .textFieldStyle(.roundedBorder)
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if !errorDetail.isEmpty {
                        Text(errorDetail)
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(copiedError ? "已复制，去聊天里粘贴给灵光" : "复制错误代码") {
                            UIPasteboard.general.string = errorDetail
                            copiedError = true
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }
                Button("保存名字") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty
                              || title.trimmingCharacters(in: .whitespaces) == item.title)
                Text("构建 \(AppBuild.tag)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("换名字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                if title.isEmpty { title = item.title }
            }
        }
    }

    /// 换名字流程：拼一张新卡（只改标题）→ 推表。
    @MainActor
    private func save() async {
        guard let token = accountStore.loadToken() else {
            fail("先在管理员页保存 GitHub 钥匙。", code: "E-411 换名字-缺少钥匙")
            return
        }
        let newTitle = title.trimmingCharacters(in: .whitespaces)
        guard !newTitle.isEmpty else { return }
        busy = true
        defer { busy = false }
        let live = store.items.first { $0.id == item.id } ?? item
        let updated = CatalogItem(
            id: live.id, title: newTitle, tags: live.tags,
            thumbnailURL: live.thumbnailURL, previewURL: live.previewURL,
            packageURL: live.packageURL, pinned: live.pinned, downloads: live.downloads, device: live.device)
        let newItems = store.items.map { $0.id == item.id ? updated : $0 }
        do {
            try await store.pushCatalog(newItems, token: token)
            onDone()
            dismiss()
        } catch {
            fail("没推上去，请点“复制错误代码”发给灵光。", code: "E-412 换名字-推表失败", detail: String(describing: error))
        }
    }

    /// 统一报错：正文说人话，附上错误代码和原始细节，方便一键复制发回给灵光。
    private func fail(_ text: String, code: String, detail: String = "") {
        message = text
        errorDetail = detail.isEmpty ? code : "\(code) | \(detail)"
        copiedError = false
    }
}

// MARK: - 换标签（管理员）

/// 给已有壁纸换标签：逗号或顿号隔开，改完推表。
/// 只有登入的管理员能打开（入口在详情页管理区）；推表靠本机钥匙串里的 GitHub 钥匙。
private struct RetagView: View {
    @ObservedObject var store: CatalogStore
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.dismiss) private var dismiss
    let item: CatalogItem
    let onDone: () -> Void

    @State private var tagsText = ""
    @State private var message = ""
    @State private var errorDetail = ""
    @State private var copiedError = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("给「\(item.title)」换标签")
                    .font(.headline)
                TextField("标签（逗号或顿号分隔）", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if !errorDetail.isEmpty {
                        Text(errorDetail)
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(copiedError ? "已复制，去聊天里粘贴给灵光" : "复制错误代码") {
                            UIPasteboard.general.string = errorDetail
                            copiedError = true
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }
                Button("保存标签") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || parsedTags.isEmpty)
                Text("构建 \(AppBuild.tag)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("换标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                if tagsText.isEmpty { tagsText = item.tags.joined(separator: "，") }
            }
        }
    }

    /// 输入框里的标签：逗号/顿号隔开，去掉空格和空项；一个不剩就默认“动漫”。
    private var parsedTags: [String] {
        let parsed = tagsText
            .components(separatedBy: CharacterSet(charactersIn: ",，、"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parsed.isEmpty ? ["动漫"] : parsed
    }

    /// 换标签流程：拼一张新卡（只改标签）→ 推表。
    @MainActor
    private func save() async {
        guard let token = accountStore.loadToken() else {
            fail("先在管理员页保存 GitHub 钥匙。", code: "E-421 换标签-缺少钥匙")
            return
        }
        busy = true
        defer { busy = false }
        let live = store.items.first { $0.id == item.id } ?? item
        let updated = CatalogItem(
            id: live.id, title: live.title, tags: parsedTags,
            thumbnailURL: live.thumbnailURL, previewURL: live.previewURL,
            packageURL: live.packageURL, pinned: live.pinned, downloads: live.downloads, device: live.device)
        let newItems = store.items.map { $0.id == item.id ? updated : $0 }
        do {
            try await store.pushCatalog(newItems, token: token)
            onDone()
            dismiss()
        } catch {
            fail("没推上去，请点“复制错误代码”发给灵光。", code: "E-422 换标签-推表失败", detail: String(describing: error))
        }
    }

    /// 统一报错：正文说人话，附上错误代码和原始细节，方便一键复制发回给灵光。
    private func fail(_ text: String, code: String, detail: String = "") {
        message = text
        errorDetail = detail.isEmpty ? code : "\(code) | \(detail)"
        copiedError = false
    }
}

/// 系统分享单：把文件发出去（微信、隔空投送、存文件都行）。
/// iPad 上分享单是浮层，没给锚点会闪退，这里锚到主窗口中间。
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        if let popover = controller.popoverPresentationController,
           let window = UIApplication.shared.connectedScenes
               .compactMap { $0 as? UIWindowScene }
               .flatMap { $0.windows }
               .first(where: { $0.isKeyWindow }) {
            popover.sourceView = window.rootViewController?.view
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
