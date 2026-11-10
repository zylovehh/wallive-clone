// InstallView.swift
// 安装：当前包 + 配对记录 → 经特权通道写盘并登记，显示进度与结果。

import SwiftUI
import UIKit
import WebKit

struct InstallView: View {
    @EnvironmentObject private var state: AppState
    @State private var host = "10.7.0.1"
    @State private var installing = false
    @State private var result = ""
    @State private var installLog = ""
    @State private var forceRefresh = true
    @State private var clearing = false
    @State private var clearResult = ""

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
                HStack {
                    TextField("管家地址", text: $host).textFieldStyle(.roundedBorder)
                }
                Toggle("强制刷新缓存", isOn: $forceRefresh)
                Text("开着：装完再写一次偏好，让系统立刻重新索引壁纸。").font(.caption)
                    .foregroundStyle(.secondary)
                Button("安装到锁屏") {
                    Task { await runInstall() }
                }
                .buttonStyle(.borderedProminent)
                // 不配对也能装：按钮只看包和安装状态（没配对时走备份还原路，
                // 直读取表 + 逃逸直写，不碰配对）。
                .disabled(state.packageData == nil || installing)
                Divider()
                Text("清除已安装").font(.headline)
                Text("两步走：先在锁屏长按进图库、上滑删掉那张锁屏，再点下面这个按钮重索引，图库才会刷新掉。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("清除已安装（重索引）") {
                    Task {
                        clearing = true
                        clearResult = ""
                        defer { clearing = false }
                        if await state.clearInstalledRecords(host: host) {
                            clearResult = "已重索引：去锁屏图库看看那张还在不在，还在就把包名告诉我。"
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!state.pairingLoaded || clearing)
                if clearing { ProgressView("正在重索引…") }
                if !clearResult.isEmpty { Text(clearResult).font(.caption) }
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
        if let uuid = await state.install(host: host, forceRefresh: forceRefresh) {
            // V1.6：备用刷新（网页重启桌面）整个去掉，跟 Vellum 对齐——
            // 配对路只认配对刷新；没配对不刷，提示重启手机。
            if state.hasPairingFile {
                result = "安装完成，描述符 UUID：\(uuid)。配对刷新跑完去锁屏看；没确认就重启手机再看。"
            } else {
                // 没配对（V1.10 起）：跟人家一样装完自动刷新桌面。
                result = "安装完成，描述符 UUID：\(uuid)。正在刷新桌面（跟人家一样）——桌面会黑一下自己回来，回来后锁屏长按进图库查看。"
                DesktopRestart.trigger()
            }
        } else if state.statusMessage.isEmpty {
            result = "安装未完成：先去“导入”选包；失败原因看提示或安装日志。"
        }
        installLog = InstallLog.shared.tail(200)
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

