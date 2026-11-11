// TendiesPackage.swift
// 干净重写：.tendies / .wallive 包的检查与描述符结构校验。
// 包结构（已验证）：标准 PosterBoard 描述符包，顶层为
//   descriptors/<UUID>/versions/1/contents/<名>.wallpaper/
// 内含 Background / Floating / Foreground 三个 .ca + Wallpaper.plist。
// 本文件不含广告 SDK、不含解锁逻辑、不含 exploit 代码。
//
// 说明：iOS 没有内置 zip 读写，zip 层由 ZipEditing 协议抽象，
// 接入时用 ZIPFoundation 或 SSZipArchive 实现该协议即可。

import Foundation

/// zip 读写抽象（接入方实现；本文件只依赖这个接口，不绑定具体 zip 库）。
public protocol ZipEditing {
    /// 列出包内全部条目路径。
    func listEntries(in archive: Data) throws -> [String]
    /// 读出指定条目的字节。
    func readEntry(_ path: String, in archive: Data) throws -> Data
    /// 返回一个新包：以 entries 为全部内容（用于改名、增删条目后重打）。
    func rebuild(entries: [(path: String, data: Data)]) throws -> Data
}

/// 描述符包的关键信息。
public struct TendiesPackageInfo {
    public let descriptorUUID: String
    public let wallpaperDirectory: String   // contents/<名>.wallpaper
    public let backgroundFile: String?      // 如 7400.WWDC_2022_Background-...ca
    public let floatingFile: String?        // 如 7400.WWDC_2022_Floating-...ca（或 Clownfish_ 前缀版）
    public let foregroundFile: String?
    public let hasRenderingConfiguration: Bool
    public let floatingHasClownfishPrefix: Bool
}

/// 包检查器：识别 WALLIVE1 / 标准 zip，并校验描述符结构。
public enum TendiesPackage {

    public enum Error: Swift.Error {
        case notATendiesPackage
        case missingWallpaperDirectory
        case missingWallpaperPlist
    }

    /// 检查一个包（WALLIVE1 加密包或标准 zip），返回其描述符信息。
    /// WALLIVE1 包会先解密；标准 zip 直接检查。
    public static func inspect(_ data: Data, zip: ZipEditing) throws -> TendiesPackageInfo {
        let plaintext: Data
        if Wallive1Crypto.isWallive1(data) {
            plaintext = try Wallive1Crypto.decrypt(data)
        } else {
            plaintext = data
        }
        return try inspectPlaintextZip(plaintext, zip: zip)
    }

    /// 旧格式判断：包是不是 WWDC22 时代的布局（描述符 7400 / 文件名含 WWDC_2022 / 共用描述符 09E9B685-…）。
    /// iOS 27 读不了这种布局：不转换直接装，不报错但永远不显示。iOS 26 能直接读，不用转。
    public static func isOldFormat(_ data: Data, zip: ZipEditing) -> Bool {
        let plaintext: Data
        if Wallive1Crypto.isWallive1(data) {
            guard let d = try? Wallive1Crypto.decrypt(data) else { return false }
            plaintext = d
        } else {
            plaintext = data
        }
        guard let entries = try? zip.listEntries(in: plaintext) else { return false }
        // 任一 WWDC22 痕迹都算旧格式。
        for e in entries {
            if e.contains("WWDC_2022") || e.contains("WWDC22") { return true }
            if e.contains("09E9B685-7456-4856-9C10-47DF26B76C33") { return true }
        }
        // Wallpaper.plist 里的 identifier 是 7400 也算旧格式。
        if let info = try? inspectPlaintextZip(plaintext, zip: zip) {
            // 描述符 UUID 是共用的 WWDC22 那一个，或壁纸目录名以 7400. 开头。
            if info.descriptorUUID == "09E9B685-7456-4856-9C10-47DF26B76C33" { return true }
            if info.wallpaperDirectory.hasPrefix("7400.") { return true }
        }
        return false
    }

