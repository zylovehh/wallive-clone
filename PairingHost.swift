// PairingHost.swift
// 真本机配对：照 AirCard-iOS 开源项目（MIT）的 PairingController 移植。
// 流程：请求本地网络权限 → 静音音频保活 → 后台线程跑 al_pairing_run_host
// → 就绪回调发 Bonjour 广播 → 握手到一半回调给 6 位 PIN，界面显示出来
// → 用户去“设置 › 隐私与安全 › 开发者模式 › 与壁纸安装器配对”输 PIN
// → 握手完成，配对文件落到 App 沙盒 Documents/wallive-pairing.plist。
// 注意：PIN 是 App 显示、用户去设置里输，不是反过来。
// 本文件不含广告 SDK、不含解锁逻辑、不含任何密钥值（密钥只在 Rust 层内存里）。

import Foundation
import AVFAudio
import Network
import AirliftFFI

/// 本机配对主机（单例，供状态页使用）。
@MainActor
final class PairingHost: ObservableObject {

    static let shared = PairingHost()

    // 主机名会显示在设置的配对界面里（“与壁纸安装器配对”），用咱们自己的名字。
    // model 照抄 AirCard 的做法，让手机以为对面是一台 Mac。
    private let hostName = "壁纸安装器"
    private let hostModel = "Mac17,7"
    private let bindAddress = "0.0.0.0"

    private var netService: NetService?
    private let localNetwork = LocalNetworkAuthorization()
    private let keepAlive = KeepAlive()

    @Published private(set) var running = false
    @Published var pairingStatus: String = "未开始"
    @Published var pairingPIN: String? = nil

    /// 配对文件固定落点（和 AppState.pairingFileURL 同一个文件，安装直接用它）。
    static var pairingFilePath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallive-pairing.plist").path
    }

    /// 存过的 alt_irk：让主机身份在多次配对间保持稳定，配对过的手机还认得它。
    private static let altIRKKey = "wallivePairingHostAltIRK"
    nonisolated private static var storedAltIRK: String {
        get { UserDefaults.standard.string(forKey: altIRKKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: altIRKKey) }
    }

    private var pairContinuation: CheckedContinuation<String, Error>?

    enum PairingError: LocalizedError {
        case busy
        case zeroBytes
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "配对正在进行中，稍等一下。"
            case .zeroBytes: return "配对生成了空文件：请先在设置里确认配对，再试一次。"
            case let .failed(msg): return msg
            }
        }
    }

    /// 启动配对主机并等结果：成功返回配对文件路径，失败抛原始错误。
    func startAndWait() async throws -> String {
        if running {
            softCancel()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await withCheckedThrowingContinuation { cont in
            pairContinuation = cont
            start()
        }
    }

    /// 取消进行中的配对。
    func softCancel() {
        stopAdvertising()
        keepAlive.stopAll()
        running = false
        pairingPIN = nil
        pairingStatus = "已取消"
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<String, Error>) {
        guard let cont = pairContinuation else { return }
        pairContinuation = nil
        cont.resume(with: result)
    }

    func start() {
        stopAdvertising()
        keepAlive.stopAll()
        running = true
        pairingPIN = nil
        pairingStatus = "正在启动本机配对…"

        Task {
            _ = await localNetwork.request()
            guard running else { return }
            keepAlive.startAudio()
            pairingStatus = "正在广播…请打开设置去配对"
            runHost()
        }
    }

    // MARK: - 跑 Rust 配对主机（后台线程，会阻塞直到配对完成或失败）

    private func runHost() {
        let bind = bindAddress
        let name = hostName
        let model = hostModel
        let outPath = Self.pairingFilePath
        let altIRK = Self.storedAltIRK
        nonisolated(unsafe) let ctx = UnsafeMutableRawPointer(
            Unmanaged.passRetained(self).toOpaque()
        )

        DispatchQueue.global(qos: .userInitiated).async {
            var result = ALPairResult()
            let rc = bind.withCString { bindC in
                name.withCString { nameC in
                    model.withCString { modelC in
                        outPath.withCString { outC in
                            altIRK.withCString { irkC in
                                al_pairing_run_host(
                                    bindC, 0, nameC, modelC, outC, irkC,
                                    pairReadyCallback, pairPinCallback, ctx, &result)
                            }
                        }
                    }
                }
            }

            let outcome: Outcome
            if rc == 0 {
                let issued = cStr(result.host_alt_irk_hex)
                if !issued.isEmpty { Self.storedAltIRK = issued }
                let devName = cStr(result.device_name)
                let filePath = cStr(result.pairing_file_path)
                outcome = .success(
                    name: devName.isEmpty ? "iPhone" : devName,
                    path: filePath.isEmpty ? outPath : filePath
                )
            } else {
                let msg = cStr(result.error)
                outcome = .failure(msg.isEmpty ? "配对失败（rc=\(rc)）" : msg)
            }
            al_pairing_result_free(&result)

            DispatchQueue.main.async {
                Unmanaged<PairingHost>.fromOpaque(ctx).release()
                self.finish(outcome)
            }
        }
    }

    private enum Outcome {
        case success(name: String, path: String)
        case failure(String)
    }

    private func finish(_ outcome: Outcome) {
        stopAdvertising()
        // 多保活 5 秒：防止用户从设置切回来之前 App 被系统杀掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.keepAlive.stopAll()
        }
        running = false
        pairingPIN = nil

        switch outcome {
        case let .success(name, path):
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            if size == 0 {
                pairingStatus = "失败：配对文件是空的"
                resolve(.failure(PairingError.zeroBytes))
            } else {
                pairingStatus = "已配对：\(name)（\(size) 字节）"
                resolve(.success(path))
            }
        case let .failure(message):
            pairingStatus = "失败：\(message)"
            resolve(.failure(PairingError.failed(message)))
        }
    }

    // MARK: - Bonjour 广播

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        pairingStatus = "正在广播…请打开设置 › 隐私与安全 › 开发者模式去配对"
    }

    fileprivate func presentPin(_ pin: String) {
        pairingPIN = pin
        pairingStatus = "请去设置 › 隐私与安全 › 开发者模式 › 与壁纸安装器配对，输入 PIN：\(pin)"
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }
}

