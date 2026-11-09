# WorseQuery（沙箱逃逸直写，27.2 新路子）

本目录引入了 [forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)
的核心实现（GPL-3.0，Copyright (C) 2026 Taj C / forcequit）：

- `worse_query.h` / `worse_query.m`：上游原样拷贝，未改动。
- `WorseQueryShim.m`：本项目新增的纯 C 包装（const char* 进出）。
- `WorseQueryEscape.swift`：本项目新增的 Swift 封装（错误映射、句柄管理、
  直写辅助）。

## 原理

通过 containermanagerd 的 class 7 查询（App Group 容器）+ 容器内
`Library/Caches` 符号链接，拿到目标路径的沙箱扩展。句柄 > 0 期间，进程
可以用普通 FileManager 直接读写目标路径。上游 README 自述覆盖
iOS 26.0–26.7.2 / 27.2。

本项目在 27.2 备份还原链路（`App/RestoreTest.swift`）里这样用：

1. 拿表完成后对 PosterBoard 容器吃一次沙箱扩展；
2. 成了：写文件、写回表走本地直写（失败自动回落 AirTraffic / FFI 原通道）；
3. 没成：整个流程照走原通道，行为与引入前完全一致。

App Group 用 `group.com.tgqq.1767742703`（entitlements 里已声明；这是
Vellum 在同一台 27.2 手机上实测容器存在的组，旧组 group.com.usc.1787713824
拿不到容器）。

## 免组兜底路（2026-11-10 新增，本项目扩展）

当 `containerURLForSecurityApplicationGroupIdentifier:` 拿不到组容器时，
`worse_query_escape2` 不再直接报 -1，而是按"免符号链接"的方式逐组试探：

- class 2 / class 7：仍查自己的组标识，part_domain 用 8 级 `../` 穿透到目标；
- class 13：查系统组 `systemgroup.com.apple.mobilegestaltcache` /
  `group.com.apple.PosterBoard`，7 级 `../` 穿透。

常量（class、part、flags 0x8000000000 / 0x800000000、穿透层数）核对自
Vellum 1.5 的反汇编（bad_query 路线，同思路重写，未拷贝代码）。每条路线
成败都记进日志与诊断 JSON，真机验证以日志为准。

## GPL-3.0 开源义务

worse_query 按 GPL-3.0 授权。把它链接进本项目后，**对外分发含这部分代码
的安装包（.ipa）时，对应部分的源代码必须按 GPL-3.0 提供**。本仓库私有
不影响义务——分发行为才触发。上游版权声明已保留在各文件头部。
