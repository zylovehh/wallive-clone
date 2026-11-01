# wallive-clone（无广告复刻版 · 干净重写）

目标：复刻交互壁纸 App 的核心功能（包导入、深景包制作、安装），
**不含任何广告 SDK、不含会员/解锁逻辑**。用户原话：“广告不用往里加”——
复刻版从第一行代码起就不接广告，不是把原版的广告剥掉。

> 边界：本目录是干净重写的新代码，不修改、不补丁原版二进制，
> 不绕过原版的广告验证/解锁。原版 App（1.1.3/290，com.mutually.wallpaper）
> 是第三方应用；本复刻只复现其公开可观测的功能与包格式。

## 架构（原版 App 的实测结构）

```
┌──────────────┐   目录浏览      ┌─────────────────────┐
│  目录 / 导入  │ ──────────────▶ │ walllive.18ir.cn    │
│  安装 / 设置  │  get_wallpaper  │   /api/*.php        │
└──────┬───────┘  .tendies导入   └─────────────────────┘
       │ UTI com.mutually.wallpaper.tendies
       ▼
┌──────────────────┐   inspectArchive    ┌──────────────────┐
│ TendiesPackage   │ ──────────────────▶ │ 描述符校验        │
│ Store / Installer│   WALLIVE1 解密     │ Background/Floating│
└──────┬───────────┘   (HKDF+AES-GCM)    │ /Foreground .ca  │
       │ 安装事务 (AirliftPosterBoard)    └──────────────────┘
       ▼
┌──────────────────┐   回环 VPN + 自配对  ┌──────────────────┐
│ 特权写盘（缺口）  │ ──────────────────▶ │ PosterBoard 描述符│
│ PrivilegedTransport│  lockdownd :62078 │ + 安装记录        │
└──────────────────┘   AFC 文件操作      └──────────────────┘
```

### UI 流程（从视图/控制器符号 + 实测行为整理）
- **目录浏览**：TendiesWallpapersView / TendiesPackagesView，拉取服务器目录
  （get_wallpaper.php，约 494 条，video/image 两类），点条目下载。
- **包导入**：TendiesDocumentPicker，注册打开 .tendies/.wallive
  （UTI com.mutually.wallpaper.tendies，PosterBoard Wallpaper Package）。
- **安装**：TendiesInstallCoordinator（下载、安装意图、清除已记录壁纸）
  → AirliftPosterBoard.InstallTransaction / InstallJob / InstallReceipts
  → 写描述符 + 登记安装记录。
- **设置**：配对（PairingController / PairingSocket / PairingFile，
  即“重新配对这台 iPhone”，配对就绪记 aircard_pairing.plist）、
  VPN（回环 VPN 连接确认）、教程视频（WallpaperApplyTutorial.mp4）。
- **会员/广告**：原版有穿山甲（CSJ/BUAdSDK）+ GroMore  mediation
  + 会员订单接口；复刻版一律不接（见“明确不做的事”）。

### 服务器接口（已确认存在）
- `https://walllive.18ir.cn/api/get_wallpaper.php`：目录（分页）。
- `https://walllive.18ir.cn/api/ios_download_file.php`：文件下载（参数未确认）。
- `https://walllive.18ir.cn/api/get_startup_notice.php`、`get_tutorials.php`、
  `ios_app_status.php`、`ios_time.php`、`ios_diagnostic_report.php`：
  公告、教程、状态、时间、诊断上报（复刻核心功能不需要）。
- `https://walllive.18ir.cn/api/ios_member_*.php`、
  `https://walllive.18ir.cn/api/csj_rectification_*.php`：
  会员订单、穿山甲广告矫正——复刻版不接。
- `https://walllive.18ir.cn/system-vpn-test-20260927/api.php/v1/enroll`：
  VPN 注册相关（原版流程用；复刻版 VPN 配置走用户手动安装描述文件）。

### 沙盒外写盘是怎么回事（功能层面）
原版没有“写 PosterBoard”的 entitlement（实测 embedded.mobileprovision
的 entitlements：无 VPN API、无 application-groups、无 springboard 相关，
只有推送、关联域名、钥匙串组）。它走的是 AirCard 模式：
1. 用户手动安装并连接回环 VPN（LocalDevVPN，设备 IP 10.7.0.1），
   使本机 lockdownd（端口 62078）可达；
2. App 解析 Lockdown 配对记录（peer_public_key / peer_identifier），
   以“远端配对主机”身份连 lockdownd（RPPairing，Bonjour 服务
   `_aircardprobe._tcp`、`_remotepairing-pairable-host._tcp`）；
