import SwiftUI
import UIKit

/// 导出流程页：管理员门控 + 已装壁纸列表 + 逐条导出 + 系统分享。
/// 支持扫描容器里全部壁纸（不限本 App 安装记录）。
struct ExportFlowView: View {
    @EnvironmentObject private var state: AppState
    @State private var unlocked: Bool

    /// 状态页已通过管理员验证时直接进列表，不用再登一次；默认仍先过管理员验证。
    init(initiallyUnlocked: Bool = false) {
        _unlocked = State(initialValue: initiallyUnlocked)
    }
    @State private var scanning = false
    @State private var scannedBackupDir: URL?
    @State private var descriptors: [InstalledWallpaperExporter.DescriptorInfo] = []
    /// 直读扫到的描述符（scanStore 的结果）；导出时优先直读，不用备份。
    @State private var directEntries: [DirectStoreExporter.DirectDescriptor]?
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
                // 扫描容器：备份一次，列出全部描述符，不只本 App 的安装记录。
                Button {
                    Task { await scan() }
                } label: {
                    Text(scanning ? "扫描中…" : (scannedBackupDir == nil ? "扫描容器里的壁纸" : "重新扫描"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(scanning || exportingUUID != nil)

                // 没配对时给出明确的下一步指引，别让用户卡在报错里。
                if !state.hasPairingFile {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("导出前需要配对记录：先去「回环 VPN」页确认 VPN 已连接，再到「配对记录」页点“生成配对文件”或导入一份。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        NavigationLink(destination: StatusPairingPage()) {
                            Text("去配对记录页").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                    .padding()
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                }

                if !state.installHistory.isEmpty && descriptors.isEmpty && scannedBackupDir == nil {
                    Text("共 \(state.installHistory.count) 条本 App 安装记录，点“导出”生成 .tendies 文件。")
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

                if !descriptors.isEmpty {
                    Text("共扫到 \(descriptors.count) 个壁纸（含其他 App 装入容器的）。")
                        .font(.caption).foregroundStyle(.secondary)
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

    private func scan() async {
        guard state.hasPairingFile else {
            errorMessage = "还没导入配对记录，先去“配对记录”页导入。"
            return
        }
        scanning = true
        exportingUUID = nil
        errorMessage = nil
        // 优先直读商店（逃逸只读，27.0.1 备份 0 文件时的正路）；直读不成再退回备份兜底。
        let (live, directFailReason) = DirectStoreExporter.scanStore(
            log: { InstallLog.shared.append($0) })
        if let live = live, !live.isEmpty {
            directEntries = live
            scannedBackupDir = nil
            descriptors = live.map {
                InstalledWallpaperExporter.DescriptorInfo(uuid: $0.uuid, name: $0.name)
            }
            scanning = false
            return
        }
        if let note = directFailReason {
            InstallLog.shared.append("直读导出不可用（\(note)），改走备份通道。")
        }
        do {
            let dir = try await InstalledWallpaperExporter.fetchBackup(
                pairingPath: state.pairingFileURL.path,
                log: { InstallLog.shared.append($0) })
            directEntries = nil
            scannedBackupDir = dir
            descriptors = try InstalledWallpaperExporter.listAllDescriptors(backupDir: dir)
        } catch {
            errorMessage = "扫描失败：\(error.localizedDescription)"
        }
        scanning = false
    }

    private func export(uuid: String) async {
        guard state.hasPairingFile else {
            errorMessage = "还没导入配对记录，先去“配对记录”页导入。"
            return
        }
        exportingUUID = uuid
        errorMessage = nil
        do {
            let result: InstalledWallpaperExporter.ExportResult
            if let entry = directEntries?.first(where: { $0.uuid == uuid }) {
                // 直读导出：直接读容器，不走备份。
                result = try DirectStoreExporter.exportDescriptor(
                    entry, log: { InstallLog.shared.append($0) })
            } else {
                let dir: URL
                if let cached = scannedBackupDir {
                    dir = cached
                } else {
                    dir = try await InstalledWallpaperExporter.fetchBackup(
                        pairingPath: state.pairingFileURL.path,
                        log: { InstallLog.shared.append($0) })
                    scannedBackupDir = dir
                }
                result = try InstalledWallpaperExporter.exportWallpaper(
                    descriptorUUID: uuid,
                    backupDir: dir,
                    log: { InstallLog.shared.append($0) })
            }
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

/// UIActivityViewController 的 SwiftUI 包装（分享 .tendies 文件用）。
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
