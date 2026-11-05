import Foundation

enum TextChunker {
    /// 把解析出的章节切成带 overlap 的知识块。
    /// bge-small-zh-v1.5 上下文 512 token，中文约 1 字 1 token，默认 300 字留足余量。
    static func chunk(bookId: String,
                      bookTitle: String,
                      sections: [ParsedSection],
                      size: Int,
                      overlap: Int) -> [Chunk] {
        let target = max(120, min(420, size))
        let back = max(0, min(target / 3, overlap))
        let breakChars = CharacterSet(charactersIn: "。！？!?\n；;，, ")

        var result: [Chunk] = []
        var sequence: Int64 = 1

        for section in sections {
            let body = normalize(section.text)
            guard body.count > 0 else { continue }
            var start = body.startIndex

            while start < body.endIndex {
                let hardEnd = body.index(start, offsetBy: target, limitedBy: body.endIndex) ?? body.endIndex
                var end = hardEnd
                if hardEnd < body.endIndex {
                    let searchFrom = body.index(start, offsetBy: target / 2, limitedBy: hardEnd) ?? start
                    let window = searchFrom..<hardEnd
                    if let r = body.rangeOfCharacter(from: breakChars, options: .backwards, range: window) {
                        end = body.index(after: r.lowerBound)
                    }
                }
                if end <= start { end = hardEnd }

                let piece = String(body[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if piece.count >= 15 {
                    result.append(Chunk(id: sequence,
                                        bookId: bookId,
                                        bookTitle: bookTitle,
                                        chapter: section.title,
                                        page: section.page,
                                        text: piece))
                    sequence += 1
                }
                guard end < body.endIndex else { break }
                let candidate = body.index(end, offsetBy: -back, limitedBy: body.startIndex) ?? start
                start = candidate > start ? candidate : end
            }
        }
        return result
    }

    /// 压缩空白、去掉 PDF 抽取常见的孤立连字符换行。
    private static func normalize(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "-\n", with: "")
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 送入 bge 的文本：带上书名与章节，提升章节级问题的召回率。
    static func embeddingText(_ chunk: Chunk) -> String {
        "《\(chunk.bookTitle)》\(chunk.chapter)\n\(chunk.text)"
    }
}
