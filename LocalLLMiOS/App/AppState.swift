import Foundation
import SwiftUI

/// 全局状态。所有模型推理与 sqlite 操作都在串行后台队列，UI 更新显式回主线程。
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var books: [Book] = []
    @Published var messages: [ChatMessage] = []
    @Published var citations: [Citation] = []
    @Published var selectedBookIDs: Set<String> = []      // 空 = 检索全部
    @Published var selectedCitation: Citation?
    @Published var chapters: [(title: String, count: Int)] = []
    @Published var chapterChunks: [Chunk] = []
    @Published var activeBookID: String?

    @Published var isBusy = false
    @Published var busyKind: BusyKind = .idle
    @Published var status = ""
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    @Published var notice: String?

    enum BusyKind { case idle, importing, answering }

    let pipeline = RAGPipeline.shared
    let models = ModelManager.shared
    let settings = AppSettings.shared

    private let queue = DispatchQueue(label: "wiki.rag.serial", qos: .userInitiated)

    private init() {
        if let err = pipeline.storeError {
            errorMessage = "索引初始化失败：\(err)"
        }
    }

    // MARK: - 书库

    func reloadBooks() {
        do {
            books = try pipeline.books()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importBook(url: URL) {
        guard !isBusy else { return }
        isBusy = true
        busyKind = .importing
        progress = 0
        status = "准备导入…"
        errorMessage = nil
        queue.async {
            self.pipeline.importBook(from: url, progress: { text, value in
                DispatchQueue.main.async {
                    self.status = text
                    self.progress = value
                }
            }, completion: { result in
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.busyKind = .idle
                    switch result {
                    case .success(let book):
                        self.notice = "《\(book.displayTitle)》已建立 \(book.chunkCount) 个知识块"
                        self.reloadBooks()
                        self.loadChapters(of: book.id)
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                    self.progress = 0
                }
            })
        }
    }

    func deleteBook(_ book: Book) {
        do {
            try pipeline.deleteBook(id: book.id)
            selectedBookIDs.remove(book.id)
            if activeBookID == book.id { activeBookID = nil; chapters = []; chapterChunks = [] }
            reloadBooks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleScope(_ book: Book) {
        if selectedBookIDs.contains(book.id) { selectedBookIDs.remove(book.id) }
        else { selectedBookIDs.insert(book.id) }
    }

    func loadChapters(of bookId: String) {
        activeBookID = bookId
        do { chapters = try pipeline.chapters(of: bookId) }
        catch { chapters = []; errorMessage = error.localizedDescription }
        chapterChunks = []
    }

    func openChapter(_ title: String) {
        guard let bookId = activeBookID else { return }
        do { chapterChunks = try pipeline.chunks(in: bookId, chapter: title) }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: - 问答

    func ask(_ rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy else { return }
        guard models.allReady else {
            errorMessage = "模型尚未就绪，请先到「模型」页导入或下载两个 GGUF。"
            return
        }

        isBusy = true
        busyKind = .answering
        status = "检索书籍知识块…"
        errorMessage = nil
        citations = []
        messages.append(ChatMessage(role: .user, content: question))
        messages.append(ChatMessage(role: .assistant, content: "", citations: [], isStreaming: true))
        let answerIndex = messages.count - 1
        let scope = selectedBookIDs

        queue.async {
            self.pipeline.ask(question: question,
                              scope: scope,
                              onCitations: { hits in
                DispatchQueue.main.async {
                    self.citations = hits
                    self.status = "Qwen3.5-4B 正在依据 \(hits.count) 段原文作答…"
                }
            }, onUpdate: { text in
                DispatchQueue.main.async {
                    guard answerIndex < self.messages.count else { return }
                    self.messages[answerIndex].content = text
                }
            }, completion: { result in
                DispatchQueue.main.async {
                    guard answerIndex < self.messages.count else { return }
                    self.messages[answerIndex].isStreaming = false
                    self.messages[answerIndex].citations = self.citations
                    switch result {
                    case .success:
                        self.status = "完成 · 全程本地离线"
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                        if self.messages[answerIndex].content.isEmpty {
                            self.messages[answerIndex].content = "（生成失败：\(error.localizedDescription)）"
                        }
                        self.status = "出错"
                    }
                    self.isBusy = false
                    self.busyKind = .idle
                }
            })
        }
    }

    func stop() {
        pipeline.cancelGeneration()
        status = "已停止生成"
    }

    func clearChat() {
        messages = []
        citations = []
        status = ""
    }

    func releaseEngines() {
        pipeline.releaseEngines()
        notice = "已释放模型内存，下次提问会重新加载"
    }
}
