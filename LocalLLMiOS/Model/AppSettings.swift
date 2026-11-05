import Foundation
import Combine

/// 用户可调的 RAG / 推理参数，全部存在 UserDefaults。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    @Published var topK: Int {
        didSet { d.set(topK, forKey: "topK") }
    }
    @Published var chunkSize: Int {
        didSet { d.set(chunkSize, forKey: "chunkSize") }
    }
    @Published var chunkOverlap: Int {
        didSet { d.set(chunkOverlap, forKey: "chunkOverlap") }
    }
    @Published var maxTokens: Int {
        didSet { d.set(maxTokens, forKey: "maxTokens") }
    }
    @Published var temperature: Double {
        didSet { d.set(temperature, forKey: "temperature") }
    }
    @Published var contextSize: Int {
        didSet { d.set(contextSize, forKey: "contextSize") }
    }
    @Published var gpuLayers: Int {
        didSet { d.set(gpuLayers, forKey: "gpuLayers") }
    }
    @Published var queryInstructionEnabled: Bool {
        didSet { d.set(queryInstructionEnabled, forKey: "queryInstructionEnabled") }
    }
    @Published var minScore: Double {
        didSet { d.set(minScore, forKey: "minScore") }
    }

    /// bge-small-zh-v1.5 的非对称检索 query 指令（v1.5 可不加，加上对短问句更稳）。
    static let bgeQueryPrefix = "为这个句子生成表示以用于检索相关文章："

    private init() {
        // register(defaults:) 保证首次启动也有值
        d.register(defaults: [
            "topK": 5,
            "chunkSize": 300,
            "chunkOverlap": 50,
            "maxTokens": 512,
            "temperature": 0.7,
            "contextSize": 4096,
            "gpuLayers": -1,      // -1 = 全部层交给 Metal
            "queryInstructionEnabled": true,
            "minScore": 0.20
        ])
        topK = d.integer(forKey: "topK")
        chunkSize = d.integer(forKey: "chunkSize")
        chunkOverlap = d.integer(forKey: "chunkOverlap")
        maxTokens = d.integer(forKey: "maxTokens")
        temperature = d.double(forKey: "temperature")
        contextSize = d.integer(forKey: "contextSize")
        gpuLayers = d.integer(forKey: "gpuLayers")
        queryInstructionEnabled = d.bool(forKey: "queryInstructionEnabled")
        minScore = d.double(forKey: "minScore")
    }
}