3. 经 lockdownd 远端服务通道调用 AFC 文件操作
   （MakeDir / WriteFile / RenamePath 等）与安装代理服务，
   把描述符写进 PosterBoard 目录并登记安装记录。
这不是靠某个 entitlement 直接写盘，而是一整套配对 + 远端服务协议。
本复刻不实现这段通道（见“缺口”），也不从原版二进制里抠 exploit。

## 本目录的组件（已写出）

| 文件 | 作用 | 状态 |
|---|---|---|
| `Wallive1Crypto.swift` | WALLIVE1 v1 加解密（HKDF-SHA256 + AES-GCM，CryptoKit） | 已实现（与 wallive1.py 验证一致） |
| `TendiesPackage.swift` | 包检查：WALLIVE1/标准 zip 识别、描述符结构校验 | 已实现（zip 层走 ZipEditing 协议，需接 ZIPFoundation 等库） |
| `DepthPackageBuilder.swift` | 深景包制作：加渲染配置 + Clownfish_ 前缀（装机验证过的配方，无加密也可出深景） | 已实现 |
| `DescriptorInstaller.swift` | 安装逻辑：本地暂存 + 校验 + 目标路径 + 记录占位；特权写盘走 PrivilegedTransport 协议 | 本地部分已实现（未改动，直接接新通道） |
| `PairingRecord.swift` | 配对记录运行时加载（字段与长度校验，不内嵌、不打印密钥） | 已实现（代码层面；加载路径待真机验证） |
| `RemoteLockdown.swift` | TCP 通道 + 配对握手 + lockdownd 会话（StartSession/StartService）+ 加密会话通道 | 已实现（代码层面；握手线格式待真机确认） |
| `AFCClient.swift` | AFC 包编解码 + 文件操作（MakeDir/写/改名/删/读目录/查信息） | 已实现（包逻辑已校验；线协议待真机确认） |
| `PrivilegedLockdownTransport.swift` | PrivilegedTransport 的具体实现 + 工厂（运行时加载配对记录） | 已实现（代码层面；待真机验证） |
| `InstallFlow.swift` | 端到端入口：inspect → stage → 建通道 → install → 返回 UUID | 已实现（代码层面走通） |
| `App/`（8 个 SwiftUI 文件） | App 壳：入口、共享状态、ZIPFoundation 适配、文件选择器、导入/安装/深景/状态四页 | 已写出（未编译，见下） |
| `WalliveClone.xcodeproj/` | Xcode 工程 + 共享 scheme（iOS 17+，SPM 接 ZIPFoundation） | 已写出（未编译） |
| `.github/workflows/build-unsigned-ipa.yml` | macOS runner 编译未签名 IPA 的工作流（仓库根推送后自动跑） | 已写出（未跑过） |
| `Info.plist` | 手写清单：UTI com.mutually.wallpaper.tendies（.tendies/.wallive）、文档类型、方向 | 已写出 |

## 全屏修复（2026-11-01，用户实测）
- 现象：16 Pro Max（1320×2868）上界面在 2336 像素处断掉，下面留 531 像素黑，页签悬在半空。
- 根因：`Info.plist` 里没有任何启动屏声明，iOS 把 App 当成老尺寸 App 做兼容显示，只给 16:9 左右的窗口高度。
- 修复：`Info.plist` 加空 `UILaunchScreen`（声明支持全屏尺寸，不用另做启动图），入口 `TabView` 加满宽满高约束。工程是 `GENERATE_INFOPLIST_FILE=NO`，手写清单会原样进包，不会被 Xcode 覆盖。
- 注意：本机是 Linux、无 Xcode，改完源码仍需走 macOS runner 重新编包、用户自己签名后装机验证，改源码本身不等于新包已出。

## 缺口：复刻版到底缺什么（明说）

1. **特权写盘通道（代码层面已补上，待真机验证）**：配对协议客户端、
   lockdownd 远端服务客户端、AFC 包协议、安装记录格式均已写出
   （见上表新文件与 CLONE-NOTES.md 第 11 节），包编解码与路径映射
   已用合成数据校验通过。但线协议细节（握手拼写、帧格式、操作码
   数字、服务名变体、路径根、系统记录格式）必须在真机上对照确认，
   否则不能保证真机装得上。没有真机验证前，复刻版仍不能说
   “能在真机上把壁纸装进锁屏”。
2. **配对信任如何建立**：配对记录来源已有用户提供的文件；
   但自配对是否需要用户在手机上点信任、App 内加载路径，
   仍需真机验证（见 CLONE-NOTES.md 第 11 节清单第 3 条）。
3. **安装记录格式**：ManagedPosterBoardRemoteInstallRecords /
   PackageInstallRecords 的具体格式未从静态分析中确认。
