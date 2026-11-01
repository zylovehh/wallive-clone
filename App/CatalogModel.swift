// CatalogModel.swift
// 目录数据：一条壁纸的元数据、目录拉取、已下载管理。
// 目录表 catalog.json 放在仓库根目录，App 打开时从 raw 地址拉取；
// 拉不到就显示空状态，不崩。壁纸包、预览视频、缩略图放仓库 wallpapers/ 目录。

import Foundation

/// 目录里的一张壁纸：标题、标签、缩略图、预览视频、壁纸包地址。
struct CatalogItem: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let tags: [String]
    let thumbnailURL: String
    let previewURL: String
    let packageURL: String

    enum CodingKeys: String, CodingKey {
        case id, title, tags
        case thumbnailURL = "thumbnail"
        case previewURL = "preview"
        case packageURL = "package"
    }
}

/// catalog.json 的顶层结构。
struct CatalogDocument: Decodable {
    let items: [CatalogItem]
}

/// 已下载的一张壁纸：元数据 + 本地文件名（存在沙盒里，供“我的”页列出）。
struct DownloadedItem: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let tags: [String]
    let fileName: String
    let downloadedAt: Date
}

/// 目录仓库：拉目录表、下载壁纸包、管理已下载列表。
/// 已下载记录存在 UserDefaults，文件存在沙盒 Documents/downloaded-wallpapers/。
@MainActor
final class CatalogStore: ObservableObject {
    /// 目录表地址（公开仓库 raw 地址，改仓库名或分支要同步改这里）。
    static let catalogURLString =
        "https://raw.githubusercontent.com/zyl.../wallive-clone/main/catalog.json"

    @Published private(set) var items: [CatalogItem] = []
    @Published private(set) var downloaded: [DownloadedItem] = []
    @Published private(set) var downloadingIDs: Set<String> = []
    @Published var errorMessage = ""
    @Published private(set) var loading = false

    private let downloadedDefaultsKey = "wallive-clone-downloaded"

    init() {
        loadDownloaded()
    }

    /// 已下载文件存放目录（沙盒 Documents/downloaded-wallpapers/）。
    var downloadedDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("downloaded-wallpapers")
    }

    /// 某张壁纸是否已下载（记录在且文件还在）。
    func isDownloaded(_ item: CatalogItem) -> Bool {
        guard downloaded.contains(where: { $0.id == item.id }) else { return false }
        return FileManager.default.fileExists(atPath: localURL(for: item).path)
    }

    /// 已下载条目对应的本地文件地址。
    func localURL(for item: CatalogItem) -> URL {
        downloadedDirectory.appendingPathComponent(safeFileName(for: item.id))
    }

    /// 已下载条目对应的本地文件地址（按记录）。
    func localURL(for record: DownloadedItem) -> URL {
        downloadedDirectory.appendingPathComponent(record.fileName)
    }

    /// 拉目录表：失败就留空 + 报错文案，绝不崩。
    func fetch() async {
        guard let url = URL(string: Self.catalogURLString) else { return }
        loading = true
        defer { loading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let doc = try JSONDecoder().decode(CatalogDocument.self, from: data)
            items = doc.items
            errorMessage = ""
        } catch {
            items = []
            errorMessage = "目录没拉到：\(error.localizedDescription)"
        }
    }

    /// 下载一张壁纸：存到沙盒并记入已下载，成功返回包数据（供安装页直接用）。
    /// 下载中、失败都不抛崩溃，失败只写 errorMessage。
    func download(_ item: CatalogItem) async -> Data? {
        guard let url = URL(string: item.packageURL),
              !downloadingIDs.contains(item.id) else { return nil }
        downloadingIDs.insert(item.id)
        defer { downloadingIDs.remove(item.id) }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try FileManager.default.createDirectory(
                at: downloadedDirectory, withIntermediateDirectories: true)
            try data.write(to: localURL(for: item), options: .atomic)
            let record = DownloadedItem(
                id: item.id, title: item.title, tags: item.tags,
                fileName: safeFileName(for: item.id), downloadedAt: Date())
            downloaded.removeAll { $0.id == item.id }
            downloaded.insert(record, at: 0)
            saveDownloaded()
            errorMessage = ""
            return data
        } catch {
            errorMessage = "下载失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 删除一张已下载：文件和记录一起删。
    func delete(_ record: DownloadedItem) {
        try? FileManager.default.removeItem(at: localURL(for: record))
        downloaded.removeAll { $0.id == record.id }
        saveDownloaded()
    }

    /// 读已下载记录，并把文件已不在的记录清掉。
    private func loadDownloaded() {
        guard let data = UserDefaults.standard.data(forKey: downloadedDefaultsKey),
              let records = try? JSONDecoder().decode([DownloadedItem].self, from: data)
        else { return }
        downloaded = records.filter {
            FileManager.default.fileExists(atPath: localURL(for: $0).path)
        }
        if downloaded.count != records.count { saveDownloaded() }
    }

    private func saveDownloaded() {
        if let data = try? JSONEncoder().encode(downloaded) {
            UserDefaults.standard.set(data, forKey: downloadedDefaultsKey)
        }
    }

    /// id 转安全文件名：只留字母数字、下划线、横线，其余换成下划线。
    private func safeFileName(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = id.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return (cleaned.isEmpty ? "wallpaper" : cleaned) + ".tendies"
    }
}
