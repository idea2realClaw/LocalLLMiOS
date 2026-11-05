import Foundation

enum BookFormat: String, Codable, CaseIterable, Identifiable {
    case pdf = "PDF"
    case epub = "EPUB"
    case txt = "TXT"
    case md = "Markdown"

    var id: String { rawValue }

    static func from(fileExtension: String) -> BookFormat? {
        switch fileExtension.lowercased() {
        case "pdf": return .pdf
        case "epub": return .epub
        case "txt", "text": return .txt
        case "md", "markdown": return .md
        default: return nil
        }
    }

    var utTypes: [String] {
        switch self {
        case .pdf: return ["com.adobe.pdf"]
        case .epub: return ["org.idpf.epub-container"]
        case .txt: return ["public.plain-text"]
        case .md: return ["public.plain-text", "net.daringfireball.markdown"]
        }
    }
}

struct Book: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var fileName: String
    var format: BookFormat
    var addedAt: Date
    var chunkCount: Int
    var isIndexed: Bool

    var displayTitle: String {
        title.isEmpty ? fileName : title
    }
}

/// 一个「知识块」，即向量检索的最小单位。
struct Chunk: Identifiable, Codable, Hashable {
    var id: Int64
    var bookId: String
    var bookTitle: String
    var chapter: String
    var page: Int?
    var text: String

    var location: String {
        var parts: [String] = []
        if !chapter.isEmpty { parts.append(chapter) }
        if let page, page > 0 { parts.append("第 \(page) 页") }
        return parts.isEmpty ? "正文" : parts.joined(separator: " · ")
    }
}

struct Citation: Identifiable {
    let index: Int
    let chunk: Chunk
    let score: Double

    var id: Int64 { chunk.id }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var content: String
    var citations: [Citation]
    var isStreaming: Bool

    enum Role: Equatable { case user, assistant }

    init(role: Role, content: String, citations: [Citation] = [], isStreaming: Bool = false) {
        self.role = role
        self.content = content
        self.citations = citations
        self.isStreaming = isStreaming
    }
}
