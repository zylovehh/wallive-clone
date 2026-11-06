import CryptoKit
import Foundation

// 一份备份 3.3 文件记录的字节。
//
// 这是 GoldenNugget 旧 `Backup.swift` 里唯一活下来的部分：那文件的其余
// 类型（`BackupFile` / `ConcreteFile` / `SymbolicLink` / `Directory` /
// `Backup` / `MobileBackupDatabase` / `MBDBRecord`）在别处零引用，
// 只是为一条已经不走的稀疏还原路线留在工程里。
//
// 留下的是注入真正需要的：写进 Files 行的 NSKeyedArchiver `MBFile`
// blob，外加还原守护进程要求写在应用容器文件上的数据保护扩展属性。

/// 合成记录的权限位。
///
/// 对照同一台 iPad 已知完好的备份（`MobileSync/Backup/00008130-001431082E40001C`）
/// 里 4000 多个 `AppDomain-*` 文件行实测：文件行 Mode 是 `0o100644` 的
/// 占 3283 行（`0o100700` 574 行、`0o100600` 6 行、`0o100640` 4 行），
/// 目录行一律 `0o40755`。设备没自己写过的行，错了没法靠重传修，
//  所以直接抄最常见的那一档。
let MODE_FILE_DEFAULT: UInt16 = 0o644
let MODE_DIR_DEFAULT: UInt16 = 0o755

/// 设备给每种行写的数据保护级别。
///
/// 同一份实测：3283/4000 个文件行是级别 3，133 行是级别 4——**没有一行是 0**，
/// 而每个目录行都是 0。以前两边都给 0，是错的。
let PROTECTION_CLASS_FILE: Int = 3
let PROTECTION_CLASS_DIR: Int = 0

/// 设备给**系统容器**文件行写的级别——4。`AppDomain-*` 行里它是少数，
//  但 `injectSystemPlist` 要递的那类文件，设备自己就是这么写的。
///
/// 取样自设备自己给那个文件写的行
/// （`…/Manifest.db`，fileID `0affc9c4722175be11a30bb60e96880ffedf29d5` =
/// `SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles/…/`
/// `SharedDeviceConfiguration.plist`）——应用容器默认的级别 3 也是同一份
/// 实测来的，两者是同一组数里的两档，不是"3 或 4 都行"。
let PROTECTION_CLASS_SYSTEM_FILE: Int = 4

/// 设备从 Files 行的 `file` blob 里解出来的 `MBFile` 对象结构。
///
/// `@objc` 的名字是起作用的：`NSKeyedArchiver` 会把类名写进归档，
//  设备那边的解析器就是按 `MBFile` 这个字面名字找的。
///
/// 键的集合是抄设备自己写的，不是凭印象：同一份 4000 个 `AppDomain-*`
/// 文件行里，`InodeNumber` 4000/4000 行都有，`Digest` 0/4000 行有
/// （`ExtendedAttributes` 不对称是正常的——1808/4000 行带）。
/// 以前正好反过来：写了一个 iOS 27 行里没有的 SHA1 `Digest`，
//  却漏了 `InodeNumber`。
@objc(MBFile) private class MBFileArchiver: NSObject, NSCoding {
    var relativePath: String = ""

    /// **必须是 `Int`，绝不能是 `UInt32`，这点不是讲究写法。**
    ///
    /// `NSCoder` 没有 `encode(_:forKey:)` 的 `UInt32` 重载，所以一个 `UInt32`
    /// 会悄悄走 `Any?` 那个重载：数字被装箱，归档器把它存成 `$objects`
    /// 里的一条，键上挂的是**引用**而不是内联整数。设备上所有读整数的路
    /// 子碰到引用都会失败——对照真的 `NSKeyedUnarchiver` 实测过（2026-09-21）：
    ///
    ///     -[NSKeyedUnarchiver decodeInt64ForKey:]: value for key (Mode) is not
    ///     an integer number        // decodeInteger / decodeInt32 / decodeInt64
    ///                              // 全都会抛，只有 decodeObject 能活
    ///
    /// 而设备自己写的 blob 里每个标量都是内联的（34918 行里 `Mode` 写成
    /// 引用的有 **0 行**）。一行读不出 `Mode` 就没有文件类型，设备就回：
    /// `MBErrorDomain/205 — "Invalid file type: 00"`——`00` 是
    /// `(mode & S_IFMT) >> 12` 在 mode 被读成 0 时的 `%02x`。
    ///
    /// 只比键的集合抓不到这个毛病（`mbFileBlobKeys` 和设备对得一模一样）。
    /// 是**编码**出了问题，所以 `mbFileBlobShape` 才要报形状。
    var mode: Int = 0

