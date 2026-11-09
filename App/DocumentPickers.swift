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
        // iPad：文件选择器默认走 popover 弹出，没有源头位置会整 App 卡住
        //（iPhone 上全屏弹出所以没事）。点“下载配置文件”在 iPad 上就是这么
        // 卡住的，“＋导入新的壁纸包”用的也是这个选择器，一样会卡。
        // 在创建时就配好源头：用选择器自己的 view 做源头、矩形取其中间，
        // 箭头方向不限制，保证有地方落，不等 update（弹出来时再配就晚了）。
        if let popover = vc.popoverPresentationController {
            popover.sourceView = vc.view
            popover.sourceRect = CGRect(
                x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        // 兜底：万一创建时 view 还没好、源头没配上，这里再补一次。
        if let popover = uiViewController.popoverPresentationController,
           popover.sourceView == nil {
            popover.sourceView = uiViewController.view
            popover.sourceRect = CGRect(
                x: uiViewController.view.bounds.midX,
                y: uiViewController.view.bounds.midY,
                width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
    }

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

    /// 导入壁纸包用的类型白名单：除自家类型和 zip 外，再放行通用数据。
    /// iPad 上隔空投送/网盘落下来的包，系统有时认不出扩展名对应的类型，
    /// 文件在选择器里整条置灰、点不了；放行 .data 后都能选中，
    /// 选错了导入那一步自己报错，不会再卡在选不了。
    static var wallpaperPackage: [UTType] {
        [AppUTTypes.tendies, .zip, .data]
    }
}
