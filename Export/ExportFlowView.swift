import SwiftUI

/// 导出流程页：管理员门控 + 已装壁纸列表 + 逐条导出 + 系统分享。
struct ExportFlowView: View {
    @EnvironmentObject private var state: AppState
    @State private var unlocked = false
    @State private var exportingUUID: String?
    @State private var exportedFileURL: URL?
    @State private var showShareSheet = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if unlocked {
                exportList
            } else {
                AdminLoginView {
                    // 仅验证通过后才进入列表，门控不能跳过。
                    unlocked = true
                }
            }
        }
        .navigationTitle("导出已装壁纸")
        .sheet(isPresented: $showShareSheet) {
            if let url = exportedFileURL {
                ActivityShareSheet(items: [url])
            }
        }
    }

    private var exportList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.installHistory.isEmpty {
                    Text("还没有成功安装的记录。")
                        .foregroundStyle(.secondary).font(.caption)
                } else {
                    Text("共 \(state.installHistory.count) 条安装记录，点“导出”生成 .tendies 文件。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(state.installHistory, id: \.self) { uuid in
                        HStack(spacing: 10) {
                            Text(uuid)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            GlassIconButton(title: "导出", systemImage: "square.and.arrow.up") {
                                Task { await export(uuid: uuid) }
                            }
                            .disabled(exportingUUID != nil)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let exportingUUID {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在导出 \(String(exportingUUID.prefix(8)))…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
    }

    private func export(uuid: String) async {
        guard state.hasPairingFile else {
            errorMessage = "还没导入配对记录，先去“配对记录”页导入。"
            return
        }
        exportingUUID = uuid
        errorMessage = nil
        do {
            let result = try await InstalledWallpaperExporter.exportWallpaper(
                descriptorUUID: uuid,
                pairingPath: state.pairingFileURL.path,
                log: { InstallLog.shared.append($0) })
            let url = try Self.writeToExports(result: result)
            exportedFileURL = url
            showShareSheet = true
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
        exportingUUID = nil
    }

    /// 导出包写入沙盒 Documents/exports/，分享面板拿文件 URL。
    private static func writeToExports(result: InstalledWallpaperExporter.ExportResult) throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("exports", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(result.fileName)
        try result.data.write(to: url, options: .atomic)
        return url
    }
}
