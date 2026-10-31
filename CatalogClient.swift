// CatalogClient.swift
// 干净重写：壁纸目录客户端（只读目录，不含会员、不含广告、不含解锁逻辑）。
//
// 服务器（已确认存在的接口，见 wallive-re 逆向记录）：
//   https://walllive.18ir.cn/api/get_wallpaper.php   目录（分页，共约 494 条）
//   https://walllive.18ir.cn/api/ios_download_file.php  文件下载（参数未确认，见下）
//   其他接口（启动公告、教程、App 状态、会员订单、时间、诊断上报等）与复刻的
//   核心功能无关，本文件不实现；会员/广告相关接口一律不接。
//
// 已确认的目录条目字段（2026-10-31 实测）：
//   media_type = video / image；down_url 在实测页为空。
// 其余字段名（条目 id、标题、媒体直链等）未从本次逆向中确认，
// 下方模型用可选字段 + 原始字典兜底，对照一次真实响应即可补齐。
// 注意：本次复刻评估中一次公开目录请求因网络原因未取回，
// 模型字段需以真实响应为准，不要把未确认字段当定论。

import Foundation

/// 目录条目：只取已确认字段，其余全部可选。
public struct CatalogItem: Decodable {
    public let mediaType: String?
    public let downURL: String?
    /// 原始 JSON（未确认字段从这里取，避免模型一改就崩）。
    public let raw: [String: AnyDecodableValue]

    enum CodingKeys: String, CodingKey {
        case mediaType = "media_type"
        case downURL = "down_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        downURL = try container.decodeIfPresent(String.self, forKey: .downURL)
        // 保留全部原始字段。
        let single = try decoder.singleValueContainer()
        let dict = try single.decode([String: AnyDecodableValue].self)
        raw = dict
    }
}

/// 宽松 JSON 值（用于 raw 字典）。
public struct AnyDecodableValue: Decodable {
    public let value: Any
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode([AnyDecodableValue].self) { value = v.map { $0.value } }
        else if let v = try? container.decode([String: AnyDecodableValue].self) { value = v.mapValues { $0.value } }
        else { value = NSNull() }
    }
}

/// 目录响应：分页结构以真实响应为准；这里只做最宽松的解析。
public struct CatalogPage: Decodable {
    public let items: [CatalogItem]
    public let total: Int?

    // 常见分页字段名都试一遍；真实字段名以实测响应为准。
    enum CodingKeys: String, CodingKey {
        case data, list, items, total, count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let items = try? container.decode([CatalogItem].self, forKey: .data) {
            self.items = items
        } else if let items = try? container.decode([CatalogItem].self, forKey: .list) {
            self.items = items
        } else if let items = try? container.decode([CatalogItem].self, forKey: .items) {
            self.items = items
        } else {
            self.items = []
        }
        total = (try? container.decode(Int.self, forKey: .total))
            ?? (try? container.decode(Int.self, forKey: .count))
    }
}

/// 目录客户端。
public struct CatalogClient {
    public static let baseURL = URL(string: "https://walllive.18ir.cn")!
    public static let wallpaperPath = "/api/get_wallpaper.php"
    /// 下载接口（存在，但参数名未确认；不要猜参数，先对照真实请求再补）。
    public static let downloadFilePath = "/api/ios_download_file.php"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 取一页目录。分页参数名以真实请求为准，默认用 page（待确认）。
    public func fetchPage(_ page: Int) async throws -> CatalogPage {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(Self.wallpaperPath), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "page", value: String(page))]
        let (data, _) = try await session.data(from: components.url!)
        return try JSONDecoder().decode(CatalogPage.self, from: data)
    }
}