    /// Drift 同款「真布局重造」：旧格式（WWDC22 布局，单个 wallpaper.ca）转换成
    /// iOS 27 能读的新布局（LayeredAnimation，每层一个 .ca 目录，Clownfish 命名）。
    /// 旧做法只换身份不动布局，iOS 27 写进去了也不显示；这里真的拆层重造：
    ///   1. 从旧 wallpaper.ca 的 main.caml 里按 BACKGROUND / FLOATING / FOREGROUND 切层
    ///      （括号深度扫描找配对闭合标签）；
    ///   2. 每层重写独立 main.caml：根层改名 _BACKGROUND 等，图片引用从
    ///      <contents><CGImage src=…/></contents> 简写成 <contents type="CGImage" src=…/>，
    ///      并把该层引用的 assets 挪进自己的目录，带上原 index.xml / assetManifest.caml；
    ///   3. 重写现代 Wallpaper.plist（LayeredAnimation，二进制）与 contents 层 userInfo；
    ///   4. descriptor.identifier 写编号，其余条目原样保留（旧壁纸目录、旧 userInfo 除外）。
    /// 描述符 UUID 与编号保持原样；装包链路（rewriteDescriptorIdentity / renameDescriptorContentsToMatch
    /// 等）会在安装时统一二次改号。返回新包数据（明文 zip；调用方再按需加密）。
    public static func convertingOldFormatToNew(_ data: Data, zip: ZipEditing) throws -> Data {
        let plaintext: Data
        if Wallive1Crypto.isWallive1(data) {
            plaintext = try Wallive1Crypto.decrypt(data)
        } else {
            plaintext = data
        }
        let entries = try zip.listEntries(in: plaintext)

        // 1. 定位旧壁纸目录：descriptors/<UUID>/versions/1/contents/<名>.wallpaper。
        guard let plistPath = entries.first(where: { $0.hasSuffix(".wallpaper/Wallpaper.plist") }) else {
            throw Error.missingWallpaperPlist
        }
        let parts = plistPath.split(separator: "/").map(String.init)
        guard parts.count >= 6, parts[0] == "descriptors" else {
            throw Error.missingWallpaperDirectory
        }
        let contentsPrefix = parts[0..<parts.count - 2].joined(separator: "/")  // …/contents
        let wallOld = parts[0..<parts.count - 1].joined(separator: "/")
        let wallOldName = parts[parts.count - 1]  // <num>.WWDC_2022-<res>.wallpaper

        // 编号与分辨率：7400.WWDC_2022-390w-844h@3x~iphone.wallpaper → 7400 / 390w-844h@3x~iphone。
        guard let resMatch = firstRegexMatch(#"^\d+\.WWDC_2022-(.+)\.wallpaper$"#, in: wallOldName),
              let res = substring(wallOldName, resMatch.range(at: 1)) else {
            throw Error.notATendiesPackage
        }
        let num = String(wallOldName.prefix(while: { $0.isNumber }))
        guard !num.isEmpty else { throw Error.notATendiesPackage }

        // 2. 读旧包关键文件。
        let caOld = wallOld + "/wallpaper.ca"
        guard entries.contains(caOld + "/main.caml"),
              entries.contains(caOld + "/index.xml"),
              entries.contains(caOld + "/assetManifest.caml") else {
            throw Error.notATendiesPackage
        }
        let indexXml = try zip.readEntry(caOld + "/index.xml", in: plaintext)
        let manifest = try zip.readEntry(caOld + "/assetManifest.caml", in: plaintext)
        let mainCamlData = try zip.readEntry(caOld + "/main.caml", in: plaintext)
        guard let mainCaml = String(data: mainCamlData, encoding: .utf8) else {
            throw Error.notATendiesPackage
        }
        let oldPlistData = try zip.readEntry(wallOld + "/Wallpaper.plist", in: plaintext)
        var plistFormat = PropertyListSerialization.PropertyListFormat.xml
        let oldPlist = (try? PropertyListSerialization.propertyList(from: oldPlistData, format: &plistFormat)) as? [String: Any] ?? [:]

        // 3. 切层： BACKGROUND / FLOATING / FOREGROUND。
        var slices: [(plane: String, openTag: String, inner: String)] = []
        let nsCaml = mainCaml as NSString
        for plane in ["BACKGROUND", "FLOATING", "FOREGROUND"] {
            guard let m = firstRegexMatch("<CALayer\\b[^>]*name=\"\(plane)\"[^>]*>", in: mainCaml),
                  let openTag = substring(mainCaml, m.range),
                  let closeEnd = endOfMatchingLayerClose(in: mainCaml, from: m.range.location) else {
                continue
            }
            // 匹配到的那个 </CALayer> 就是区间里最后一个，取它前面的一段当层内 XML。
            let closeRange = nsCaml.range(of: "</CALayer>", options: .backwards,
                                          range: NSRange(location: m.range.location, length: closeEnd - m.range.location))
            guard closeRange.location != NSNotFound else { continue }
            let innerStart = m.range.location + m.range.length
            let inner = nsCaml.substring(with: NSRange(location: innerStart, length: closeRange.location - innerStart))
            slices.append((plane: plane, openTag: openTag, inner: inner))
        }
        guard !slices.isEmpty else { throw Error.notATendiesPackage }

        let wallNew = num + ".Clownfish-" + res + ".wallpaper"
        func caDirName(_ plane: String) -> String {
            let cap = plane.prefix(1) + plane.dropFirst().lowercased()  // Background / Floating / Foreground
            return num + ".Clownfish_" + cap + "-" + res + ".ca"
        }

        var out: [(path: String, data: Data)] = []
        var seen = Set<String>()
        func add(_ path: String, _ data: Data) {
            guard !seen.contains(path) else { return }
            seen.insert(path)
            out.append((path: path, data: data))
        }

        // 4. 每层一个 .ca 目录。
        for slice in slices {
            let dir = contentsPrefix + "/" + wallNew + "/" + caDirName(slice.plane)
            let inner = rewriteContentsNotation(slice.inner)
            let root = replacingFirstName(in: slice.openTag, with: "_" + slice.plane)
            let main = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\n"
                + "<caml xmlns=\"http://www.apple.com/CoreAnimation/1.0\">\n"
                + "  " + root + "\n"
                + inner + "\n"
                + "  </CALayer>\n</caml>\n"
            add(dir + "/main.caml", Data(main.utf8))
            add(dir + "/index.xml", indexXml)
            add(dir + "/assetManifest.caml", manifest)
            for a in assetPaths(in: inner) {
                add(dir + "/" + a, try zip.readEntry(caOld + "/" + a, in: plaintext))
            }
        }

        // 5. 现代 Wallpaper.plist（二进制，LayeredAnimation）。
        let hasFloating = slices.contains { $0.plane == "FLOATING" }
        let hasForeground = slices.contains { $0.plane == "FOREGROUND" }
        var assetsDef: [String: Any] = [
            "type": "LayeredAnimation",
            "identifier": Int(num) ?? 0,
            "name": "Clownfish",
            "backgroundAnimationFileName": num + ".Clownfish_Background-" + res + ".ca"
        ]
        if hasFloating {
            assetsDef["floatingAnimationFileNameKey"] = num + ".Clownfish_Floating-" + res + ".ca"
        }
        if hasForeground {
            assetsDef["foregroundAnimationFileName"] = num + ".Clownfish_Foreground-" + res + ".ca"
        }
        var modernPlist: [String: Any] = [
            "appearanceAware": true,
            "assets": ["lockAndHome": ["default": assetsDef]],
            "contentVersion": 2.01,
            "family": "Clownfish",
            "identifier": Int(num) ?? 0,
            "logicalScreenClass": res,
            "name": "Clownfish",
            "version": 1
        ]
        for key in ["preferredProminentColor", "preferredTitleColor"] {
            if let v = oldPlist[key] { modernPlist[key] = v }
        }
        add(contentsPrefix + "/" + wallNew + "/Wallpaper.plist",
            try PropertyListSerialization.data(fromPropertyList: modernPlist, format: .binary, options: 0))

        // 6. contents 层 userInfo（身份对齐：三个身份位之一，装包链会再统一改号）。
        let contentsUserInfo: [String: Any] = [
            "posterEnvironmentOverrides": Data("{}".utf8),
            "wallpaperRepresentingFileName": wallNew,
            "wallpaperRepresentingIdentifier": Int(num) ?? 0
        ]
        add(contentsPrefix + "/com.apple.posterkit.provider.contents.userInfo",
            try PropertyListSerialization.data(fromPropertyList: contentsUserInfo, format: .binary, options: 0))

        // 7. 其余条目原样保留；旧壁纸目录整个不要，旧 userInfo 用上面重写的。
        for path in entries {
            if path.hasPrefix(wallOld + "/") { continue }
            if path.hasSuffix("/com.apple.posterkit.provider.contents.userInfo") { continue }
            if path.hasSuffix("/com.apple.posterkit.provider.descriptor.identifier") {
                add(path, Data(num.utf8))
                continue
            }
            add(path, try zip.readEntry(path, in: plaintext))
        }
        return try zip.rebuild(entries: out)
    }

    // MARK: - 旧格式转换的正则与 XML 小工具

    private static func firstRegexMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func substring(_ text: String, _ range: NSRange) -> String? {
        Range(range, in: text).map { String(text[$0]) }
    }

    /// 从某个 <CALayer / <CAEmitterLayer 开标签的位置起，用深度扫描找它配对的闭合标签，
    /// 返回闭合标签结束位置的下一字符索引。找不到返回 nil（自闭合 <CALayer …/> 不计层）。
    private static func endOfMatchingLayerClose(in text: String, from start: Int) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "<(/?)(CALayer|CAEmitterLayer)[\\s>/]") else {
            return nil
        }
        let ns = text as NSString
        var depth = 0
        var i = start
        while i < ns.length {
            guard let m = regex.firstMatch(in: text, range: NSRange(location: i, length: ns.length - i)) else {
                return nil
            }
            let isClose = ns.substring(with: m.range(at: 1)) == "/"
            if isClose {
                depth -= 1
                if depth == 0 { return m.range.location + m.range.length }
            } else {
                // 开标签是否自闭合：看它的「>」前一个字符是不是「/」。
                let gt = ns.range(of: ">", range: NSRange(location: m.range.location, length: ns.length - m.range.location))
                if gt.location != NSNotFound, gt.location > 0 {
                    let prev = ns.substring(with: NSRange(location: gt.location - 1, length: 1))
                    if prev != "/" { depth += 1 }
                }
            }
            i = m.range.location + m.range.length
        }
        return nil
    }

    /// 旧写法 <contents><CGImage src="assets/x.png"/></contents> →
    /// 新写法 <contents type="CGImage" src="assets/x.png"/>。
    private static func rewriteContentsNotation(_ inner: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<contents>\\s*<CGImage src=\"([^\"]+)\"/>\\s*</contents>") else { return inner }
        return regex.stringByReplacingMatches(
            in: inner, range: NSRange(inner.startIndex..., in: inner),
            withTemplate: "<contents type=\"CGImage\" src=\"$1\"/>")
    }

    private static func assetPaths(in inner: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "src=\"(assets/[^\"]+)\"") else { return [] }
        let ns = inner as NSString
        var out = Set<String>()
        for m in regex.matches(in: inner, range: NSRange(inner.startIndex..., in: inner)) {
            out.insert(ns.substring(with: m.range(at: 1)))
        }
        return out.sorted()
    }

    /// 把开标签里第一处 name="…" 改成新名字。
    private static func replacingFirstName(in openTag: String, with newName: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "name=\"[^\"]*\""),
              let m = regex.firstMatch(in: openTag, range: NSRange(openTag.startIndex..., in: openTag)) else {
            return openTag
        }
        return (openTag as NSString).replacingCharacters(in: m.range, with: "name=\"\(newName)\"")
    }

    /// 检查已解密的标准 zip 包。
    public static func inspectPlaintextZip(_ zipData: Data, zip: ZipEditing) throws -> TendiesPackageInfo {
        let entries = try zip.listEntries(in: zipData)
        guard let plistPath = entries.first(where: { $0.hasSuffix(".wallpaper/Wallpaper.plist") }) else {
            throw Error.missingWallpaperPlist
        }
        // 路径形如 descriptors/<UUID>/versions/1/contents/<名>.wallpaper/Wallpaper.plist
        let parts = plistPath.split(separator: "/")
        guard parts.count >= 6, parts[0] == "descriptors" else {
            throw Error.missingWallpaperDirectory
        }
        let uuid = String(parts[1])
        let wallpaperDir = parts[3..<parts.count - 1].joined(separator: "/")
        let prefix = "descriptors/\(uuid)/versions/1/contents/\(wallpaperDir)/"

        // 读 Wallpaper.plist，取三层文件名（键在 assets.lockAndHome.default 下）。
        let plistData = try zip.readEntry(plistPath, in: zipData)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: &format)
        var backgroundFile: String?
        var floatingFile: String?
        var foregroundFile: String?
        if let root = plist as? [String: Any],
           let assets = root["assets"] as? [String: Any],
           let lockAndHome = assets["lockAndHome"] as? [String: Any],
           let def = lockAndHome["default"] as? [String: Any] {
            backgroundFile = def["backgroundAnimationFileName"] as? String
            floatingFile = def["floatingAnimationFileNameKey"] as? String
            foregroundFile = def["foregroundAnimationFileName"] as? String
        }
        _ = prefix // 保留目录前缀供调用方拼条目路径。

        let hasRenderingConfiguration = entries.contains {
            $0.hasSuffix("com.apple.posterkit.provider.instance.renderingConfiguration.plist")
        }
        let floatingHasClownfishPrefix = (floatingFile ?? "").hasPrefix("Clownfish_")

        return TendiesPackageInfo(
            descriptorUUID: uuid,
            wallpaperDirectory: wallpaperDir,
            backgroundFile: backgroundFile,
            floatingFile: floatingFile,
            foregroundFile: foregroundFile,
            hasRenderingConfiguration: hasRenderingConfiguration,
            floatingHasClownfishPrefix: floatingHasClownfishPrefix
        )
    }
}
