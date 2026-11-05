#!/usr/bin/env bash
#
# 给官方 llama.xcframework 补上 iOS 模拟器 slice（arm64 + x86_64）。
# 官方 release 只带 ios-arm64 与 macos-arm64_x86_64，想在模拟器里跑 App 需要本脚本。
#
# 用法：
#   ./scripts/enable_simulator.sh                  # 完整流程：准备 CMake/源码 → 编译 ios-sim → 合成
#   ./scripts/enable_simulator.sh --merge-only    # 已经编好时只做合成（可配 LLAMA_SRC_DIR）
#
# 可选环境变量：
#   LLAMA_SIM_WORKDIR    工作目录，默认 /tmp/llama-sim-b12119
#   LLAMA_SRC_DIR        llama.cpp 源码目录，默认 $WORKDIR/src
#   LLAMA_SIM_FRAMEWORK 已编好的模拟器 framework 路径
#
# 全程只写 /tmp 与 Vendor/（后者可用 setup.sh 复原），不改动系统目录。
set -euo pipefail

LLAMA_TAG=b12119
CMAKE_VERSION=3.31.12
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${LLAMA_SIM_WORKDIR:-/tmp/llama-sim-${LLAMA_TAG}}"
SRC_DIR="${LLAMA_SRC_DIR:-$WORKDIR/src}"
XCF="$ROOT/Vendor/build-apple/llama.xcframework"
SIM_FW="${LLAMA_SIM_FRAMEWORK:-$SRC_DIR/build-ios-sim/framework/llama.framework}"
CMAKE_DIR="$WORKDIR/cmake-${CMAKE_VERSION}/CMake.app/Contents/bin"
MERGE_ONLY=0
if [ "${1:-}" = "--merge-only" ]; then MERGE_ONLY=1; fi

log() { printf '\n==> %s\n' "$*"; }

# ---- 0. 前置检查 ----------------------------------------------------------
command -v xcodebuild >/dev/null 2>&1 || { echo "错误：需要完整 Xcode（CommandLineTools 不够）"; exit 1; }
if [ ! -d "$XCF" ]; then
    echo "错误：未找到 $XCF，请先执行 ./scripts/setup.sh 下载官方框架"
    exit 1
fi
if [ -d "$XCF/ios-arm64_x86_64-simulator" ]; then
    echo "已包含模拟器 slice，无需重复执行：$XCF"
    exit 0
fi

# ---- 1. 准备 CMake（官方 tarball，纯解压，不装系统）----------------------
if [ "$MERGE_ONLY" -eq 0 ]; then
    mkdir -p "$WORKDIR"
    if [ ! -x "$CMAKE_DIR/cmake" ]; then
        log "下载 CMake ${CMAKE_VERSION} 到 $WORKDIR"
        curl -fL --retry 3 --max-time 900 -o "$WORKDIR/cmake.tar.gz" \
            "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-macos-universal.tar.gz"
        mkdir -p "$WORKDIR/cmake-${CMAKE_VERSION}"
        tar -xzf "$WORKDIR/cmake.tar.gz" -C "$WORKDIR/cmake-${CMAKE_VERSION}" --strip-components=1
    fi
    "$CMAKE_DIR/cmake" --version | head -1

    # ---- 2. 准备 llama.cpp 源码 ------------------------------------------
    if [ ! -f "$SRC_DIR/CMakeLists.txt" ]; then
        log "下载 llama.cpp ${LLAMA_TAG} 源码"
        curl -fL --retry 3 --max-time 900 -o "$WORKDIR/llama.tar.gz" \
            "https://github.com/ggml-org/llama.cpp/archive/refs/tags/${LLAMA_TAG}.tar.gz"
        mkdir -p "$SRC_DIR"
        tar -xzf "$WORKDIR/llama.tar.gz" -C "$SRC_DIR" --strip-components=1
    fi

    # ---- 3. 编译模拟器 slice（脚本自带日志 build_ios_sim.log）-------------
    log "编译 iOS 模拟器 slice（约 10-20 分钟，日志：$SRC_DIR/build_ios_sim.log）"
    ( cd "$SRC_DIR" && PATH="$CMAKE_DIR:$PATH" ./build-xcframework.sh ios-sim )
fi

if [ ! -d "$SIM_FW" ]; then
    echo "错误：未找到模拟器 framework：$SIM_FW"
    echo "可用 LLAMA_SIM_FRAMEWORK=/path/to/llama.framework 指定"
    exit 1
fi

# ---- 4. 备份官方框架后合成三 slice ----------------------------------------
BACKUP="$ROOT/Vendor/build-apple/llama.xcframework.official"
if [ -d "$BACKUP" ]; then BACKUP="${BACKUP}-$(date +%Y%m%d%H%M%S)"; fi
log "备份官方框架到 $BACKUP"
mv "$XCF" "$BACKUP"

ARGS=()
for slice in ios-arm64 macos-arm64_x86_64; do
    fw="$BACKUP/$slice/llama.framework"
    if [ -d "$fw" ]; then
        ARGS+=( -framework "$fw" )
        dsym="$BACKUP/$slice/dSYMs/llama.dSYM"
        if [ -d "$dsym" ]; then ARGS+=( -debug-symbols "$dsym" ); fi
    fi
done
ARGS+=( -framework "$SIM_FW" )

log "合成 XCFramework（真机 + 模拟器 + macOS）"
if ! xcrun xcodebuild -create-xcframework "${ARGS[@]}" -output "$XCF"; then
    echo "合成失败，恢复官方框架"
    rm -rf "$XCF"
    mv "$BACKUP" "$XCF"
    exit 1
fi

log "完成：$XCF"
plutil -p "$XCF/Info.plist" | grep -E "LibraryIdentifier|SupportedPlatform|SupportedPlatformVariant" || true
echo "现在可在 Xcode 里选任意 iOS 模拟器直接 Run。"
