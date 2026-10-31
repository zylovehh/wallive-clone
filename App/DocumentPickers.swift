// DocumentPickers.swift
// 系统文件选择器（UIDocumentPicker，asCopy 取副本，免安全域处理）。

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 通用文档选择器：选一个文件，回调其 URL（asCopy 副本，可直接读）。
struct DocumentPicker: UIViewControllerRepresentable {
    var contentTypes: [UTType]
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

/// .tendies / .wallive 的 UTI（Info.plist 里已声明导出类型；未解析时退回通用数据）。
enum AppUTTypes {
    static var tendies: UTType {
        UTType("com.mutually.wallpaper.tendies") ?? .data
    }
}