    var size: Int = 0
    var userID: Int = 501
    var groupID: Int = 501
    var protectionClass: Int = 0
    var birth: Int = 0
    var lastModified: Int = 0
    var lastStatusChange: Int = 0
    var flags: Int = 0
    var inodeNumber: Int = 0
    /// 载荷的 SHA-1——只在设备会盖章的那类行上有。
    ///
    /// 有还是没有，按 domain 分得一清二楚，绝对值（110 个带文件行的
    /// domain，没有一个混着来——`scripts/blob-shape-check.swift` 第 4 节
    /// 就是复查的这个）：
    ///
    ///   * **带**（11 个 domain）：`HomeDomain`、`SystemPreferencesDomain`、
    ///     `ManagedPreferencesDomain`、`DatabaseDomain`、`RootDomain`、
    ///     `MobileDeviceDomain`、`WirelessDomain`、`NetworkDomain`、
    ///     `KeychainDomain`、`ProtectedDomain`、`InstallDomain`
    ///     （每个 domain 自己的数也很稳：HomeDomain 708/708、
    ///     SystemPreferencesDomain 9/9、ManagedPreferencesDomain 4/4、
    ///     DatabaseDomain 3/3）；
    ///   * **从不带**（99 个 domain）：整个 `AppDomain*` 家族
    ///     （`AppDomain-`、`AppDomainGroup-`、`AppDomainPlugin-`）、
    ///     `SysSharedContainerDomain-*`、`SysContainerDomain-*`、`CameraRollDomain`
    ///     （`AppDomain-*` 0/2760，`SysSharedContainerDomain-*` 0/10）。
    ///
    /// 目录行（那批 domain 里 0/4387 行）和符号链接行不管在哪个 domain
    /// 都不带；带的地方，它的值就是 `sha1(载荷)` 一个字节不差
    /// （`HomeDomain`、`SystemPreferencesDomain`、`ManagedPreferencesDomain`、
    /// `DatabaseDomain` 各抽一行验过）。
    ///
    /// 这是只做 AppDomain 的注入器唯一能白省的字段：`AppDomain-*` 恰好是
    /// 不带的那一类。往一个带摘要的 domain 里写行却漏了它，就是和设备
    /// 对不上号的偏差，而走应用容器那条路永远发现不了；设备回的会是
    /// `MBErrorDomain/205 — "Manifest references files not in backup"`。
    /// 哪个 domain 带、哪个不带，看 `BackupRowProfile.carriesDigest`。
    var digest: Data?
    var extendedAttributes: Data?

    override init() { super.init() }

    required init?(coder: NSCoder) { super.init() }

    func encode(with coder: NSCoder) {
        coder.encode(birth, forKey: "Birth")
        coder.encode(lastModified, forKey: "LastModified")
        coder.encode(lastStatusChange, forKey: "LastStatusChange")
        coder.encode(flags, forKey: "Flags")
        coder.encode(groupID, forKey: "GroupID")
        coder.encode(userID, forKey: "UserID")
        coder.encode(mode, forKey: "Mode")
        coder.encode(protectionClass, forKey: "ProtectionClass")
        coder.encode(size, forKey: "Size")
        coder.encode(relativePath, forKey: "RelativePath")
        // 无条件写，目录也算：设备从不省略它。
        coder.encode(inodeNumber, forKey: "InodeNumber")
        // `Data`，所以和 `RelativePath` 一样是真实对象，即引用而不是内联。
        // 设备自己也是这么写的。
        if let digest { coder.encode(digest, forKey: "Digest") }
        if let ea = extendedAttributes { coder.encode(ea, forKey: "ExtendedAttributes") }
    }
}

