import Foundation

/// RAG 主编排：导入 → 解析 → 分块 → bge 编码 → SQLite 索引；
/// 提问 → bge 编码 → 余弦检索 → 组装带出处 Prompt → Qwen3.5-4B 流式生成。
final class RAGPipeline {
    static let shared = RAGPipeline()

    private(set) var store: VectorStore?
    private(set) var storeError: String?

    private var embedding: EmbeddingEngine?
    private var generator: LlamaEngine?
    private let engineLock = NSLock()

    private init() {
        do {
            store = try VectorStore()
        } catch {
            storeError = error.localizedDescription
        }
    }

    private func requireStore() throws -> VectorStore {
        guard let store else { throw WikiError.database(storeError ?? "索引未初始化") }
        return store
    }

    // MARK: - 引擎生命周期

    private func ensureEmbedding() throws -> EmbeddingEngine {
        engineLock.lock(); defer { engineLock.unlock() }
        if let e = embedding { return e }
        guard let url = ModelManager.shared.urlFor(AppPaths.bgeFileName) else {
            throw WikiError.modelNotFound(AppPaths.bgeFileName)
        }
        let e = try EmbeddingEngine(path: url)
        embedding = e
        return e
    }

    private func ensureGenerator() throws -> LlamaEngine {
        engineLock.lock(); defer { engineLock.unlock() }
        let settings = AppSettings.shared
        if let g = generator, g.nCtx == Int32(settings.contextSize) { return g }
        generator?.release()
        generator = nil
        guard let url = ModelManager.shared.urlFor(AppPaths.qwenFileName) else {
            throw WikiError.modelNotFound(AppPaths.qwenFileName)
        }
        let g = try LlamaEngine(path: url,
                                nCtx: settings.contextSize,
                                gpuLayers: settings.gpuLayers)
        generator = g
        return g
    }

    /// 收到内存警告或改了上下文长度时调用，释放 2.6GB 的模型占用。
    func releaseEngines() {
        engineLock.lock(); defer { engineLock.unlock() }
        generator?.release(); generator = nil
        embedding?.release(); embedding = nil
    }

    func cancelGeneration() {
        engineLock.lock(); let g = generator; engineLock.unlock()
        g?.cancel()
    }

    var generatorLoaded: Bool {
        engineLock.lock(); defer { engineLock.unlock() }
        return generator != nil
    }

    // MARK: - 导入书籍

