# LocalLLMiOS · 本地 AI Wiki

把一本书变成可以追问的离线 Wiki：**导入 PDF / EPUB / TXT / MD → bge 中文向量化 → 本地 SQLite 索引 → 检索原文片段 → Qwen3.5-4B 生成带引用编号的中文答案**。全程在 iPhone 上离线运行，不调用任何云端 API。

技术栈：SwiftUI + llama.cpp C API + Qwen3.5-4B GGUF + BAAI/bge-small-zh-v1.5 GGUF + 系统自带 PDFKit / zlib / sqlite3 / Accelerate。零第三方 Swift 依赖。

---

## 一、架构

```
                        ┌──────────── 导入 ────────────┐
 PDF/EPUB/TXT/MD  ──▶  BookParser  ──▶  TextChunker  ──▶  EmbeddingEngine(bge)
                       (PDFKit / ZIP)     (300字/块)         (512维, CLS, L2)
                                                              │
                                                              ▼
                                              VectorStore (SQLite: text + vec BLOB)
                                                              │
  提问 ──▶ EmbeddingEngine(问题 + 中文检索指令) ──▶ 余弦 Top-K ──▶ 拼带出处 Prompt
                                                              │
                                                              ▼
                                              LlamaEngine (Qwen3.5-4B, Metal)
                                                              │
                                                              ▼
                                          流式答案 + [1][2] 引用 → 点击回溯原文
```

源码分层：

| 目录 | 职责 |
|---|---|
| `LocalLLMiOS/Engine/` | `LlamaEngine`（生成 / chat template / sampler / 流式）、`EmbeddingEngine`（bge 编码）、`LlamaBackend`（后端初始化与路径） |
| `LocalLLMiOS/RAG/` | `BookParser`、`ZipReader`、`TextChunker`、`VectorStore`、`RAGPipeline`、`ModelManager` |
| `LocalLLMiOS/Views/` | 书库 / 章节树、问答、引用溯源、模型管理、设置 |
| `LocalLLMiOS/App/` | `@main`、`AppState`、`Info.plist`、Bridging-Header |
| `scripts/` | 依赖下载、局域网模型分发、Xcode 工程生成 |
| `Vendor/`、`Models/` | 预编译框架与 GGUF（被 `.gitignore` 忽略，用 `setup.sh` 获取） |

---

## 二、快速开始

### 1. 准备依赖（Mac 上执行一次）

```bash
cd /Users/zhuxiaodong/Documents/GitRepo/LocalLLMiOS
bash scripts/setup.sh
```

脚本幂等、支持断点续传，会下载：

| 文件 | 大小 | 用途 |
|---|---|---|
| `Vendor/build-apple/llama.xcframework`（b12119） | 73 MB | llama.cpp 官方预编译框架，Metal 已启用 |
| `Models/bge-small-zh-v1.5-f16.gguf` | 46 MB | 中文嵌入（512 维 / CLS pooling） |
| `Models/qwen35-4b-Q4_K_M.gguf` | 2.58 GiB | 生成模型（Q4_K_M） |

### 2. 用 Xcode 打开并编译

```bash
open LocalLLMiOS.xcodeproj
```

- **需要完整 Xcode**（CommandLineTools 不够，因为要 iOS SDK 与代码签名）。
- 在 target 的 *Signing & Capabilities* 里选自己的 Development Team。
- **必须选真机**：官方 XCFramework 只含 `ios-arm64`（真机）与 macOS slice，**没有 iOS 模拟器 slice**。工程已把 `SUPPORTED_PLATFORMS` 限定为 `iphoneos`。
- 最低系统 iOS 16.4（与框架一致），`SWIFT_VERSION = 5.0`。

> 如果要在模拟器上跑：在装了 Xcode 的机器上 `git clone https://github.com/ggml-org/llama.cpp`，执行 `./build-xcframework.sh ios-sim ios-device`，把产出的 `build-apple/llama.xcframework` 覆盖到 `Vendor/build-apple/`，再把工程里的 `SUPPORTED_PLATFORMS` 放宽。

