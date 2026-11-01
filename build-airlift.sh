#!/bin/bash
# 现场编 AirliftFFI.xcframework（只编真机目标 aarch64-apple-ios，不编模拟器），
# 供 GitHub 工作流在 xcodebuild 之前跑。不要把编好的 xcframework 提交进仓库
# （约 127MB，网页上传传不上去）；rust-core 源码只有 3.1MB，随仓库走。
# 注意：不要像上游那样把 DEVELOPER_DIR 写死成 Xcode-beta.app，
# Runner 上没有那个路径，用默认 Xcode 即可。
set -euo pipefail

# 跟 App 目标的最低系统版本保持一致（pbxproj 里是 17.0）。
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

# 让非登录 shell 也能找到 cargo（CI 环境）。
# shellcheck disable=SC1090
source "$HOME/.cargo/env" 2>/dev/null || true

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/rust-core"

echo "==> 安装真机目标（如果还没有）"
rustup target add aarch64-apple-ios 2>/dev/null || true

echo "==> 编 Rust 静态库（release，真机）"
cargo build --locked --release --target aarch64-apple-ios

cd "$ROOT"
echo "==> 打包 AirliftFFI.xcframework"
rm -rf "$ROOT/AirliftFFI.xcframework"
xcodebuild -create-xcframework \
  -library rust-core/target/aarch64-apple-ios/release/libairlift_ffi.a \
  -headers rust-core/include \
  -output "$ROOT/AirliftFFI.xcframework"

echo "==> 完成"
