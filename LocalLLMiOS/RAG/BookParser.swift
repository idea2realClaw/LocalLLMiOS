import Foundation
import PDFKit

struct ParsedSection {
    var title: String
    var text: String
    var page: Int?
}

enum BookParser {

    static func parse(url: URL, format: BookFormat) throws -> (title: String, sections: [ParsedSection]) {
        let baseTitle = url.deletingPathExtension().lastPathComponent
        switch format {
        case .pdf:  return try parsePDF(url: url, fallbackTitle: baseTitle)
        case .epub: return try parseEPUB(url: url, fallbackTitle: baseTitle)
        case .txt, .md: return try parsePlainText(url: url, format: format, fallbackTitle: baseTitle)
        }
    }

    // MARK: - PDF

    private static func parsePDF(url: URL, fallbackTitle: String) throws -> (String, [ParsedSection]) {
        guard let doc = PDFDocument(url: url) else {
            throw WikiError.emptyDocument(fallbackTitle)
        }
        var sections: [ParsedSection] = []
        var currentChapter = "正文"
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let heading = firstLineChapter(trimmed) { currentChapter = heading }
            sections.append(ParsedSection(title: currentChapter, text: trimmed, page: i + 1))
        }
        let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        guard !sections.isEmpty else { throw WikiError.emptyDocument(fallbackTitle) }
        return (title, sections)
    }

    // MARK: - EPUB

    private static func parseEPUB(url: URL, fallbackTitle: String) throws -> (String, [ParsedSection]) {
        let zip = try ZipReader(url: url)

        // container.xml -> OPF 路径
        var opfPath = "OEBPS/content.opf"
        if let containerData = zip.read("META-INF/container.xml"),
           let container = String(data: containerData, encoding: .utf8),
           let found = firstMatch("full-path\\s*=\\s*[\"']([^\"']+)[\"']", in: container) {
            opfPath = found
        }
        guard let opfData = zip.read(opfPath) ?? zip.read((opfPath as NSString).lastPathComponent),
              let opf = String(data: opfData, encoding: .utf8) else {
            throw WikiError.emptyDocument(fallbackTitle)
        }

        let bookTitle = firstMatch("(?is)<dc:title[^>]*>(.*?)</dc:title>", in: opf)
            .map { stripHTML($0) } ?? fallbackTitle

        // manifest: id -> href
        var manifest: [String: String] = [:]
        let itemTags = matches("(?is)<item\\b[^>]*>", in: opf)
        for tag in itemTags {
            guard let id = firstMatch("id\\s*=\\s*[\"']([^\"']+)[\"']", in: tag),
                  let href = firstMatch("href\\s*=\\s*[\"']([^\"']+)[\"']", in: tag) else { continue }
            manifest[id] = href.removingPercentEncoding ?? href
        }

        // spine: 阅读顺序
        let idrefs = matches("(?is)<itemref\\b[^>]*>", in: opf).compactMap {
            firstMatch("idref\\s*=\\s*[\"']([^\"']+)[\"']", in: $0)
        }
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        let orderedHrefs = idrefs.isEmpty ? Array(manifest.values) : idrefs.compactMap { manifest[$0] }

        var sections: [ParsedSection] = []
        for (idx, href) in orderedHrefs.enumerated() {
            let path = opfDir == "." ? href : (opfDir as NSString).appendingPathComponent(href)
            guard let data = zip.read(path) ?? zip.read(href),
                  let html = String(data: data, encoding: .utf8) else { continue }
            let plain = stripHTML(html)
            guard plain.count > 20 else { continue }
            let heading = firstMatch("(?is)<(?:title|h1|h2|h3)[^>]*>(.*?)</(?:title|h1|h2|h3)>", in: html)
                .map { stripHTML($0) }
            let title = (heading?.isEmpty == false ? heading! : "第 \(idx + 1) 节")
            sections.append(ParsedSection(title: String(title.prefix(60)), text: plain, page: nil))
        }
        guard !sections.isEmpty else { throw WikiError.emptyDocument(fallbackTitle) }
        return (bookTitle.isEmpty ? fallbackTitle : bookTitle, sections)
    }

    // MARK: - TXT / Markdown

    private static func parsePlainText(url: URL,
                                       format: BookFormat,
                                       fallbackTitle: String) throws -> (String, [ParsedSection]) {
        guard let text = readText(url: url), !text.isEmpty else {
            throw WikiError.emptyDocument(fallbackTitle)
        }
        let lines = text.components(separatedBy: .newlines)
        var sections: [ParsedSection] = []
        var currentTitle = "开篇"
        var buffer: [String] = []

        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { sections.append(ParsedSection(title: currentTitle, text: body, page: nil)) }
            buffer.removeAll()
        }

        for line in lines {
            if let heading = headingOf(line, format: format) {
                flush()
                currentTitle = String(heading.prefix(60))
            } else {
                buffer.append(line)
                // 长文没有章节时，按体量自动分段
                if buffer.joined(separator: "\n").count > 4000 {
                    flush()
                    currentTitle = "第 \(sections.count + 1) 节"
                }
            }
        }
        flush()
        guard !sections.isEmpty else { throw WikiError.emptyDocument(fallbackTitle) }
        return (fallbackTitle, sections)
    }

    private static func headingOf(_ line: String, format: BookFormat) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 80 else { return nil }
        if format == .md, trimmed.hasPrefix("#") {
            let t = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            return t.isEmpty ? nil : t
        }
        let pattern = "^\\s*(第\\s*[零〇一二三四五六七八九十百千两0-9]+\\s*[章节卷篇部回]\\s*[^\\n]{0,40}|Chapter\\s+\\d+[^\\n]{0,40}|PART\\s+[IVXLCDM0-9]+[^\\n]{0,40})\\s*$"
        return firstMatch(pattern, in: trimmed)
    }

    private static func firstLineChapter(_ pageText: String) -> String? {
        let lines = pageText.components(separatedBy: .newlines).prefix(4)
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.count < 60 else { continue }
            if let h = headingOf(t, format: .txt) { return h }
            if let h = headingOf(t, format: .md) { return h }
        }
        return nil
    }

    private static func readText(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gb18030) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - HTML / 正则工具

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            Range(m.range, in: text).map { String(text[$0]) }
        }
    }

    static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    static func stripHTML(_ html: String) -> String {
        var s = html
        let rules: [(String, String)] = [
            ("(?is)<(script|style|head)[^>]*>.*?</\\1>", " "),
            ("(?is)<br\\s*/?>", "\n"),
            ("(?is)</?(p|div|h[1-6]|li|tr|section|article|blockquote)[^>]*>", "\n"),
            ("(?s)<[^>]+>", "")
        ]
        for (p, r) in rules {
            s = s.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&#39;": "'",
            "&hellip;": "…", "&mdash;": "—", "&ndash;": "–",
            "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’"
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        // 数字实体 &#123; / &#x1F600;
        for m in matches("&#(x[0-9A-Fa-f]+|[0-9]+);", in: s) {
            let raw = String(m.dropFirst(2).dropLast(1))
            let value: UInt32? = raw.hasPrefix("x") || raw.hasPrefix("X")
                ? UInt32(String(raw.dropFirst()), radix: 16)
                : UInt32(raw)
            if let v = value, let scalar = Unicode.Scalar(v) {
                s = s.replacingOccurrences(of: m, with: String(Character(scalar)))
            }
        }
        s = s.replacingOccurrences(of: "[ \\t\\r]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