### 3. 把两个 GGUF 送进手机（三选一）

**A. 局域网下载（推荐，最快）**

```bash
python3 scripts/serve_models.py
# 终端会打印形如 http://192.168.1.10:8899/<文件名> 的地址
```

App → 书库左上角「模型」→ 把地址（去掉文件名，以 `/` 结尾）填进输入框 → 分别点两个「下载」按钮。脚本支持 Range 断点续传，2.58 GiB 断了可以接着下。手机与 Mac 需同一 Wi-Fi。

**B. 文件 App 导入**：模型页点「选择 xxx.gguf」，从「文件」App 里选本地 GGUF。

**C. Finder 文件共享**：iPhone 连 Mac，Finder → 设备 → 文件 → 拖入 `LocalLLMiOS` 的 Documents 目录（Info.plist 已开启 `UIFileSharingEnabled`）。

模型存放位置：`App Documents/Models/`，文件名必须是 `qwen35-4b-Q4_K_M.gguf` 与 `bge-small-zh-v1.5-f16.gguf`。

### 4. 用起来

1. 「书库」→ 导入一本书（PDF / EPUB / TXT / MD）。首次会切块并用 bge 逐块编码，几千块大约需要几分钟，界面有进度。
2. 勾选书籍可限定检索范围，不勾选则检索全部；点章节图标可浏览该书的章节树与原文。
3. 「问答」输入问题 → 先检索 Top-K 原文片段 → Qwen3.5-4B 流式作答，答案里带 `[1]` `[2]`。
4. 「引用」页可看每个片段的书名、章节、页码、相似度；点气泡里的编号可弹窗核对原文。

---

## 三、关键实现细节

- **bge 参数按 GGUF 元数据实测确定**：`architecture=bert`、`pooling_type=CLS(2)`、`embedding_length=512`、`context_length=512`。上下文创建时显式设 `LLAMA_POOLING_TYPE_CLS` + `LLAMA_ATTENTION_TYPE_NON_CAUSAL` + `n_ubatch == n_batch == 512`，向量做 L2 归一化，检索时余弦即点积（Accelerate `vDSP_dotpr`）。
- **分块默认 300 字 / 重叠 50 字**，中文约 1 字 1 token，留足 bge 的 512 上下文余量；编码时给每块加「《书名》章节」前缀提升召回。
- **问题加中文检索指令**（`为这个句子生成表示以用于检索相关文章：`），v1.5 不是必须，但对短问句检索长段落更稳，设置里可关。
- **Qwen3.5 默认开思考**：GGUF 自带 chat template 在 `add_generation_prompt` 时会注入 `<think>\n`，4B 模型会先写几百 token 英文思考把输出预算耗光。C API 无法传 `enable_thinking=false` 模板变量，所以 `LlamaEngine.closeThinking()` 在模板输出后补上空的 `<think>\n\n</think>\n\n`，等价于模板的关闭分支；`stripThinking()` 再做流式兜底过滤。
- **EPUB 零依赖解析**：`ZipReader` 自己读 ZIP central directory，用系统 zlib 的 `inflateInit2_(-MAX_WBITS)` 解 raw deflate；OPF 的 manifest/spine 决定章节顺序，XHTML 剥标签得到正文。PDF 用 PDFKit 逐页抽文本并记录页码，GB18030 编码的 TXT 自动回退。
- **索引存系统 SQLite**：`books` 表 + `chunks` 表（向量以 Float32 BLOB 存储），WAL 模式。检索把向量读进内存算余弦，一本书几千块毫秒级。
- **内存**：Qwen3.5-4B Q4_K_M 约 2.6 GB + KV cache，建议 **8GB 内存的 iPhone（15 Pro 及以上）**；设置页可把上下文从 4096 调到 2048，或点「释放模型内存」。

