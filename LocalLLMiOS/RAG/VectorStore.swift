import Foundation
import Accelerate

/// 本地向量库：系统自带 sqlite3，零第三方依赖。
/// 向量已 L2 归一化，检索时余弦相似度 = 点积；一本书几千块，全量内存计算足够快。
final class VectorStore {

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open(AppPaths.databaseURL.path, &handle)
        guard rc == SQLITE_OK, let h = handle else {
            throw WikiError.database("无法打开 \(AppPaths.databaseURL.lastPathComponent)（rc=\(rc)）")
        }
        db = h
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS books (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                filename TEXT NOT NULL,
                format TEXT NOT NULL,
                added_at REAL NOT NULL,
                chunk_count INTEGER NOT NULL DEFAULT 0,
                indexed INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id TEXT NOT NULL,
                book_title TEXT NOT NULL,
                chapter TEXT NOT NULL,
                page INTEGER NOT NULL DEFAULT 0,
                text TEXT NOT NULL,
                vec BLOB NOT NULL,
                dim INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_chunks_book ON chunks(book_id);
            """)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        guard rc == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(err)
            throw WikiError.database(message)
        }
    }

    // MARK: - 书籍

    func insertBook(_ book: Book) throws {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO books (id,title,filename,format,added_at,chunk_count,indexed) VALUES (?,?,?,?,?,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WikiError.database("prepare insertBook 失败")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, book.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, book.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, book.fileName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, book.format.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, book.addedAt.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 6, Int64(book.chunkCount))
        sqlite3_bind_int(stmt, 7, book.isIndexed ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw WikiError.database("写入书目失败") }
    }

    func setIndexed(bookId: String, chunkCount: Int) throws {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = "UPDATE books SET indexed=1, chunk_count=? WHERE id=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(chunkCount))
        sqlite3_bind_text(stmt, 2, bookId, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    func deleteBook(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE;")
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM chunks WHERE book_id=?;", -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
        try exec("COMMIT;")
        var s2: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM books WHERE id=?;", -1, &s2, nil) == SQLITE_OK {
            defer { sqlite3_finalize(s2) }
            sqlite3_bind_text(s2, 1, id, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(s2)
        }
    }

    func books() throws -> [Book] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,title,filename,format,added_at,chunk_count,indexed FROM books ORDER BY added_at DESC;", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var result: [Book] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(Book(id: columnString(stmt, 0),
                               title: columnString(stmt, 1),
                               fileName: columnString(stmt, 2),
                               format: BookFormat(rawValue: columnString(stmt, 3)) ?? .txt,
                               addedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                               chunkCount: Int(sqlite3_column_int(stmt, 5)),
                               isIndexed: sqlite3_column_int(stmt, 6) != 0))
        }
        return result
    }

    func totalChunks() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM chunks;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - 写入向量

    func insertChunks(_ chunks: [Chunk], vectors: [[Float]]) throws {
        guard chunks.count == vectors.count else { throw WikiError.database("块数量与向量数量不一致") }
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE;")
        var stmt: OpaquePointer?
        let sql = "INSERT INTO chunks (book_id,book_title,chapter,page,text,vec,dim) VALUES (?,?,?,?,?,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            try? exec("ROLLBACK;")
            throw WikiError.database("prepare insertChunks 失败")
        }
        defer { sqlite3_finalize(stmt) }
        for (chunk, vec) in zip(chunks, vectors) {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, chunk.bookId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, chunk.bookTitle, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, chunk.chapter, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, Int32(chunk.page ?? 0))
            sqlite3_bind_text(stmt, 5, chunk.text, -1, SQLITE_TRANSIENT)
            let bytes = vec.withUnsafeBufferPointer { Data(buffer: $0) }
            bytes.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 6, raw.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int(stmt, 7, Int32(vec.count))
            if sqlite3_step(stmt) != SQLITE_DONE {
                try? exec("ROLLBACK;")
                throw WikiError.database("写入知识块失败")
            }
        }
        try exec("COMMIT;")
    }

    // MARK: - 检索

    func search(query: [Float], topK: Int, minScore: Double, bookIds: Set<String>?) throws -> [Citation] {
        lock.lock(); defer { lock.unlock() }
        var sql = "SELECT id,book_id,book_title,chapter,page,text,vec,dim FROM chunks"
        if let ids = bookIds, !ids.isEmpty {
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            sql += " WHERE book_id IN (\(marks))"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WikiError.database("检索准备失败")
        }
        defer { sqlite3_finalize(stmt) }
        if let ids = bookIds, !ids.isEmpty {
            for (i, id) in ids.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), id, -1, SQLITE_TRANSIENT)
            }
        }

        struct Hit { let chunk: Chunk; let score: Double }
        var hits: [Hit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let page = Int(sqlite3_column_int(stmt, 4))
            let chunk = Chunk(id: sqlite3_column_int64(stmt, 0),
                              bookId: columnString(stmt, 1),
                              bookTitle: columnString(stmt, 2),
                              chapter: columnString(stmt, 3),
                              page: page > 0 ? page : nil,
                              text: columnString(stmt, 5))
            let dim = Int(sqlite3_column_int(stmt, 7))
            guard let blob = sqlite3_column_blob(stmt, 6), dim > 0 else { continue }
            let count = min(dim, Int(sqlite3_column_bytes(stmt, 6)) / MemoryLayout<Float>.size)
            var vec = [Float](repeating: 0, count: count)
            vec.withUnsafeMutableBytes { memcpy($0.baseAddress!, blob, count * MemoryLayout<Float>.size) }
            let score = EmbeddingEngine.dot(query, vec)
            if score >= minScore { hits.append(Hit(chunk: chunk, score: score)) }
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(max(1, topK))).enumerated().map {
            Citation(index: $0.offset + 1, chunk: $0.element.chunk, score: $0.element.score)
        }
    }

    /// Wiki 侧栏：按章节浏览原文。
    func chapters(of bookId: String) throws -> [(title: String, count: Int)] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT chapter, COUNT(*) FROM chunks WHERE book_id=? GROUP BY chapter ORDER BY MIN(id);", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
        var result: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append((columnString(stmt, 0), Int(sqlite3_column_int(stmt, 1))))
        }
        return result
    }

    func chunks(in bookId: String, chapter: String? = nil) throws -> [Chunk] {
        lock.lock(); defer { lock.unlock() }
        let sql = chapter == nil
            ? "SELECT id,book_id,book_title,chapter,page,text FROM chunks WHERE book_id=? ORDER BY id LIMIT 500;"
            : "SELECT id,book_id,book_title,chapter,page,text FROM chunks WHERE book_id=? AND chapter=? ORDER BY id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
        if let chapter { sqlite3_bind_text(stmt, 2, chapter, -1, SQLITE_TRANSIENT) }
        var result: [Chunk] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let page = Int(sqlite3_column_int(stmt, 4))
            result.append(Chunk(id: sqlite3_column_int64(stmt, 0),
                                bookId: columnString(stmt, 1),
                                bookTitle: columnString(stmt, 2),
                                chapter: columnString(stmt, 3),
                                page: page > 0 ? page : nil,
                                text: columnString(stmt, 5)))
        }
        return result
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: UnsafeRawPointer(p).assumingMemoryBound(to: CChar.self))
    }
}
