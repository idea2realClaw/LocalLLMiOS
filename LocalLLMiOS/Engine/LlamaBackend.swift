import Foundation
import llama

// MARK: - 统一错误类型

enum WikiError: LocalizedError {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case contextFailed(String)
    case tokenizeFailed
    case decodeFailed(Int32)
    case embeddingsUnavailable
    case unsupportedFormat(String)
    case emptyDocument(String)
    case database(String)
    case noResults
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let n): return "缺少模型文件：\(n)。请到「模型」页导入。"
        case .modelLoadFailed(let n): return "模型加载失败：\(n)。请确认 GGUF 完整且与 llama.cpp 版本兼容。"
        case .contextFailed(let m): return "创建推理上下文失败：\(m)。可尝试在设置里调小「上下文长度」。"
        case .tokenizeFailed: return "分词失败。"
        case .decodeFailed(let c): return "推理失败（llama_decode 返回 \(c)）。"
        case .embeddingsUnavailable: return "嵌入模型未输出向量。请检查 bge GGUF 是否完整。"
        case .unsupportedFormat(let e): return "暂不支持 .\(e) 格式。"
        case .emptyDocument(let n): return "《\(n)》没有可提取的文本（可能是扫描版 PDF）。"
        case .database(let m): return "本地索引数据库错误：\(m)"
        case .noResults: return "书库里没有可检索的内容，请先导入一本书。"
        case .cancelled: return "已取消。"
        }
    }
}

// MARK: - 路径

enum AppPaths {
    static let qwenFileName = "qwen35-4b-Q4_K_M.gguf"
    static let bgeFileName = "bge-small-zh-v1.5-f16.gguf"

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var modelsDir: URL {
        let url = documents.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var databaseURL: URL {
        documents.appendingPathComponent("wiki.sqlite3")
    }

    static var booksDir: URL {
        let url = documents.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func modelURL(_ name: String) -> URL {
        modelsDir.appendingPathComponent(name)
    }

    /// 开发调试时若把 GGUF 拖进了 App Bundle，也会自动识别。
    static func resolvedModelURL(_ name: String) -> URL? {
        let local = modelURL(name)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil) { return bundled }
        return nil
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
    }
}

// MARK: - llama.cpp 后端

enum LlamaBackend {
    private static let lock = NSLock()
    private static var initialized = false

    /// 必须在任意 llama_* 调用之前执行一次。
    static func initialize() {
        lock.lock()
        defer { lock.unlock() }
        guard !initialized else { return }
        llama_backend_init()
        initialized = true
    }

    static var version: String {
        String(cString: llama_version())
    }

    /// 建议的线程数：性能核数量，避免大小核全开拖慢。
    static var recommendedThreads: Int32 {
        Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }
}