    /// 同步执行，调用方需放在后台队列。progress 的 (阶段说明, 0~1)。
    func importBook(from source: URL,
                    progress: @escaping (String, Double) -> Void,
                    completion: @escaping (Result<Book, Error>) -> Void) {
        var createdBookId: String?
        do {
            let store = try requireStore()
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }

            let ext = source.pathExtension
            guard let format = BookFormat.from(fileExtension: ext) else {
                throw WikiError.unsupportedFormat(ext)
            }
            progress("读取《\(source.lastPathComponent)》", 0.02)

            // 留一份原书，便于以后重新索引
            let savedName = "\(UUID().uuidString).\(ext)"
            let savedURL = AppPaths.booksDir.appendingPathComponent(savedName)
            try? FileManager.default.copyItem(at: source, to: savedURL)

            let parsed = try BookParser.parse(url: source, format: format)
            progress("提取到 \(parsed.sections.count) 个章节", 0.10)

            let id = UUID().uuidString
            let settings = AppSettings.shared
            let chunks = TextChunker.chunk(bookId: id,
                                           bookTitle: parsed.title,
                                           sections: parsed.sections,
                                           size: settings.chunkSize,
                                           overlap: settings.chunkOverlap)
            guard !chunks.isEmpty else { throw WikiError.emptyDocument(parsed.title) }

            var book = Book(id: id,
                            title: parsed.title,
                            fileName: source.lastPathComponent,
                            format: format,
                            addedAt: Date(),
                            chunkCount: 0,
                            isIndexed: false)
            try store.insertBook(book)
            createdBookId = id

            let encoder = try ensureEmbedding()
            progress("bge 编码 \(chunks.count) 个知识块", 0.12)

            var vectors: [[Float]] = []
            vectors.reserveCapacity(chunks.count)
            let batchSize = 8
            var index = 0
            while index < chunks.count {
                let end = min(index + batchSize, chunks.count)
                let texts = (index..<end).map { TextChunker.embeddingText(chunks[$0]) }
                vectors.append(contentsOf: try encoder.embed(texts))
                index = end
                let ratio = 0.12 + 0.78 * Double(index) / Double(chunks.count)
                progress("向量化 \(index)/\(chunks.count)", ratio)
            }

            progress("写入本地索引", 0.93)
            try store.insertChunks(chunks, vectors: vectors)
            try store.setIndexed(bookId: id, chunkCount: chunks.count)
            book.chunkCount = chunks.count
            book.isIndexed = true
            progress("完成", 1.0)
            completion(.success(book))
        } catch {
            if let bid = createdBookId { try? store?.deleteBook(id: bid) }
            completion(.failure(error))
        }
    }

    func deleteBook(id: String) throws {
        try requireStore().deleteBook(id: id)
    }

    func books() throws -> [Book] { try requireStore().books() }
    func totalChunks() throws -> Int { try requireStore().totalChunks() }
    func chapters(of id: String) throws -> [(title: String, count: Int)] { try requireStore().chapters(of: id) }
    func chunks(in id: String, chapter: String? = nil) throws -> [Chunk] {
        try requireStore().chunks(in: id, chapter: chapter)
    }

    // MARK: - 问答

    /// 同步执行，调用方需放在后台队列。
    func ask(question: String,
             scope: Set<String>?,
             onCitations: @escaping ([Citation]) -> Void,
             onUpdate: @escaping (String) -> Void,
             completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let store = try requireStore()
            let settings = AppSettings.shared
            guard (try store.totalChunks()) > 0 else { throw WikiError.noResults }

            let encoder = try ensureEmbedding()
            let queryText = settings.queryInstructionEnabled
                ? AppSettings.bgeQueryPrefix + question
                : question
            let queryVector = try encoder.embed(queryText)

            let hits = try store.search(query: queryVector,
                                        topK: settings.topK,
                                        minScore: settings.minScore,
                                        bookIds: scope?.isEmpty == true ? nil : scope)
            guard !hits.isEmpty else { throw WikiError.noResults }
            onCitations(hits)

            let llm = try ensureGenerator()
            llm.prepare(temperature: settings.temperature)
            let (system, user) = Self.buildPrompt(question: question,
                                                  citations: hits,
                                                  contextSize: settings.contextSize,
                                                  maxTokens: settings.maxTokens)
            try llm.generate(system: system, user: user, maxTokens: settings.maxTokens) { text in
                onUpdate(text)
                return true
            }
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: - Prompt

    static let systemPrompt = """
    你是一台完全离线运行的「本地书籍 Wiki」问答助手。必须遵守：
    1. 只依据下方【参考资料】作答，禁止使用资料之外的知识，禁止编造书名、页码、人物或数字。
    2. 每个关键结论后标注来源编号，如 [1]、[2][3]，编号必须对应参考资料。
    3. 若资料不足以回答，先说明「书中未找到明确答案」，再客观概括资料里最接近的内容。
    4. 用中文回答，条理清晰、简洁；不要复述问题，不要输出思考过程或内部标签。
    """

    static func buildPrompt(question: String,
                            citations: [Citation],
                            contextSize: Int,
                            maxTokens: Int) -> (String, String) {
        // 中文约 1 字 ≈ 1 token；给 system、模板、回答留足余量。
        let budget = max(800, contextSize - maxTokens - systemPrompt.count - 256)
        var blocks: [String] = []
        var used = 0
        for c in citations {
            let header = "[\(c.index)] 《\(c.chunk.bookTitle)》· \(c.chunk.location)"
            let text = c.chunk.text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let block = "\(header)\n\(text)"
            if used + block.count > budget {
                let remain = budget - used - header.count - 40
                if remain > 80 {
                    blocks.append("\(header)\n\(String(text.prefix(remain)))…")
                }
                break
            }
            blocks.append(block)
            used += block.count + 8
        }
        let material = blocks.joined(separator: "\n\n")
        let user = """
        【参考资料】
        \(material)

        【问题】
        \(question)

        请仅依据上述参考资料回答，并在关键结论后标注引用编号。
        """
        return (systemPrompt, user)
    }
}