4. **App 壳已搭好、Swift 代码未编译**：本机是 Linux、无 Xcode；
   工程、界面、工作流均已写出并做了结构校验（见“App 壳”一节），
   但真正的 Xcode 编译必须上 GitHub macOS runner，尚未跑过。
   编译若报错，修的范围应是工程/壳层，不动发动机文件。

## App 壳（SwiftUI，已搭好，未编译）

壳在 `App/`（8 个文件，514 行），发动机文件一律原地引用、不复制：

| 页签 | 作用 | 接的发动机 |
|---|---|---|
| 导入 | 系统文件选择器接 .tendies/.wallive（UTI 已注册），检查后显示三层与深景标记 | TendiesPackage |
| 安装 | 当前包 + 配对记录 → 特权通道写盘登记，显示进度与结果 | InstallFlow |
| 深景 | 给标准包加渲染配置开关 + Clownfish 前缀，可分享、可设为当前包再安装 | DepthPackageBuilder |
| 状态 | 回环 VPN 通不通（TCP 连 10.7.0.1:62078，3 秒超时）、配对记录有没有、装过哪些 | PairingRecord（只显示字段长度） |

- **配对记录**：用户在“状态”页导入 .plist 文件，App 拷进自己沙盒
  Documents（wallive-pairing.plist），运行时加载；代码与工程里
  不含任何密钥材料，也不捆绑任何配对文件。文件共享（File Sharing）
  故意没开，避免配对文件经 Finder 外泄。
- **zip 层**：`App/ZipFoundationAdapter.swift`，SPM 接 ZIPFoundation
  0.9+（读用内存 Archive + consumer 抽取；写用临时目录 + STORE），
  拒绝包外路径（防 Zip Slip）。
- **包名**：工程里是占位 `com.example.walliveclone`，签名时用户自己定。
  注意：若用户用固定 App ID wb.uniusc8301.tool7 的证书签，会与
  TendiesEditor 撞包名、装一个盖掉另一个。
- **签名**：工程与工作流一律不签名（CODE_SIGNING_ALLOWED=NO），
  只出未签名 IPA，用户自己签名安装（用户 2026-11-01 定）。
- **编译**：把本目录内容作为仓库根推送到 GitHub，
  `.github/workflows/build-unsigned-ipa.yml` 在 macOS runner 上
  跑 `xcodebuild archive`（未签名）→ 打包 IPA → 上传产物
  WalliveClone-unsigned-ipa。runner 上若报 SPM 拉取失败，
  先查网络/ZIPFoundation 版本，再动工程。
- **结构校验（本机已做，Linux 无 Xcode）**：Info.plist 合法、UTI 与
  文档类型齐全；工作流 YAML 合法且无签名步骤；工程文件引用与磁盘
  文件一一对应、全部 19 个 Swift 源文件都在 Sources 编译相；
  scheme 的目标 ID 与工程一致；壳引用的发动机类型与接口均存在；
  新文件无配对文件引用、无广告 SDK 字样、无 64 位十六进制串、
  无捆绑配对文件；发动机文件未被改动。

## 明确不做的事
- 不修改、不补丁原版二进制；不剥离、不绕过原版的广告验证/解锁。
- 不接任何广告 SDK（无穿山甲 CSJ/BUAdSDK、无 GroMore、无腾讯广告配置）。
- 不接会员/订单/诊断上报接口。
- 不开发新的沙盒逃逸 exploit；不从原版二进制提取 exploit 代码。
- 不复制原版的任何账号、密钥、证书（VPNDownloadAccount.json 的
  账号口令只确认了字段名，未抄录、未使用）。

## 许可说明（原版包内自带的许可文本）
- AirCard-iOS：MIT（Copyright 2026 Johnny Franks）——配对/AFC 模式的
  参考实现来源；复刻如参考其思路，需保留 MIT 声明。
- Tendies（3105）：GPL-3.0——原版 Tendies 相关代码的许可；复刻如
  直接复用其代码，需遵守 GPL；本目录为干净重写，不直接抄录。
- LocalDevVPN（StosVPN，SideStore Team）：宽松许可文本随包附带。
- 本目录新代码的许可由使用者定；建议与上述参考来源保持一致声明。

## 构建要求（复刻版完整构建时）
- Xcode，iOS 17+（原版 MinimumOS 17.0），Swift + CryptoKit。
- 侧载签名：与原版相同的企业/开发者描述文件方式；
  不需要特殊 entitlement 即可构建非特权部分。
- zip 库：已接 ZIPFoundation（SPM，见工程；`App/ZipFoundationAdapter.swift` 实现 ZipEditing 协议）。
- 真机安装能力取决于特权通道（见缺口），不在第一阶段范围。