/// 给一行清单造归档好的 `MBFile` blob。
///
/// `mode` 是 `Int`，因为归档里的字段必须是内联整数——见
/// `MBFileArchiver.mode`。调用方拼成 `Int(MODE_FILE_DEFAULT) | Int(S_IFREG)`。
///
/// `timestamp` 给三个时间字段都用同一个值。设备从不给任何一个写 0
/// （`Birth` 0/34918，`LastModified` 0/34918，`LastStatusChange` 0/34918，
/// 最早 1321453406），所以我们也不写 0。
///
/// `digest` 只在设备会盖章的那类行上给——见 `MBFileArchiver.digest`
/// 的实测分布。往一个带摘要的 domain 里写行，调用方必须传
/// `payloadDigest(contents)`。
func buildMBFileBlob(relativePath: String, mode: Int, size: Int,
                     userID: Int = 501, groupID: Int = 501, protectionClass: Int = 0,
                     inodeNumber: Int = 0,
                     timestamp: Int = Int(Date().timeIntervalSince1970),
                     digest: Data? = nil,
                     extendedAttributes: Data? = nil) -> Data {
    let obj = MBFileArchiver()
    obj.relativePath = relativePath
    obj.mode = mode
    obj.size = size
    obj.userID = userID
    obj.groupID = groupID
    obj.protectionClass = protectionClass
    obj.birth = timestamp
    obj.lastModified = timestamp
    obj.lastStatusChange = timestamp
    obj.inodeNumber = inodeNumber
    obj.digest = digest
    obj.extendedAttributes = extendedAttributes
    NSKeyedArchiver.setClassName("MBFile", for: MBFileArchiver.self)
    // 这里敢 force-try：类名上一行已经注册过，而且对象图就是一个扁平对象，
    // 没有嵌套容器，归档不可能失败。
    return try! NSKeyedArchiver.archivedData(withRootObject: obj, requiringSecureCoding: false)
}

/// 一个文件行要声明的 `Digest`：载荷字节的 SHA-1。
///
/// 定义放在这里、挨着它要进的 blob，因为它是同一份约定的一部分：
/// 设备每行带 `Digest` 的地方，它的值都精确等于 `sha1(<载荷>)`
/// （在参考备份的 `HomeDomain` / `SystemPreferencesDomain` /
/// `ManagedPreferencesDomain` / `DatabaseDomain` 行上验过）。
/// GoldenNugget 写的一样（`_build_mbfile_blob` / `_patch_donor_blob`
/// 里的 `hashlib.sha1(contents).digest()`），所以这是参考实现的行为，
/// 不是我们的推测。
func payloadDigest(_ contents: Data) -> Data {
    Data(Insecure.SHA1.hash(data: contents))
}

/// `com.apple.dataprotection.policy.exception-applied-by` 属性。
///
/// 值是"谁给了这个例外"，设备自己的应用容器行写的是
/// `com.apple.containermanagerd_system`——同属 `AppDomain-*` 的行抽了 3 行，
/// 3 行都是它。以前写的是 `com.apple.springboard`，抽样的行里没有一行
/// 是这个；调用方的注释说那是"让 SpringBoard 写进容器"，但设备自己的
/// 记录不同意，记录才是约定。
///
/// `publisher` 是参数，因为设备不是所有地方都用同一个值：同一份备份里，
/// 一个 `ManagedPreferencesDomain` 行写的是 `com.apple.BackupAgent2`，
/// 一个 HomeDomain 的 `.GlobalPreferences.plist` 写的是
/// `com.apple.cfprefsd`。默认值是应用容器那个值，所以原来每个调用处
/// 拿到的字节不变。
func buildDataprotectionExtendedAttributes(
    publisher: String = "com.apple.containermanagerd_system"
) -> Data {
    let ea: [String: Any] = [
        "com.apple.dataprotection.policy.exception-applied-by":
            Data(publisher.utf8)
    ]
    return (try? PropertyListSerialization.data(fromPropertyList: ea, format: .binary, options: 0)) ?? Data()
}

/// 一个归档好的 `file` blob 实际带哪些 `MBFile` 键（已排序）。
///
/// 存在是因为设备有一次拒绝还原，报的是
/// `MBErrorDomain/205 — "Invalid file type: 00"`（2026-09-20），当时 471 个
/// 载荷只拉了 7 个就停了；`205` 是一类错，不是原因，描述是唯一的区分点。
/// "file type" 指向的就是设备从 Files 行的 `file` blob 里解出来的元数据，
/// 所以要比的就是键的集合——我们的和设备自己写的比；设备没动过的行
/// 都还带着它自己写的 blob，正好当参照。
///
/// `NSKeyedArchiver` 把编码对象的属性当作非 `$` 键放在 `$objects` 里，
//  所以把每个条目里的键都收集起来，就是键的集合。
func mbFileBlobKeys(_ data: Data) -> String {
    guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = obj as? [String: Any] else {
        return "<not a plist>"
    }
    guard let objects = dict["$objects"] as? [Any] else {
        return dict.keys.sorted().joined(separator: ",")
    }
    var keys: Set<String> = []
    for entry in objects {
        guard let entry = entry as? [String: Any] else { continue }
        for key in entry.keys where !key.hasPrefix("$") { keys.insert(key) }
    }
    return keys.sorted().joined(separator: ",")
}

