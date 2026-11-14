// UpdateChecker.swift
// 检查更新：打开 App 时拉一下下载页上的 version.json，比版本号，
// 有新版就弹提示框，点“去下载”跳到下载页（https://zylovehh.github.io/wallive-clone/）。
// 侧载 App 自己装不了更新，只能跳网页让用户手动下新包再装。

import SwiftUI

/// 远端 version.json 的结构（放在下载页 docs/version.json 里）。
struct RemoteVersion: Decodable {
    let tag: String
    let number: Double
    let url: String
}

enum UpdateChecker {
    /// 下载页上的 version.json 地址。
    static let versionURL = URL(string: "https://zylovehh.github.io/wallive-clone/version.json")!
    /// 点“去下载”跳去的下载页。
    static let downloadPageURL = URL(string: "https://zylovehh.github.io/wallive-clone/")!

    /// 从 BuildInfo.tag（比如 "V1.5 正式版"）里抠出版本号数字（1.5）。
    static func localVersionNumber() -> Double {
        let tag = BuildInfo.tag
        // 找 "V" 后面的数字，一直读到空格或非数字/点为止。
        guard let vRange = tag.range(of: "V") else { return 0 }
        var numStr = ""
        for ch in tag[vRange.upperBound...] {
            if ch.isNumber || ch == "." {
                numStr.append(ch)
            } else {
                break
            }
        }
        return Double(numStr) ?? 0
    }

    /// 拉 version.json，比版本号。有新版就回传远端信息，没有新版回传 nil。
    /// 拉不到（没网、文件没了）就当没新版，不报错、不打扰。
    static func checkForUpdate() async -> RemoteVersion? {
        guard let url = URL(string: "https://zylovehh.github.io/wallive-clone/version.json") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let remote = try JSONDecoder().decode(RemoteVersion.self, from: data)
            let local = localVersionNumber()
            if remote.number > local {
                return remote
            }
            return nil
        } catch {
            return nil
        }
    }
}

/// 更新提示框：有新版时弹出来，点“去下载”跳下载页，点“以后再说”关掉。
struct UpdateAlertModifier: ViewModifier {
    @Binding var remote: RemoteVersion?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .alert("有新版本", isPresented: Binding(
                get: { remote != nil },
                set: { if !$0 { remote = nil } }
            )) {
                Button("去下载") {
                    if let url = URL(string: remote?.url ?? UpdateChecker.downloadPageURL.absoluteString) {
                        openURL(url)
                    }
                    remote = nil
                }
                Button("以后再说", role: .cancel) {
                    remote = nil
                }
            } message: {
                Text("新版本 \(remote?.tag ?? "") 已发布，点“去下载”到下载页拿新包，再用 AltStore / SideStore 装一次。")
            }
    }
}

extension View {
    func updateAlert(remote: Binding<RemoteVersion?>) -> some View {
        modifier(UpdateAlertModifier(remote: remote))
    }
}
