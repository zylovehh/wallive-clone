// CatalogModel.swift
// 目录数据：一条壁纸的元数据、目录拉取、已下载管理。
// 目录表 catalog.json 放在仓库根目录，App 打开时按分发线路顺序拉取
// （jsDelivr Fastly → jsDelivr Gcore → 仓库 raw 兜底），国内访问走前两条快线；
// 全部失败就显示空状态，不崩。壁纸包、预览视频、缩略图放仓库 wallpapers/ 目录。
// 管理端推完目录/传完壁纸后，自动清一下 CDN 缓存，用户端马上能看到新内容。

import Foundation

/// 目录里的一张壁纸：标题、标签、缩略图、预览视频、壁纸包地址，
/// 再加管理员置顶（pinned）和下载数（downloads）。
/// 排序规则（见 fetch）：置顶先排，置顶里按目录表顺序；不置顶的按下载数从多到少；
/// 下载数相同按目录表顺序。新上传的壁纸管理员置顶后就排最上边。
/// 下载数目前是目录表里的数字，由管理员改；App 里点下载不会自动加总，
/// 因为没有服务器记账，以后接了服务器再改成自动计数。
struct CatalogItem: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let tags: [String]
    let thumbnailURL: String
    let previewURL: String
    let packageURL: String
    let pinned: Bool
    let downloads: Int

    enum CodingKeys: String, CodingKey {
        case id, title, tags, pinned, downloads
        case thumbnailURL = "thumbnail"
        case previewURL = "preview"
        case packageURL = "package"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        tags = try c.decode([String].self, forKey: .tags)
        thumbnailURL = try c.decode(String.self, forKey: .thumbnailURL)
        previewURL = try c.decode(String.self, forKey: .previewURL)
        packageURL = try c.decode(String.self, forKey: .packageURL)
        // 老目录表没有这两个字段时默认不置顶、下载数 0，不让旧表解码失败。
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
    }

    /// 管理员改目录时直接拼一张新卡（改置顶、增加都用这个，不走解码）。
    init(id: String, title: String, tags: [String], thumbnailURL: String, previewURL: String, packageURL: String, pinned: Bool, downloads: Int) {
        self.id = id
        self.title = title
        self.tags = tags
        self.thumbnailURL = thumbnailURL
        self.previewURL = previewURL
        self.packageURL = packageURL
        self.pinned = pinned
        self.downloads = downloads
    }
}

/// catalog.json 的顶层结构。
struct CatalogDocument: Decodable {
    let items: [CatalogItem]
}

/// 目录拉取/下载失败原因（带中文说明，免得 404 也报“格式不对”）。
enum CatalogError: LocalizedError {
    case notFound
    case fileNotFound
    var errorDescription: String? {
        switch self {
        case .notFound: return "目录表没找到（请检查目录地址）"
        case .fileNotFound: return "壁纸文件没找到（可能还没上传）"
        }
    }
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
    /// 目录/壁纸分发线路，按顺序尝试：jsDelivr Fastly（国内快线）→
    /// jsDelivr Gcore（备胎）→ 仓库 raw 地址（兜底，前面全挂才用它）。
    /// 改仓库名或分支要同步改这里。
    static let catalogHosts = [
        "https://fastly.jsdelivr.net/gh/zylovehh/wallive-catalog@main",
        "https://gcore.jsdelivr.net/gh/zylovehh/wallive-catalog@main",
        "https://raw.githubusercontent.com/zylovehh/wallive-catalog/main",
    ]

    /// 目录表地址（主线路；实际拉取在 fetch 里按 catalogHosts 顺序尝试）。
    static let catalogURLString = catalogHosts[0] + "/" + catalogPath

    /// 目录仓库（公开目录仓库，管理员改置顶、增删时推到这里）。
    static let catalogRepo = "zylovehh/wallive-catalog"
    static let catalogPath = "catalog.json"
    static let wallpapersDir = "wallpapers"
    /// 新壁纸写进目录表的地址前缀（与主线路一致；下载实际按目录表里的地址走）。
    static let wallpapersRawBase = catalogHosts[0] + "/wallpapers/"

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

