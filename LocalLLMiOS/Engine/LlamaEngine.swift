import Foundation
import llama

/// Qwen3.5-4B (GGUF) 生成引擎。
/// 所有 llama_* 调用都在调用方所在的线程上同步执行；UI 层负责切到后台队列。
final class LlamaEngine {

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?

    private let lock = NSLock()
    private var cancelled = false

    let nCtx: Int32
    let modelPath: String

    var isLoaded: Bool { model != nil && ctx != nil }

    init(path: URL, nCtx: Int = 4096, gpuLayers: Int = -1) throws {
        LlamaBackend.initialize()
        self.modelPath = path.path
        self.nCtx = Int32(nCtx)

        var mp = llama_model_default_params()
        mp.n_gpu_layers = Int32(gpuLayers)      // -1 = 全量 Metal offload
        guard let m = llama_model_load_from_file(path.path, mp) else {
            throw WikiError.modelLoadFailed(path.lastPathComponent)
        }
        self.model = m

        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(nCtx)
        cp.n_batch = 512
        cp.n_ubatch = 256
        cp.n_threads = LlamaBackend.recommendedThreads
        cp.n_threads_batch = LlamaBackend.recommendedThreads
        cp.pooling_type = LLAMA_POOLING_TYPE_NONE
        cp.embeddings = false
        cp.offload_kqv = true
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            self.model = nil
            throw WikiError.contextFailed("内存不足？Qwen3.5-4B Q4_K_M 需要约 3GB 可用内存")
        }
        self.ctx = c
        self.vocab = llama_model_get_vocab(m)

