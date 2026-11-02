// CatalogView.swift
// 目录页：仿原版发现页，卡片列表 + 搜索 + 分类 + 下载，另有“我的”页。
// 卡片左上角播放键点一下播预览视频（AVKit 系统播放器），平时只显示静态缩略图。
// 下载完直接把包交给安装页（AppState.setPackage + 切到“安装”页），不另起安装逻辑。
// 红心收藏的排前面（只影响本机显示，目录表不动）。
// 管理员登入后卡片上有改置顶、删除的按钮，还有增加壁纸的入口（推到公开目录仓库，靠本机钥匙串里的 GitHub 钥匙）。

import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct CatalogView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var accountStore: AccountStore
    @StateObject private var store = CatalogStore()
    @StateObject private var favorites = FavoritesStore()
    @State private var segment = 0 // 0 发现，1 我的
    @State private var query = ""
    @State private var selectedCategory = "全部"
    @State private var previewItem: CatalogItem?
    @State private var showingAccount = false
    @State private var adminBusy = false
    @State private var adminMessage = ""
    @State private var adminMessageIsError = false
    @State private var showingAdd = false
    @State private var itemToDelete: CatalogItem?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("目录", selection: $segment) {
                    Text("发现").tag(0)
                    Text("我的").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if segment == 0 {
                    discoverView
                } else {
                    myView
                }
            }
            // 顶部不留大黑边：不用系统大标题，改用一行小标题，整个目录往上贴。
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("目录").font(.headline)
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
            .sheet(item: $previewItem) { item in
                PreviewPlayerView(item: item)
            }
            .sheet(isPresented: $showingAdd) {
                AddWallpaperView(store: store, onAdded: { showingAdd = false })
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

    // MARK: - 发现页

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
                            CatalogCard(
                                item: item,
                                downloaded: store.isDownloaded(item),
                                downloading: store.downloadingIDs.contains(item.id),
                                favorites: favorites,
                                isAdmin: accountStore.currentUser != nil,
                                adminBusy: adminBusy,
                                onPreview: { previewItem = item },
                                onDownload: { await downloadAndInstall(item) },
                                onTogglePin: { Task { await adminTogglePin(item) } },
                                onDelete: { itemToDelete = item }
                            )
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
            state.setPackage(data)
            state.selectedTab = 2
            return
        }
        if let data = await store.download(item) {
            state.setPackage(data)
            state.selectedTab = 2
        }
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
        let toggled = CatalogItem(
            id: item.id, title: item.title, tags: item.tags,
            thumbnailURL: item.thumbnailURL, previewURL: item.previewURL,
            packageURL: item.packageURL, pinned: !item.pinned, downloads: item.downloads)
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

    // MARK: - 我的页

    private var myView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.downloaded.isEmpty {
                Text("还没下载过壁纸，去发现页下载一张吧。")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(store.downloaded) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title).font(.subheadline)
                            Text(record.tags.map { "#\($0)" }.joined(separator: " "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("下载于 \(record.downloadedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("安装") {
                                    if let data = try? Data(contentsOf: store.localURL(for: record)) {
                                        state.setPackage(data)
                                        state.selectedTab = 2
                                    }
                                }
                                Button("删除", role: .destructive) {
                                    store.delete(record)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(.horizontal)
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
    let onDelete: () -> Void

    var body: some View {
        ZStack {
            if let url = URL(string: item.thumbnailURL) {
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
        .aspectRatio(9 / 19.5, contentMode: .fit)
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
                            .padding(10)
                            .background(.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                }
                Spacer()
                Button {
                    favorites.toggle(item.id)
                } label: {
                    Image(systemName: favorites.isFavorite(item.id) ? "heart.fill" : "heart")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.45))
                        .clipShape(Circle())
                }
                // 管理员图钉：点一下改置顶（只有登入的管理员能看到）。
                if isAdmin {
                    Button(action: onTogglePin) {
                        Image(systemName: item.pinned ? "pin.fill" : "pin")
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.45))
                            .clipShape(Circle())
                    }
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
                .disabled(downloading)
                // 管理员删除：只从目录表里删条目（只有登入的管理员能看到）。
                if isAdmin {
                    Button("删除壁纸", action: onDelete)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .disabled(adminBusy)
                }
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
}

/// 液态玻璃条：iOS 26+ 用系统液态玻璃，低版本回退到半透明黑条，
/// 视觉上仍是同一条玻璃下载条，不会因系统版本编译不过或显示断层。
/// 形状是两头全圆的胶囊，玻璃比之前更透。
private struct LiquidGlassBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.tint(.black.opacity(0.12)),
                in: Capsule()
            )
        } else {
            content
                .background(.black.opacity(0.30))
                .clipShape(Capsule())
        }
    }
}

// MARK: - 增加壁纸（管理员）

