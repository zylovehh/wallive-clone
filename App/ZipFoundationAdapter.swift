// ZipFoundationAdapter.swift
// ZipEditing 的 ZIPFoundation 实现（SPM 引入，无其他依赖）。
// 读：内存 Archive + consumer 抽取；写：临时目录 + 文件 Archive（STORE），
// 再读回 Data。显式目录条目用 provider 方式写；拒绝包外路径（防 Zip Slip）。

import Foundation
import ZIPFoundation

public struct ZipFoundationAdapter: ZipEditing {
    public init() {}

    public func listEntries(in archive: Data) throws -> [String] {
        guard let zip = Archive(data: archive, accessMode: .read) else {
            throw AdapterError.notAnArchive
        }
        return zip.map { $0.path }
    }

    public func readEntry(_ path: String, in archive: Data) throws -> Data {
        guard let zip = Archive(data: archive, accessMode: .read) else {
            throw AdapterError.notAnArchive
        }
        guard let entry = zip.first(where: { $0.path == path }) else {
            throw AdapterError.entryNotFound(path)
        }
        var out = Data()
        _ = try zip.extract(entry, consumer: { out.append($0) })
        return out
    }

    public func rebuild(entries: [(path: String, data: Data)]) throws -> Data {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallive-clone-rebuild-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let zipURL = tmpDir.appendingPathComponent("out.zip")
        let zip = try Archive(url: zipURL, accessMode: .create)
        for entry in entries {
            let path = entry.path
            guard !path.hasPrefix("/"),
                  !path.split(separator: "/").contains("..") else { continue }
            if path.hasSuffix("/") {
                try zip.addEntry(with: path, type: .directory, uncompressedSize: Int64(0),
                                 provider: { _, _ in Data() })
            } else {
                let fileURL = tmpDir.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try entry.data.write(to: fileURL)
                try zip.addEntry(with: path, relativeTo: tmpDir, compressionMethod: .none)
            }
        }
        return try Data(contentsOf: zipURL)
    }

    public enum AdapterError: Error {
        case notAnArchive
        case entryNotFound(String)
    }
}