    /// 拉目录表：按线路顺序尝试（Fastly → Gcore → 仓库 raw），
    /// 第一条通的生效；全失败就留空 + 报错文案，绝不崩。
    func fetch() async {
        loading = true
        defer { loading = false }
        var lastError: Error?
        for host in Self.catalogHosts {
            guard var components = URLComponents(string: host + "/" + Self.catalogPath) else { continue }
            // 时间戳参数：让运营商/CDN 中间缓存无法命中旧目录（部分线路缓存宽限长达 7 天）。
            components.queryItems = [URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970)))]
            guard let url = components.url else { continue }
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw CatalogError.notFound
                }
                let doc = try JSONDecoder().decode(CatalogDocument.self, from: data)
                items = Self.sortedItems(doc.items)
                errorMessage = ""
                return
            } catch {
                lastError = error
            }
        }
        items = []
        errorMessage = "目录没拉到：\(lastError?.localizedDescription ?? "所有线路都不可用")"
    }

    /// 下载一张壁纸：存到沙盒并记入已下载，成功返回包数据（供安装页直接用）。
    /// 下载中、失败都不抛崩溃，失败只写 errorMessage。
    func download(_ item: CatalogItem) async -> Data? {
        guard let url = URL(string: item.packageURL),
              !downloadingIDs.contains(item.id) else { return nil }
        downloadingIDs.insert(item.id)
        defer { downloadingIDs.remove(item.id) }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw CatalogError.fileNotFound
            }
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

    /// 排序：置顶在前（置顶内保持目录表顺序），其余按下载数从多到少，
    /// 下载数相同保持目录表顺序（序号 tiebreak 保证稳定）。
    static func sortedItems(_ input: [CatalogItem]) -> [CatalogItem] {
        input.enumerated().sorted { a, b in
            if a.element.pinned != b.element.pinned {
                return a.element.pinned
            }
            if a.element.downloads != b.element.downloads {
                return a.element.downloads > b.element.downloads
            }
            return a.offset < b.offset
        }.map { $0.element }
    }

    // MARK: - 管理员改目录（推到 GitHub 仓库）

    /// 目录推送失败原因（带中文说明）。
    enum PushError: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .http(let code):
                let hint: String
                switch code {
                case 401: hint = "钥匙失效了，去管理员页重新保存一把"
                case 403: hint = "这把钥匙没有写权限，检查授权范围"
                case 409, 422: hint = "仓库刚有新改动没同步上，稍等几秒再操作一次"
                case 404: hint = "仓库里没找到要写的文件"
                default: hint = "网络或服务暂时不给力"
                }
                return "推到仓库失败：\(hint)（状态码 \(code)）"
            }
        }
    }

    /// 把一整份目录表推到仓库（改置顶、增删都走这里），成功后刷新本机目录顺序。
    func pushCatalog(_ newItems: [CatalogItem], token: String) async throws {
        let dicts: [[String: Any]] = newItems.map { item in
            ["id": item.id, "title": item.title, "tags": item.tags,
             "thumbnail": item.thumbnailURL, "preview": item.previewURL,
             "package": item.packageURL, "pinned": item.pinned, "downloads": item.downloads]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["items": dicts], options: [.withoutEscapingSlashes])
        try await githubPut(
            path: Self.catalogPath, contentBase64: data.base64EncodedString(),
            message: "Update catalog via app", token: token)
        items = Self.sortedItems(newItems)
        errorMessage = ""
        // 推完顺手清 CDN 缓存，用户端马上能看到新目录（失败不影响主流程）。
        await purgeCDNCache(paths: [Self.catalogPath])
    }

    /// 上传一个壁纸文件到仓库 wallpapers/ 目录（已有同名就覆盖，重试不报错）。
    /// progress：上传进度回调（0~1，可能从非主线程调用），nil 表示不关心进度。
    func uploadWallpaperFile(name: String, data: Data, token: String,
                             progress: ((Double) -> Void)? = nil) async throws {
        try await githubPut(
            path: "\(Self.wallpapersDir)/\(name)", contentBase64: data.base64EncodedString(),
            message: "Upload \(name) via app", token: token, progress: progress)
        // 清掉该文件的 CDN 缓存（目录本身的缓存由随后的 pushCatalog 统一清）。
        await purgeCDNCache(paths: ["\(Self.wallpapersDir)/\(name)"])
    }

    /// 让 CDN 缓存失效（best effort）：逐条请求 purge 接口，失败静默忽略，
    /// 不影响推目录主流程。下次用户拉取时 CDN 会回源拿最新内容。
    private func purgeCDNCache(paths: [String]) async {
        for path in paths {
            guard let url = URL(string:
                "https://purge.jsdelivr.net/gh/\(Self.catalogRepo)@main/\(path)")
            else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// GitHub contents 接口地址。
    private func githubContentsURL(path: String) -> URL {
        URL(string: "https://api.github.com/repos/\(Self.catalogRepo)/contents/\(path)")!
    }

    /// 读仓库里某个文件的当前版本标识（sha），文件不存在返回 nil（不是错）。
    private func githubSHA(path: String, token: String) async throws -> String? {
        var request = URLRequest(url: githubContentsURL(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WalliveClone", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw PushError.http(status) }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = dict["sha"] as? String
        else { throw PushError.http(status) }
        return sha
    }

    /// 写（新建或覆盖）仓库里某个文件：内容先转 base64；已有文件要带上它的 sha 才能覆盖。
    /// 连续操作（删除/置顶连着点）时接口偶尔报 409 版本冲突，自动等一拍重取再推，最多重试两次。
    private func githubPut(path: String, contentBase64: String, message: String, token: String,
                           progress: ((Double) -> Void)? = nil) async throws {
        let baseBody: [String: Any] = ["message": message, "content": contentBase64]
        var lastStatus = 0
        for attempt in 0..<3 {
            var body = baseBody
            if let sha = try await githubSHA(path: path, token: token) {
                body["sha"] = sha
            }
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            var request = URLRequest(url: githubContentsURL(path: path))
            request.httpMethod = "PUT"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("WalliveClone", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
            let (data, response): (Data, URLResponse)
            if let progress {
                // 带进度的上传：每次发出数据块都会回传一次已传比例。
                let delegate = UploadProgressDelegate(handler: progress)
                let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
                (data, response) = try await session.data(for: request)
                session.finishTasksAndInvalidate()
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastStatus = status
            if status == 200 || status == 201 { return }
            // 版本冲突就等一小拍重试；其他错直接抛。
            guard (status == 409 || status == 422), attempt < 2 else { break }
            try await Task.sleep(nanoseconds: 900_000_000)
        }
        throw PushError.http(lastStatus)
    }

    /// id 转安全串：只留字母数字、下划线、横线，其余换成下划线（增加壁纸时用文件名当 id）。
    static func safeID(from name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return cleaned.isEmpty ? "wallpaper" : cleaned
    }

    /// id 转安全文件名：只留字母数字、下划线、横线，其余换成下划线。
    private func safeFileName(for id: String) -> String {
        Self.safeID(from: id) + ".tendies"
    }
}

/// 上传进度回调的辅助类：URLSession 每发出一块数据就触发一次，把已传比例交给外面。
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let handler: (Double) -> Void

    init(handler: @escaping (Double) -> Void) {
        self.handler = handler
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        handler(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

