import Foundation
import llama
import Accelerate

/// BAAI/bge-small-zh-v1.5 (GGUF) 中文嵌入引擎。
/// GGUF 元数据：architecture=bert, pooling_type=CLS(2), embedding_length=512, context_length=512。
/// 向量做 L2 归一化，检索时余弦相似度退化为点积。
final class EmbeddingEngine {

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?

    let dimension: Int
    let maxTokens: Int32 = 510

    init(path: URL) throws {
        LlamaBackend.initialize()

        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        guard let m = llama_model_load_from_file(path.path, mp) else {
            throw WikiError.modelLoadFailed(path.lastPathComponent)
        }
        self.model = m

        var cp = llama_context_default_params()
        cp.n_ctx = 512
        cp.n_batch = 512
        cp.n_ubatch = 512              // 非因果模型要求 n_ubatch == n_batch
        cp.n_seq_max = 1
        cp.n_threads = LlamaBackend.recommendedThreads
        cp.n_threads_batch = LlamaBackend.recommendedThreads
        cp.pooling_type = LLAMA_POOLING_TYPE_CLS
        cp.attention_type = LLAMA_ATTENTION_TYPE_NON_CAUSAL
        cp.embeddings = true
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            self.model = nil
            throw WikiError.contextFailed("bge 嵌入上下文创建失败")
        }
        self.ctx = c
        self.vocab = llama_model_get_vocab(m)
        llama_set_embeddings(c, true)

        let d = Int(llama_model_n_embd_out(m))
        self.dimension = d > 0 ? d : Int(llama_model_n_embd(m))
        guard dimension > 0 else {
            throw WikiError.embeddingsUnavailable
        }
    }

    deinit { release() }

    func release() {
        if let c = ctx { llama_free(c); ctx = nil }
        if let m = model { llama_model_free(m); model = nil }
        vocab = nil
    }

    // MARK: - 编码

    private func tokenize(_ text: String) throws -> [llama_token] {
        guard let v = vocab else { throw WikiError.tokenizeFailed }
        let byteCount = text.utf8.count
        var capacity = byteCount + 16
        var tokens = [llama_token](repeating: 0, count: capacity)
        let n = text.withCString { cstr -> Int32 in
            llama_tokenize(v, cstr, Int32(byteCount), &tokens, Int32(capacity), true, false)
        }
        if n < 0 {
            capacity = Int(-n) + 8
            tokens = [llama_token](repeating: 0, count: capacity)
            let n2 = text.withCString { cstr -> Int32 in
                llama_tokenize(v, cstr, Int32(byteCount), &tokens, Int32(capacity), true, false)
            }
            guard n2 >= 0 else { throw WikiError.tokenizeFailed }
            return Array(tokens.prefix(Int(n2)))
        }
        return Array(tokens.prefix(Int(n)))
    }

    /// 单条文本 -> 归一化向量。
    func embed(_ text: String) throws -> [Float] {
        try embed([text])[0]
    }

    /// 批量编码。逐条 decode 并清空 KV，内存占用最小，适合在手机上建索引。
    func embed(_ texts: [String]) throws -> [[Float]] {
        guard let c = ctx else { throw WikiError.embeddingsUnavailable }
        var output: [[Float]] = []
        output.reserveCapacity(texts.count)

        for text in texts {
            let full = try tokenize(text)
            guard !full.isEmpty else {
                output.append([Float](repeating: 0, count: dimension))
                continue
            }
            let tokens = Array(full.prefix(Int(maxTokens)))
            let n = Int32(tokens.count)

            // 与官方 examples/embedding 一致：所有 token 都标记 output，
            // 使用显式 pos / seq_id，CLS pooling 后取 seq 0 的向量。
            var batch = llama_batch_init(n, 0, 1)
            defer { llama_batch_free(batch) }
            for i in 0..<Int(n) {
                batch.token[i] = tokens[i]
                batch.pos[i] = llama_pos(i)
                batch.n_seq_id[i] = 1
                if let seq = batch.seq_id[i] { seq[0] = 0 }
                batch.logits[i] = 1
            }

            if let mem = llama_get_memory(c) { llama_memory_clear(mem, true) }
            let rc = llama_decode(c, batch)
            guard rc == 0 else { throw WikiError.decodeFailed(rc) }

            guard let ptr = llama_get_embeddings_seq(c, 0) else {
                throw WikiError.embeddingsUnavailable
            }
            var vec = Array(UnsafeBufferPointer(start: ptr, count: dimension))
            Self.normalize(&vec)
            output.append(vec)
        }
        return output
    }

    static func normalize(_ v: inout [Float]) {
        guard !v.isEmpty else { return }
        var sum: Float = 0
        vDSP_svesq(v, 1, &sum, vDSP_Length(v.count))
        var scale: Float = 1.0 / sqrtf(max(sum, 1e-12))
        vDSP_vsmul(v, 1, &scale, &v, 1, vDSP_Length(v.count))
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(n))
        return Double(result)
    }
}
