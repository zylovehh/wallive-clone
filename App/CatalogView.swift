// CatalogView.swift
// 目录页：仿原版发现页，卡片列表 + 搜索 + 分类 + 下载，另有“我的”页。
// 卡片左上角播放键点一下播预览视频（AVKit 系统播放器），平时只显示静态缩略图。
// 下载完直接把包交给安装页（AppState.setPackage + 切到“安装”页），不另起安装逻辑。

import SwiftUI
import AVKit

struct CatalogView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var store = CatalogStore()
    @State private var segment = 0 // 0 发现，1 我的
    @State private var query = ""
    @State private var selectedCategory = "全部"
    @State private var previewItem: CatalogItem?

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

    /// 搜标题或标签 + 分类筛选后的卡片。
    private var filteredItems: [CatalogItem] {
        store.items.filter { item in
            let categoryOK = selectedCategory == "全部"
                || item.tags.contains(selectedCategory)
            let queryOK = query.isEmpty
                || item.title.localizedCaseInsensitiveContains(query)
                || item.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            return categoryOK && queryOK
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
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
            .navigationTitle("目录")
            .task { await store.fetch() }
            .sheet(item: $previewItem) { item in
                PreviewPlayerView(item: item)
            }
        }
    }

    // MARK: - 发现页

    private var discoverView: some View {
        VStack(spacing: 12) {
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
                                onPreview: { previewItem = item },
                                onDownload: { await downloadAndInstall(item) }
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

/// 一张壁纸卡片：缩略图 + 左上角播放键 + 标题 + 标签 + 下载按钮。
private struct CatalogCard: View {
    let item: CatalogItem
    let downloaded: Bool
    let downloading: Bool
    let onPreview: () -> Void
    let onDownload: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
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
                // 预览视频地址能用才显示播放键，点一下播动态预览。
                if URL(string: item.previewURL) != nil {
                    Button(action: onPreview) {
                        Image(systemName: "play.fill")
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    .padding(8)
                }
            }
            .aspectRatio(9 / 16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(item.title)
                .font(.subheadline)
                .lineLimit(2)
            Text(item.tags.map { "#\($0)" }.joined(separator: " "))
                .font(.caption).foregroundStyle(.secondary)

            Button {
                Task { await onDownload() }
            } label: {
                if downloading {
                    ProgressView()
                } else {
                    Label(downloaded ? "已下载" : "下载", systemImage: "arrow.down")
                }
            }
            .buttonStyle(.bordered)
            .disabled(downloading)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.quaternary)
            .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
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
