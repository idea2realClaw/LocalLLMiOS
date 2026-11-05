#!/usr/bin/env bash
# LocalLLMiOS 依赖安装脚本
# 幂等、支持断点续传。下载 llama.cpp 官方预编译 XCFramework 与两个 GGUF 模型。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
MODELS="$ROOT/Models"
LLAMA_BUILD="b12119"                       # 与 Vendor/.../Headers/llama.h 对应
QWEN_FILE="qwen35-4b-Q4_K_M.gguf"
BGE_FILE="bge-small-zh-v1.5-f16.gguf"
QWEN_MIN_BYTES=2700000000
BGE_MIN_BYTES=47000000

XCF_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_BUILD}/llama-${LLAMA_BUILD}-xcframework.zip"
QWEN_URL="https://www.modelscope.cn/api/v1/models/AtomicChat/Qwen3.5-4B-GGUF/repo?Revision=master&FilePath=${QWEN_FILE}"
QWEN_URL_ALT="https://hf-mirror.com/AtomicChat/Qwen3.5-4B-GGUF/resolve/main/${QWEN_FILE}"
BGE_URL="https://huggingface.co/CompendiumLabs/bge-small-zh-v1.5-gguf/resolve/main/${BGE_FILE}"
BGE_URL_ALT="https://hf-mirror.com/CompendiumLabs/bge-small-zh-v1.5-gguf/resolve/main/${BGE_FILE}"

mkdir -p "$VENDOR" "$MODELS"

say() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }
size_of() { stat -f%z "$1" 2>/dev/null || echo 0; }

fetch() {  # fetch <目标文件> <最小字节> <主URL> <备URL>
  local dest="$1" min="$2" url="$3" alt="$4" label="$5"
  if [[ -f "$dest" ]] && (( $(size_of "$dest") >= min )); then
    say "$label 已存在 ($(du -h "$dest" | cut -f1))，跳过"
    return 0
  fi
  say "下载 $label -> $dest"
  curl -L --retry 5 --retry-delay 2 -C - --progress-bar -o "$dest" "$url" || {
    say "主源失败，尝试备用源"
    curl -L --retry 5 --retry-delay 2 -C - --progress-bar -o "$dest" "$alt"
  }
  local sz; sz=$(size_of "$dest")
  if (( sz < min )); then
    echo "错误：$label 只有 $sz 字节，低于预期 $min 字节，请检查网络后重跑本脚本（支持断点续传）。" >&2
    exit 1
  fi
  say "$label 完成 ($(du -h "$dest" | cut -f1))"
}

# --- 1. llama.cpp XCFramework ---
XCF="$VENDOR/build-apple/llama.xcframework"
if [[ -d "$XCF" ]] && [[ -f "$XCF/ios-arm64/llama.framework/Headers/llama.h" ]]; then
  say "llama.xcframework 已存在，跳过"
else
  say "下载 llama.cpp ${LLAMA_BUILD} XCFramework (约 73MB)"
  curl -L --retry 5 --retry-delay 2 -C - --progress-bar -o /tmp/llama-${LLAMA_BUILD}-xcframework.zip "$XCF_URL"
  unzip -q -o /tmp/llama-${LLAMA_BUILD}-xcframework.zip -d "$VENDOR"
fi
[[ -f "$XCF/ios-arm64/llama.framework/Headers/llama.h" ]] || { echo "XCFramework 解压异常" >&2; exit 1; }
say "XCFramework 就绪：$XCF"

# --- 2. bge 中文嵌入模型 ---
fetch "$MODELS/$BGE_FILE" "$BGE_MIN_BYTES" "$BGE_URL" "$BGE_URL_ALT" "bge-small-zh-v1.5 (f16, 46MB)"

# --- 3. Qwen3.5-4B 生成模型 ---
fetch "$MODELS/$QWEN_FILE" "$QWEN_MIN_BYTES" "$QWEN_URL" "$QWEN_URL_ALT" "Qwen3.5-4B Q4_K_M (2.71GB)"

say "全部依赖就绪。"
echo
echo "下一步（需要完整 Xcode + iOS 真机）："
echo "  1. open $ROOT/LocalLLMiOS.xcodeproj"
echo "  2. 若要把模型送进手机，运行: python3 $ROOT/scripts/serve_models.py"
echo "     然后在 App 的「模型」页填入局域网地址下载，或用「文件」App / Finder 文件共享导入。"
echo
echo "注意：官方 XCFramework 只含 ios-arm64(真机) 与 macOS slice，不含 iOS 模拟器 slice。"
