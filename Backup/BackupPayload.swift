import Foundation

/// 要还原进备份的一份文件。对应 GoldenNugget 的 `TweakPayload`，只改名：
///
/// 原名里的 "Tweak" 是 GoldenNugget 那边"改系统设置"的总称，我们这边
/// 只装壁纸，用 `BackupPayload` 更贴切。其余一字不改。
struct BackupPayload: Equatable {
    let domain: String
    let relativePath: String
    /// 放在内存里的内容。`source` 有值时这里是空的。
    let contents: Data
    /// 内容在磁盘上的文件，太大放不进内存时用。调用方保证注入运行时文件还在，
    /// 这个类型自己不删它。
    let source: URL?
    /// 文件行的属主（nil 时按 domain 的实测形状取默认值）。
    let owner: Int?

    init(domain: String, relativePath: String, contents: Data, owner: Int? = nil) {
        self.domain = domain
        self.relativePath = BackupPayload.manifestPath(relativePath)
        self.contents = contents
        self.source = nil
        self.owner = owner
    }

    init(domain: String, relativePath: String, source: URL) {
        self.domain = domain
        self.relativePath = BackupPayload.manifestPath(relativePath)
        self.contents = Data()
        self.source = source
        self.owner = nil
    }

    /// 清单里一行 `relativePath` 的写法：不能带前导斜杠。
    ///
    /// 大多数生产者天生就是这个形状；有两种会把斜杠带进来（桌面版
    /// `restore_path`、PosterBoard 容器遍历从 `/` 起步），带斜杠的行设备会
    /// 直接拒绝：`MBErrorDomain/205 — File path is invalid`。
    /// 在这个类型里统一去掉，任何生产者都放不进带斜杠的路径。
    static func manifestPath(_ relativePath: String) -> String {
        var path = Substring(relativePath)
        while path.first == "/" { path = path.dropFirst() }
        return String(path)
    }

    var label: String { "\(domain)/\(relativePath)" }

    /// 内容从哪来，写日志用。
    var origin: String { source?.lastPathComponent ?? "\(contents.count) B in memory" }

    /// 内容。磁盘上的文件用映射读，不另拷一份——视频壁纸的帧很大，
    /// 映射让内核直接把同一页内存交过去。
    func bytes() throws -> Data {
        guard let source else { return contents }
        do {
            return try Data(contentsOf: source, options: .mappedIfSafe)
        } catch {
            throw BackupError("备份文件 \(label) 读不出来（\(source.lastPathComponent)：\(error.localizedDescription)），注入已停。")
        }
    }

    /// 内容大小，不读文件。
    var byteCount: Int {
        guard let source else { return contents.count }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size
    }
}
