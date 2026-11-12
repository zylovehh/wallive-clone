// InstallView.swift
// 安装：当前包 + 配对记录 → 经特权通道写盘并登记，显示进度与结果。

import SwiftUI
import UIKit
import WebKit

struct InstallView: View {
    @EnvironmentObject private var state: AppState
    /// 安装方式（Drift 同款分段控件）：自动=看配对记录（没配对走直刷、
    /// 有配对走隧道）；直刷=逃逸直写；隧道=配对隧道写盘。
    private enum Method {
        case auto, direct, tunnel
    }
    @State private var method: Method = .auto
    @State private var installing = false
    @State private var result = ""
    @State private var installLog = ""

    /// 本机系统版本拆成数字（如 27.2.1 → [27, 2, 1]）；读不到按空算。
    private var versionParts: [Int] {
        UIDevice.current.systemVersion.split(separator: ".").compactMap { Int($0) }
    }
    /// iOS 27.3 起，参照应用在这版标「无可用通道」——直刷这条路未必还行，
    /// 只提醒、不拦安装（咱们的逃逸路在 27.3 上还没真机验证过）。
    private var directMayBeBlocked: Bool {
        let p = versionParts
        guard p.count >= 2 else { return false }
        return p[0] > 27 || (p[0] == 27 && p[1] >= 3)
    }