// MARK: - C 回调（Rust 层调回 Swift）

private let pairReadyCallback: ALPairReadyCb = { ctx, serviceID, port, keys, vals, count in
    guard let ctx = ctx, let serviceID = serviceID else { return }
    let controller = Unmanaged<PairingHost>.fromOpaque(ctx).takeUnretainedValue()
    let id = String(cString: serviceID)

    var txt: [String: Data] = [:]
    if let keys = keys, let vals = vals {
        for i in 0..<Int(count) {
            guard let k = keys[i], let v = vals[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }
    DispatchQueue.main.async {
        controller.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
    }
}

private let pairPinCallback: ALPairPinCb = { pin, ctx in
    guard let ctx = ctx, let pin = pin else { return }
    let controller = Unmanaged<PairingHost>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    DispatchQueue.main.async {
        controller.presentPin(pinString)
    }
}

private func cStr(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
    guard let ptr = ptr else { return "" }
    return String(cString: ptr)
}

// MARK: - 保活：静音音频（用户切去设置输 PIN 时 App 不被系统挂起）

@MainActor
final class KeepAlive: NSObject {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var audioRunning = false

    func startAudio() {
        guard !audioRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if player.engine == nil {
                engine.attach(player)
            }
            let format = engine.outputNode.inputFormat(forBus: 0)
            guard format.sampleRate > 0 && format.channelCount > 0 else {
                audioRunning = true
                return
            }

            engine.connect(player, to: engine.mainMixerNode, format: format)

            let frames = max(1024, AVAudioFrameCount(format.sampleRate))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                audioRunning = true
                return
            }
            buffer.frameLength = frames
            if let channelData = buffer.floatChannelData {
                for ch in 0..<Int(format.channelCount) {
                    memset(channelData[ch], 0, Int(frames) * MemoryLayout<Float>.size)
                }
            }

            if !engine.isRunning {
                try engine.start()
            }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            audioRunning = true
        } catch {
            audioRunning = false
        }
    }

    func stopAudio() {
        guard audioRunning else { return }
        audioRunning = false
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        if player.engine != nil {
            engine.detach(player)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func stopAll() {
        stopAudio()
    }
}

// MARK: - 本地网络权限：用一次性的 Bonjour 探针触发系统弹窗

@MainActor
final class LocalNetworkAuthorization {
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Bool, Never>?

    // 必须和 Info.plist 里 NSBonjourServices 的一项对应。
    private let probeType = "_aircardprobe._tcp"

    func request(timeout: TimeInterval = 1.5) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont

            let params = NWParameters.tcp
            params.includePeerToPeer = true

            let listener = try? NWListener(using: params)
            listener?.service = NWListener.Service(name: "WalliveProbe", type: probeType)
            listener?.newConnectionHandler = { $0.cancel() }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated { self?.finish(true) }
                }
            }
            self.listener = listener

            let browser = NWBrowser(for: .bonjour(type: probeType, domain: nil), using: params)
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated { self?.finish(true) }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                if !results.isEmpty {
                    MainActor.assumeIsolated { self?.finish(true) }
                }
            }
            self.browser = browser

            listener?.start(queue: .main)
            browser.start(queue: .main)

            // 短超时：如果之前已经点过允许/拒绝，就直接往下走；
            // 真要弹权限时，配对广播那一步也会再触发一次。
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(true) }
            }
        }
    }

    private func finish(_ authorized: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: authorized)
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
    }
}