/// 归档 blob 里的 `MBFile` 对象字典，即装着这行元数据的那个条目
/// （不是 `$null`、字符串、类字典……）。
///
/// 用扫描找，不走 `$top` → `root`：根索引是个 `CFKeyedArchiverUID`，
//  `PropertyListSerialization` 给回来的是个没有公开读取方法的私有类型。
private func mbFileBlobObject(_ data: Data) -> [String: Any]? {
    guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = obj as? [String: Any],
          let objects = dict["$objects"] as? [Any] else {
        return nil
    }
    for entry in objects {
        guard let entry = entry as? [String: Any],
              entry["Birth"] != nil || entry["Mode"] != nil else { continue }
        return entry
    }
    return nil
}

/// 设备能从 blob 里读到的 `Mode`，读不到时是 nil。
///
/// nil 就是坏的形状：`NSCoder` 写内联数字时是内联数字写进去的，但凡
/// 它得装箱的东西都是以 `$objects` 引用的形式写——设备用
/// `decodeInteger` 那家人读引用时会抛 "value for key (Mode) is not an
/// integer number"。一个还原代理读不出行的类型，就会回
/// `MBErrorDomain/205 — "Invalid file type: 00"`。
func mbFileBlobMode(_ data: Data) -> Int? {
    (mbFileBlobObject(data)?["Mode"] as? NSNumber)?.intValue
}

/// 一行 blob 声称的 `InodeNumber`，没有时是 nil。
///
/// 需要它是因为还原代理按 inode 去重：GoldenNugget 的注入器读出清单里
/// 最大的 inode 再往上数——"代理按 inode 去重，共用供体 inode 的克隆
/// 会被按供体的内容还原"（`src/restore/inject.py:254-266`）。这个字段
/// 在 blob 里，不在列里，所以要算最大值只能把每个 blob 解出来读。
func mbFileBlobInode(_ data: Data) -> Int? {
    (mbFileBlobObject(data)?["InodeNumber"] as? NSNumber)?.intValue
}

/// 一个 blob 的值是**怎么编码的**，而不只是有哪些键。
///
/// `mbFileBlobKeys` 只比键的集合，单靠它不够——坏掉的 `Mode` 就是这么
/// 逃过一整轮诊断的：键和设备对得一模一样，值却是对象引用而不是数字，
/// 设备上每次读整数都抛（2026-09-21），还原回的是
/// `MBErrorDomain/205 — "Invalid file type: 00"`。
///
/// 所以这里报两件能区分好坏 blob 的事：读到的 `Mode`（引用时是
/// `UNREADABLE`），以及哪些键是引用。`RelativePath` / `ExtendedAttributes` /
/// `Digest` 本来就是引用——它们是真实对象；一个**标量**字段出现
/// 在这个表里，就是 bug。
func mbFileBlobShape(_ data: Data) -> String {
    guard let entry = mbFileBlobObject(data) else { return "<no object dict>" }
    var references: [String] = []
    for key in entry.keys.sorted() where !key.hasPrefix("$") {
        if entry[key] is NSNumber { continue }
        references.append(key)
    }
    let mode = (entry["Mode"] as? NSNumber)?.intValue
    return "mode=\(mode.map(String.init) ?? "UNREADABLE") "
        + "reference-valued keys=[\(references.joined(separator: ","))]"
}

/// 同路径替换，照桌面版 inject.py 的供体 blob 策略。
/// 保留原来的 inode、mode、属主、保护级别和扩展属性；只有和内容有关的
/// 大小和摘要会变；keyed-archive 的 UID 原样带过去。
func patchMBFileContents(_ donor: Data, contents: Data) throws -> Data {
    guard var plist = try PropertyListSerialization.propertyList(from: donor, format: nil) as? [String: Any],
          var objects = plist["$objects"] as? [Any], objects.count > 1,
          var root = objects[1] as? [String: Any], root["Size"] != nil else {
        throw BackupError("设备原有文件的元数据读不出来，还原已停——要替换的文件没有可用的原始记录。")
    }
    root["Size"] = contents.count
    if let digest = root["Digest"] {
        // 原生的 UID 对 Swift 是不透明的；它的整数能从反射里看到。
        let value = Mirror(reflecting: digest).children.first(where: { $0.label == "value" })?.value
        let index = (value as? NSNumber)?.intValue ?? (value as? UInt32).map(Int.init) ?? (value as? Int)
        guard let index, objects.indices.contains(index), objects[index] is Data else {
            throw BackupError("设备原有文件的摘要元数据读不出来，还原已停。")
        }
        objects[index] = payloadDigest(contents)
    }
    objects[1] = root
    plist["$objects"] = objects
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
}