        var sp = llama_sampler_chain_default_params()
        let s = llama_sampler_chain_init(sp)
        llama_sampler_chain_add(s, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(s, llama_sampler_init_top_p(0.90, 1))
        llama_sampler_chain_add(s, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(s, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        self.sampler = s
    }

    deinit { release() }

    func release() {
        if let s = sampler { llama_sampler_free(s); sampler = nil }
        if let c = ctx { llama_free(c); ctx = nil }
        if let m = model { llama_model_free(m); model = nil }
        vocab = nil
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func resetCancel() {
        lock.lock(); cancelled = false; lock.unlock()
    }

    /// 每次回答前调用，把采样链重置、KV 清空，并更新温度。
    func prepare(temperature: Double) {
        if let s = sampler { llama_sampler_reset(s) }
        if let c = ctx, let mem = llama_get_memory(c) { llama_memory_clear(mem, true) }
        // 温度不可动态改，重新构建采样链
        if let s = sampler { llama_sampler_free(s) }
        var sp = llama_sampler_chain_default_params()
        let ns = llama_sampler_chain_init(sp)
        let t = Float(max(0.05, min(1.5, temperature)))
        llama_sampler_chain_add(ns, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(ns, llama_sampler_init_top_p(0.90, 1))
        llama_sampler_chain_add(ns, llama_sampler_init_temp(t))
        llama_sampler_chain_add(ns, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        sampler = ns
    }

    // MARK: - 分词 / 模板

    private func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) throws -> [llama_token] {
        guard let v = vocab else { throw WikiError.tokenizeFailed }
        let byteCount = text.utf8.count
        var capacity = byteCount + 16
        var tokens = [llama_token](repeating: 0, count: capacity)
        let n = text.withCString { cstr -> Int32 in
            llama_tokenize(v, cstr, Int32(byteCount), &tokens, Int32(capacity), addSpecial, parseSpecial)
        }
        if n < 0 {
            capacity = Int(-n) + 8
            tokens = [llama_token](repeating: 0, count: capacity)
            let n2 = text.withCString { cstr -> Int32 in
                llama_tokenize(v, cstr, Int32(byteCount), &tokens, Int32(capacity), addSpecial, parseSpecial)
            }
            guard n2 >= 0 else { throw WikiError.tokenizeFailed }
            return Array(tokens.prefix(Int(n2)))
        }
        return Array(tokens.prefix(Int(n)))
    }

    private func tokenBytes(_ id: llama_token) -> [UInt8] {
        guard let v = vocab else { return [] }
        var buf = [CChar](repeating: 0, count: 128)
        let n = llama_token_to_piece(v, id, &buf, 127, 0, false)
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    /// 优先使用 GGUF 自带的 chat template；失败时回退到 Qwen ChatML。
    private func formatChat(system: String, user: String) -> String {
        let fallback = """
        <|im_start|>system
        \(system)<|im_end|>
        <|im_start|>user
        \(user)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        """
        guard let m = model, let tmpl = llama_model_chat_template(m, nil) else { return fallback }

        let roles = [strdup("system"), strdup("user")]
        let contents = [strdup(system), strdup(user)]
        defer {
            roles.forEach { if let p = $0 { free(p) } }
            contents.forEach { if let p = $0 { free(p) } }
        }
        var messages = [llama_chat_message]()
        for i in 0..<2 {
            guard let r = roles[i], let c = contents[i] else { return fallback }
            messages.append(llama_chat_message(role: UnsafePointer(r), content: UnsafePointer(c)))
        }

        var capacity = system.utf8.count + user.utf8.count + 1024
        for _ in 0..<3 {
            var buf = [CChar](repeating: 0, count: capacity + 1)
            let needed = messages.withUnsafeBufferPointer { ptr -> Int32 in
                llama_chat_apply_template(tmpl, ptr.baseAddress, 2, true, &buf, Int32(capacity))
            }
            if needed >= 0 && Int(needed) < capacity {
                let bytes = buf.prefix(Int(needed)).map { UInt8(bitPattern: $0) }
                return Self.closeThinking(String(decoding: bytes, as: UTF8.self))
            }
            capacity = max(capacity * 2, Int(needed) + 256)
        }
        return fallback
    }

    /// Qwen3.5 的 chat template 在 add_generation_prompt 时默认注入 "<think>\n"，
    /// 4B 小模型会先写几百 token 英文思考过程，把输出预算耗光。
    /// 模板的 enable_thinking=false 分支会注入 "<think>\n\n</think>\n\n"，
    /// 而 C API 无法传模板变量，所以在这里手工补上空的思考块（已用 b12119 实测）。
    static func closeThinking(_ prompt: String) -> String {
        if prompt.hasSuffix("<think>\n") { return prompt + "\n</think>\n\n" }
        if prompt.hasSuffix("<think>")   { return prompt + "\n\n</think>\n\n" }
        if prompt.contains("</think>")   { return prompt }
        return prompt + "<think>\n\n</think>\n\n"
    }

    /// 流式展示时隐藏思考段。兼容三种情形：完整 <think>…</think>、
    /// <think> 来自 prompt 而模型只吐出 </think> 尾巴、以及模型重新开了思考。
    static func stripThinking(_ s: String) -> String {
        var text = s
        if let start = text.range(of: "<think>") {
            if let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                return ""                       // 思考尚未结束，先不显示
            }
        } else if let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...])
        }
        if text.hasPrefix("[Start thinking]") || text.hasPrefix("Thinking Process:") {
            return ""
        }
        var out = text
        while let first = out.first, first == "\n" || first == "\r" || first == " " {
            out.removeFirst()
        }
        return out
    }

    // MARK: - 生成

    /// 同步阻塞的流式生成。onUpdate 传入「当前完整可见答案」，返回 false 可中止。
    func generate(system: String,
                  user: String,
                  maxTokens: Int,
                  onUpdate: @escaping (String) -> Bool) throws {
        guard let c = ctx, let v = vocab, let s = sampler else {
            throw WikiError.contextFailed("引擎未就绪")
        }
        resetCancel()

        let prompt = formatChat(system: system, user: user)
        var promptTokens = try tokenize(prompt, addSpecial: false, parseSpecial: true)
        guard !promptTokens.isEmpty else { throw WikiError.tokenizeFailed }

        let reserve = min(max(maxTokens, 1), 1024)
        if promptTokens.count + reserve > Int(nCtx) {
            // 超长时截断 RAG 上下文的头部，保留 system + 尾部检索结果
            let keep = max(256, Int(nCtx) - reserve - 64)
            promptTokens = Array(promptTokens.suffix(keep))
        }

        // 分块 prefill，避免单次 batch 超过 n_batch
        let step = 256
        var offset = 0
        while offset < promptTokens.count {
            let n = min(step, promptTokens.count - offset)
            var slice = Array(promptTokens[offset..<(offset + n)])
            var batch = llama_batch_get_one(&slice, Int32(n))
            let rc = llama_decode(c, batch)
            guard rc == 0 else { throw WikiError.decodeFailed(rc) }
            offset += n
            if shouldStop { return }
        }

        var pending = [UInt8]()
        var raw = ""
        for _ in 0..<max(1, min(maxTokens, 2048)) {
            if shouldStop { break }
            let id = llama_sampler_sample(s, c, -1)
            if llama_vocab_is_eog(v, id) { break }

            pending.append(contentsOf: tokenBytes(id))
            if let piece = String(bytes: pending, encoding: .utf8) {
                pending.removeAll()
                raw += piece
                if !onUpdate(Self.stripThinking(raw)) { break }
            }

            var one = [id]
            var batch = llama_batch_get_one(&one, 1)
            let rc = llama_decode(c, batch)
            if rc != 0 { break }
        }
        if let rest = String(bytes: pending, encoding: .utf8), !rest.isEmpty {
            raw += rest
            _ = onUpdate(Self.stripThinking(raw))
        }
    }
}