---

## 四、实测验证（llama.cpp b12119 / macOS arm64）

本机没有完整 Xcode 与 iOS SDK，**iOS App 本身未做真机编译**（这是当前唯一未验证环节）。但同版本 macOS 二进制已对两个 GGUF 与 RAG 链路做了真实推理验证：

| 验证项 | 结果 |
|---|---|
| Qwen3.5-4B GGUF 加载 | 成功，`architecture=qwen35`、`Q4_K - Medium`、build 12119 |
| bge GGUF 加载 | 成功，`bert` / CLS / 512 维 |
| bge 输出向量 | 512 维、L2 范数 = 1.0000 |
| 检索区分度 | 相关文档余弦 **0.4611** > 无关文档 **0.1823**，排序正确 |
| 默认思考模式 | 输出 `Thinking Process: 1. Analyze the Request...`，140 token 内无答案 ❌ |
| 注入空思考块 | 直接输出中文答案并带 `[1]` 引用 ✅ |
| 端到端 RAG | 4 个片段中「检索」相关片段相似度 0.6399 排第一；答案为「检索时，需先将问题加上中文检索指令并进行编码，随后在向量库中执行余弦相似度检索以获取最相关片段 [1]。最终系统会取 Top-5 最相关的片段 [1]。」——中文、带引用、无思考过程 ✅ |
| Swift 源码 | 19 个文件全部通过 `swiftc -parse` 语法解析 |
| Xcode 工程 | `plutil -lint` 通过，65 个对象、无悬空 ID 引用 |

工程文件由 `scripts/generate_xcodeproj.py` 生成（自动扫描源码、路径哈希生成稳定 ID），源码增删后重跑即可：

```bash
python3 scripts/generate_xcodeproj.py
```

---

## 五、设置项

| 参数 | 默认 | 说明 |
|---|---|---|
| Top-K | 5 | 检索返回的原文片段数 |
| 相似度下限 | 0.20 | 低于此值不送给模型；中文 bge 相关片段通常 0.4 以上 |
| 块大小 / 重叠 | 300 / 50 字 | 仅对新导入的书生效 |
| 最大输出 | 512 token | 关闭思考后足够 |
| 温度 | 0.7 | 问答建议 0.5–0.8 |
| 上下文长度 | 4096 | 改动后模型会重新加载；内存紧张就调到 2048 |
| Metal 卸载层数 | 全部(-1) | Apple Silicon 统一内存，默认全量 Metal |
| bge 检索指令 | 开 | 短问句检索长文档时有用 |

---

## 六、已知限制

1. **需要装了完整 Xcode 的 Mac 与真机**；本机只有 CommandLineTools，因此未做 `xcodebuild` 与真机运行验证。
2. **不支持 iOS 模拟器**（官方 XCFramework 缺 simulator slice），见上文重建方法。
3. **扫描版 PDF 无文本层**会报「没有可提取的文本」，需先 OCR。
4. 首次导入一本长书要逐块跑 bge，属于正常耗时；导入过程中不要切到后台太久。
5. 2.6 GB 模型在 6 GB 以下内存的 iPhone 上可能被系统杀掉进程，属 iOS jetsam 限制。
6. 问答是单轮 RAG（不做多轮对话历史压缩），每次提问独立检索；清空对话不影响书库索引。
7. 模型下载需要网络（局域网或公网），**问答与索引阶段完全离线**。

---

## 七、模型来源与许可

- Qwen3.5-4B：`Qwen/Qwen3.5-4B`（Apache-2.0），GGUF 量化版 `AtomicChat/Qwen3.5-4B-GGUF`
- bge-small-zh-v1.5：`BAAI/bge-small-zh-v1.5`（MIT），GGUF 版 `CompendiumLabs/bge-small-zh-v1.5-gguf`
- llama.cpp：`ggml-org/llama.cpp`（MIT），预编译 XCFramework 取 release `b12119`