    /// 分段控件下面的判定说明（照效果图话术）。
    private var methodNote: String {
        let blocked = directMayBeBlocked
            ? "（注意：iOS 27.3 起参照应用标「无可用通道」，直刷未必装得上。）"
            : ""
        switch method {
        case .auto:
            let verdict = state.hasPairingFile
                ? "本机判定：读到了配对文件 → 这次走隧道（先开好回环 VPN）。删掉配对文件再点，就自动改走直刷。"
                : "本机判定：没读到配对文件 → 这次走直刷。导了配对文件再点，就自动改走隧道。"
            return "自动=看本机情况：没配对走直刷，导了配对文件走隧道。判定结果在按钮下面写明。" + verdict + blocked
        case .direct:
            return "手动指定直刷：不管有没有配对文件，都走逃逸直写，不碰配对、不需要 VPN。" + blocked
        case .tunnel:
            let ready = state.hasPairingFile
                ? ""
                : "还没读到配对文件：先去状态页导入配对文件，再走隧道。"
            return "手动指定隧道：走配对隧道写盘。27.2 上隧道必须回环 VPN——先开好 VPN 再点安装。" + ready
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let info = state.packageInfo {
                    Text("待安装：\(info.descriptorUUID)").font(.caption)
                    Text(info.hasRenderingConfiguration ? "含深景开关" : "不含深景开关").font(.caption)
                } else {
                    Text("还没选包：先去“导入”选本地包。")
                        .foregroundStyle(.secondary)
                }
                Text("配对记录：\(state.pairingDescription)").font(.caption)
                    .onAppear { state.refreshPairingStatus() }

                Text("安装方式").font(.headline)
                Picker("安装方式", selection: $method) {
                    Text("自动").tag(Method.auto)
                    Text("直刷").tag(Method.direct)
                    Text("隧道").tag(Method.tunnel)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(methodNote).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("安装") {
                    Task { await runInstall() }
                }
                .buttonStyle(.borderedProminent)
                // 不配对也能装：按钮只看包和安装状态（没配对走直刷）。
                .disabled(state.packageData == nil || installing)
                Text("装完自动刷新：不用注销，锁屏长按进图库就能看到。").font(.caption)
                    .foregroundStyle(.secondary)

                if installing { ProgressView("正在安装…") }
                if !result.isEmpty { Text(result).font(.caption) }
                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage).foregroundStyle(.red).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // V1.14：成功也铺完整日志（用户要求日志记详细些，方便对着看）。
                if !installLog.isEmpty {
                    Text("安装日志（可长按复制）").font(.headline)
                    ScrollView {
                        Text(installLog)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("安装")
        }
    }

    private func runInstall() async {
        installing = true
        result = ""
        installLog = ""
        defer { installing = false }
        // 自动=没配对走直刷、有配对走隧道；手动选定不自动改道（Drift 同款）。
        let channel: InstallChannel
        switch method {
        case .auto: channel = state.hasPairingFile ? .tunnel : .direct
        case .direct: channel = .direct
        case .tunnel: channel = .tunnel
        }
        guard let report = try? await state.installWithReport(
            host: "10.7.0.1", forceRefresh: true, channel: channel) else {
            if state.statusMessage.isEmpty {
                result = "安装未完成：先去“导入”选包；失败原因看提示或安装日志。"
            }
            installLog = InstallLog.shared.tail(200)
            return
        }
        if channel == .tunnel {
            result = tunnelResult(report)
        } else {
            await directResult(report)
        }
        installLog = InstallLog.shared.tail(200)
    }

    /// 隧道结果：读回核对按通道可信度分话术，不把话说满。
    private func tunnelResult(_ report: InstallReport) -> String {
        var text = "安装完成（隧道路），描述符 UUID：\(report.descriptorUUID)。"
        if report.verifyResults.contains(where: { $0.channelUnavailable }) {
            text += "读回通道不可用，写没写进设备没法现场核实——去锁屏图库看，没有就把日志发来。"
        } else if !report.verifyResults.isEmpty, report.verifyResults.allSatisfy({ $0.allPresent }) {
            text += "读回核对在册：描述符已经在商店目录里。"
        } else {
            text += "读回核对没过：描述符缺了东西——把日志发来看。"
        }
        if report.refresh?.confirmed != true {
            text += "配对刷新没确认，重启手机后再去锁屏图库看。"
        }
        return text
    }

    /// 直刷结果（Drift 打头 + 暗号退路）：装完用私有接口把 PosterBoard 应用
    /// 整个唤出来——它一露头系统就重读壁纸，用户上滑关掉卡片即生效；
    /// 私有接口叫不动，退 posterboard:// 暗号（用户拍板保留的退路）；
    /// 暗号也不行就照实说明，不自动压桌面。
    private func directResult(_ report: InstallReport) async {
        let uuid = report.descriptorUUID
        let verify = report.backupSummary ?? ""
        if PosterBoardLauncher.launch() {
            result = "安装完成（直刷路），描述符 UUID：\(uuid)。\(verify)海报界面拉起来了——上滑关掉卡片，锁屏长按进图库查看。"
            installLog = InstallLog.shared.tail(200)
            return
        }
        InstallLog.shared.append("restore: 私有接口没叫动海报应用，退 posterboard:// 暗号。")
        if let posterBoardURL = URL(string: "posterboard://") {
            result = "安装完成（直刷路），描述符 UUID：\(uuid)。\(verify)海报应用马上弹出来——上滑关掉它，锁屏长按进图库查看。"
            UIApplication.shared.open(posterBoardURL) { ok in
                guard !ok else { return }
                // open 的回调不保证主线程；result 是界面状态，必须回主线程改。
                DispatchQueue.main.async {
                    InstallLog.shared.append("restore: 暗号也没叫动，去锁屏长按进图库看装没装上。")
                    result = "安装完成（直刷路），描述符 UUID：\(uuid)。\(verify)海报没叫动——锁屏长按进图库看看装没装上，日志里有调用结果。"
                    installLog = InstallLog.shared.tail(200)
                }
            }
        } else {
            result = "安装完成（直刷路），描述符 UUID：\(uuid)。\(verify)海报没叫动——锁屏长按进图库看看装没装上，日志里有调用结果。"
            installLog = InstallLog.shared.tail(200)
        }
    }
}
/// Drift 同款唤出海报应用：不拼 URL 暗号，直接用私有接口把 PosterBoard
/// 整个打开（Drift 二进制里 openApplicationWithBundleID: 对着
/// com.apple.PosterBoard 调，posterboard:// 一次都没出现过）。
/// 私有接口打头，暗号作退路（用户拍板保留）；同 target 免改工程文件。
enum PosterBoardLauncher {
    /// 唤出成功返回 true；接口不存在、类拿不到或调用报错一律 false，
    /// 由调用方退暗号或照实告知。
    static func launch() -> Bool {
        // LSApplicationWorkspace 是私有类，运行时 NSClassFromString 找。
        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = cls.perform(NSSelectorFromString("defaultWorkspace"))?
                  .takeUnretainedValue() as? NSObject
        else { return false }
        let selector = NSSelectorFromString("openApplicationWithBundleID:")
        // 返回值是 BOOL，不是对象——perform 拿不准，走函数指针原样读。
        guard workspace.responds(to: selector),
              let method = class_getInstanceMethod(type(of: workspace), selector)
        else { return false }
        typealias OpenMethod = @convention(c) (AnyObject, Selector, String) -> Bool
        let open = unsafeBitCast(method_getImplementation(method), to: OpenMethod.self)
        let ok = open(workspace, selector, "com.apple.PosterBoard")
        InstallLog.shared.append("restore: openApplicationWithBundleID: 调用返回 \(ok)。")
        return ok
    }
}
// 只重启桌面，不重启手机。
// 办法按 AirCard 的 NeoSpring 路子（@neonmodder123 与 @skadz108）：
// 用一个全屏网页视图加载特定网页内容，靠网页渲染压力让桌面（SpringBoard）
// 重启，只动桌面，不碰整机重启、不调任何重启手机的接口。
enum DesktopRestart {
    static let neospringHTML = """
<!DOCTYPE html>
<html>
    <body>
        <!-- big credit to @neonmodder123 & @skadz108 (neospring) -->
        <iframe id="frame" srcdoc="" sandbox="allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-presentation allow-scripts"></iframe>
        <script>
            const frame = document.getElementById('frame');
            const funfun = `
                <html>
                <body>
                    <script>
                        const container = document.createElement('div');
                        container.style.cssText = 'perspective: 1px; perspective-origin: 9999999% 9999999%;';
                        document.body.appendChild(container);
                        for (let i = 0; i < 500; i++) {
                            let d = document.createElement('div');
                            d.style.cssText = 'position: absolute; width: 100vw; height: 100vh; backdrop-filter: blur(100px); -webkit-backdrop-filter: blur(100px); transform: translate3d(100000px, 100000px, ' + i + 'px) rotateY(90deg);';
                            container.appendChild(d);
                        }
                        setInterval(() => {
                            navigator.share({ title: 'R', text: 'R'.repeat(100000) }).catch(() => {});
                            let x = new Uint8Array(1024 * 1024 * 10);
                            crypto.getRandomValues(x);
                        }, 0);
                    <\\/script>
                </body>
                </html>
            `;
            frame.srcdoc = funfun;
        </script>
    </body>
</html>
"""

    /// 装完自动调：把全屏网页视图贴到主窗口上，桌面随后重启。
    /// Vellum 同款做法（它没配对时也走这一招）：20 秒内桌面还没重启成
    ///（App 还活着）就把网页撤掉，不让它一直在后台压内存；真重启成了
    /// App 会跟着被杀，撤不撤无所谓。
    static func trigger() {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first else {
                return
            }
            let config = WKWebViewConfiguration()
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            let webView = WKWebView(frame: window.bounds, configuration: config)
            webView.isOpaque = true
            webView.backgroundColor = .black
            window.addSubview(webView)
            webView.loadHTMLString(neospringHTML, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                webView.removeFromSuperview()
            }
        }
    }
}