/// 增加壁纸表单：标题、标签、选 .tendies 文件、选缩略图，按顺序传包、传图、追加条目并推表。
/// 只有登入的管理员能打开（入口在发现页管理员行）；推表靠本机钥匙串里的 GitHub 钥匙。
private struct AddWallpaperView: View {
    @ObservedObject var store: CatalogStore
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.dismiss) private var dismiss
    let onAdded: () -> Void

    @State private var title = ""
    @State private var tags = "动漫"
    @State private var tendiesName = ""
    @State private var tendiesData: Data?
    @State private var thumbItem: PhotosPickerItem?
    @State private var thumbImage: UIImage?
    @State private var thumbData: Data?
    @State private var videoItem: PhotosPickerItem?
    @State private var videoData: Data?
    @State private var showingTendiesPicker = false
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("标题", text: $title)
                    .textFieldStyle(.roundedBorder)
                TextField("标签（逗号或顿号分隔）", text: $tags)
                    .textFieldStyle(.roundedBorder)
                Button(tendiesName.isEmpty ? "选 .tendies 文件" : "已选：\(tendiesName).tendies") {
                    showingTendiesPicker = true
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                PhotosPicker(selection: $thumbItem, matching: .images) {
                    Text(thumbImage == nil ? "选缩略图（可不选）" : "已选缩略图")
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                if let thumbImage {
                    Image(uiImage: thumbImage)
                        .resizable().scaledToFit().frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                PhotosPicker(selection: $videoItem, matching: .videos) {
                    Text(videoData == nil ? "选预览视频" : "已选预览视频")
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                if busy { ProgressView() }
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("缩略图和预览视频都可选：缩略图不选会用包里的图自动生成；预览视频不选也能下载安装。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("增加到目录") { Task { await add() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty
                              || tendiesData == nil)
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
            .fileImporter(
                isPresented: $showingTendiesPicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    guard url.startAccessingSecurityScopedResource() else {
                        message = "没读到文件，重新选一次。"
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    guard let data = try? Data(contentsOf: url) else {
                        message = "没读到文件，重新选一次。"
                        return
                    }
                    // 后缀不限死：.tendies 直接收；其他后缀按内容认（WALLIVE1 魔数或标准 zip 都算）。
                    let looksLikeZip = data.count > 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
                    let looksLikeTendies = url.pathExtension.lowercased() == "tendies"
                        || Wallive1Crypto.isWallive1(data)
                        || looksLikeZip
                    guard looksLikeTendies else {
                        message = "这个文件认不出是壁纸包，重新选一次。"
                        return
                    }
                    tendiesName = url.deletingPathExtension().lastPathComponent
                    tendiesData = data
                    message = ""
                case .failure:
                    message = "没读到文件，重新选一次。"
                }
            }
            .task(id: thumbItem?.itemIdentifier) {
                guard let item = thumbItem,
                      let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let jpeg = image.jpegData(compressionQuality: 0.85)
                else { return }
                thumbImage = image
                thumbData = jpeg
            }
            .task(id: videoItem?.itemIdentifier) {
                guard let item = videoItem,
                      let data = try? await item.loadTransferable(type: Data.self)
                else { return }
                videoData = data
            }
        }
    }

    /// 增加流程（顺序固定）：传包 → 传图 → 传视频（可选）→ 追加条目并推表。
    @MainActor
    private func add() async {
        guard let token = accountStore.loadToken() else {
            message = "先在管理员页保存 GitHub 钥匙。"
            return
        }
        guard let packageData = tendiesData else { return }
        // 缩略图没选时，用包里的背景图自动生成一张，别卡在必填上。
        var thumbToUpload = thumbData
        if thumbToUpload == nil {
            thumbToUpload = Self.autoThumbnail(from: packageData)
        }
        guard let imageData = thumbToUpload else {
            message = "缩略图没生成，手动选一张图再试。"
            return
        }
        let id = CatalogStore.safeID(from: tendiesName)
        guard !store.items.contains(where: { $0.id == id }) else {
            message = "已有同名壁纸，换个文件名。"
            return
        }
        busy = true
        defer { busy = false }
        let parsedTags = tags
            .components(separatedBy: CharacterSet(charactersIn: ",，、"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let finalTags = parsedTags.isEmpty ? ["动漫"] : parsedTags
        do {
            try await store.uploadWallpaperFile(name: "\(id).tendies", data: packageData, token: token)
            try await store.uploadWallpaperFile(name: "\(id)-thumb.jpg", data: imageData, token: token)
            var previewURL = ""
            if let videoData {
                let videoName = "\(id)-preview.\(Self.videoExtension(for: videoItem))"
                try await store.uploadWallpaperFile(name: videoName, data: videoData, token: token)
                previewURL = CatalogStore.wallpapersRawBase + videoName
            }
            let newItem = CatalogItem(
                id: id, title: title.trimmingCharacters(in: .whitespaces), tags: finalTags,
                thumbnailURL: CatalogStore.wallpapersRawBase + "\(id)-thumb.jpg",
                previewURL: previewURL,
                packageURL: CatalogStore.wallpapersRawBase + "\(id).tendies",
                pinned: false, downloads: 0)
            try await store.pushCatalog(store.items + [newItem], token: token)
            onAdded()
        } catch {
            message = "没推上去：\(error.localizedDescription)"
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
        guard let entries = try? zip.listEntries(in: plain),
              let info = try? TendiesPackage.inspect(plain, zip: zip)
        else { return nil }
        // 优先背景层目录下的图，其次任意 assets 图片。
        let images = entries.filter {
            $0.contains("/assets/") && [".jpeg", ".jpg", ".png"].contains(($0 as NSString).pathExtension.lowercased())
        }
        guard let picked = images.first(where: { info.backgroundFile.map { $0.contains($0) } ?? false }) ?? images.first,
              let data = try? zip.readEntry(picked, in: plain),
              let image = UIImage(data: data)
        else { return nil }
        // 最长边压到 720，控制封面图体积。
        let maxSide: CGFloat = 720
        let w = image.size.width, h = image.size.height
        let ratio = min(maxSide / max(w, 1), maxSide / max(h, 1), 1)
        let scaled = UIGraphicsImageRenderer(size: CGSize(width: w * ratio, height: h * ratio)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: w * ratio, height: h * ratio))
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
        .onAppear {
            if let url = URL(string: item.previewURL) {
                player = AVPlayer(url: url)
            }
        }
    }
}

