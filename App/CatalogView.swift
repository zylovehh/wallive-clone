// CatalogView.swift
// 目录浏览：拉 walllive.18ir.cn 目录，点条目下载（有直链时）并设为当前包。

import Foundation
import SwiftUI

struct CatalogView: View {
    @EnvironmentObject private var state: AppState
    @State private var items: [CatalogItem] = []
    @State private var page = 1
    @State private var loading = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(items.indices, id: \.self) { i in
                    let item = items[i]
                    Button {
                        Task { await download(item) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title(of: item)).lineLimit(2)
                            HStack {
                                Text(item.mediaType ?? "未知类型")
                                if (item.downURL ?? "").isEmpty {
                                    Text("无下载直链").foregroundStyle(.secondary)
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !items.isEmpty {
                    Button("加载下一页") {
                        page += 1
                        Task { await load() }
                    }
                }
            }
            .navigationTitle("目录")
            .toolbar {
                Button("刷新") {
                    page = 1
                    Task { await load() }
                }
            }
            .task { await load() }
            if loading { ProgressView("加载中…") }
            if !message.isEmpty {
                Text(message).foregroundStyle(.red).font(.caption).padding()
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await CatalogClient().fetchPage(page)
            if page == 1 {
                items = result.items
            } else {
                items += result.items
            }
            message = result.items.isEmpty ? "这页没有条目（分页字段以真实响应为准）" : ""
        } catch {
            message = "目录加载失败：\(error.localizedDescription)"
        }
    }

    private func download(_ item: CatalogItem) async {
        guard let urlString = item.downURL, !urlString.isEmpty,
              let url = URL(string: urlString) else {
            message = "这条没有下载直链（实测 down_url 为空），请走“导入”选本地包。"
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            state.setPackage(data)
            state.selectedTab = 2
        } catch {
            message = "下载失败：\(error.localizedDescription)"
        }
    }

    private func title(of item: CatalogItem) -> String {
        for key in ["title", "name", "id"] {
            if let v = item.raw[key]?.value as? String, !v.isEmpty { return v }
            if let v = item.raw[key]?.value as? Int { return String(v) }
        }
        return "未命名"
    }
}
