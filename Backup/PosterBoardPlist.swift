import Foundation

/// 描述符里 plist 的改写小工具。照 GoldenNugget 手机版
/// `Nugget/Core/PosterBoard.swift` 里的 `PosterBoardPlist` 原样搬，
/// 只把 `GoldenNuggetError` 换成 `BackupError`。
///
/// 用在备份路的编包 walk 里：新 UUID 发下来后，描述符里那几个
/// identifier 字段要跟着改，否则提供方认不出自己的壁纸。
enum PosterBoardPlist {
    static func load(contentsOf url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let plist = object as? [String: Any] else {
            throw BackupError("\(url.lastPathComponent) 是个 plist，但不是字典。")
        }
        return plist
    }

    /// `set_plist_value`：读出来、改一个键、再写回去。
    ///
    /// 写 XML，因为 Python 的 `plistlib.dumps` 默认就是 XML。
    /// **一个不同点**：Python 写的时候会排键，`PropertyListSerialization`
    /// 按字典顺序写。plist 字典读出来是无序的，设备比的是值不是字节——
    /// 清单里的 `Digest` 是注入器自己对这些字节算的，所以下游不受影响。
    static func set(contentsOf url: URL,
                    key: String,
                    value: Any,
                    recursive: Bool) throws -> Data {
        var plist = try load(contentsOf: url)
        if recursive {
            plist = recursiveSet(plist, key: key, value: value)
        } else {
            plist[key] = value
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// `plist_handler.recursive_set`：键在哪出现就改哪，一路钻进
    /// 每个子字典。
    static func recursiveSet(_ plist: [String: Any], key: String, value: Any) -> [String: Any] {
        var result = plist
        for (existingKey, existingValue) in plist {
            if existingKey == key {
                result[existingKey] = value
            } else if let nested = existingValue as? [String: Any] {
                result[existingKey] = recursiveSet(nested, key: key, value: value)
            }
        }
        return result
    }

    /// `update_for_family`：把一张系统壁纸按 Marble（Configs）模型对齐——
    /// family 和 name 强制改成 Lavender，嵌套的
    /// `assets.lockAndHome.default.identifier` 跟着顶层的 identifier 一起改，
    /// 提供方才能按那个 id 找到 `.ca` 动画文件。
    ///
    /// 系统壁纸（iOS 17 时代）自带 family/name 和一个单独的描述符 identifier，
    /// 商店改成数据库驱动的 configs 后就对不上了，所以每个 identifier 字段
    /// 都要重写。
    static func alignedForFamily(_ data: Data) throws -> Data {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard var plist = object as? [String: Any] else {
            throw BackupError("Wallpaper.plist 不是字典。")
        }
        let newIdentifier = plist["identifier"]
        if let assets = plist["assets"] as? [String: Any],
           let lockAndHome = assets["lockAndHome"] as? [String: Any],
           var fallback = lockAndHome["default"] as? [String: Any] {
            fallback["name"] = "Lavender"
            if let newIdentifier { fallback["identifier"] = newIdentifier }
            var updatedLockAndHome = lockAndHome
            updatedLockAndHome["default"] = fallback
            var updatedAssets = assets
            updatedAssets["lockAndHome"] = updatedLockAndHome
            plist["assets"] = updatedAssets
        }
        plist["family"] = "Marble"
        plist["name"] = "Lavender"
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
