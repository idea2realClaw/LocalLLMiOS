import Foundation

/// 极简 ZIP 读取器（EPUB 用）。支持 stored(0) 与 raw deflate(8)，
/// 通过系统 zlib 解压，不引入任何第三方依赖。
struct ZipEntry {
    let name: String
    let method: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let dataOffset: Int
}

final class ZipReader {
    private let bytes: [UInt8]
    private(set) var entries: [ZipEntry] = []

    private func u16(_ at: Int) -> UInt16 {
        guard at + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
    }

    private func u32(_ at: Int) -> UInt32 {
        guard at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8)
             | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw WikiError.emptyDocument(url.lastPathComponent) }

        // 1. 从尾部找 EOCD (0x06054b50)
        var eocd = -1
        let lowest = max(0, bytes.count - 65_557)
        var i = bytes.count - 22
        while i >= lowest {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw WikiError.unsupportedFormat("epub（不是合法 ZIP）") }

        let count = Int(u16(eocd + 10))
        var cursor = Int(u32(eocd + 16))
        var parsed: [ZipEntry] = []
        parsed.reserveCapacity(count)

        // 2. 遍历 Central Directory
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, u32(cursor) == 0x02014b50 else { break }
            let method = u16(cursor + 10)
            let compressedSize = Int(u32(cursor + 20))
            let uncompressedSize = Int(u32(cursor + 24))
            let nameLen = Int(u16(cursor + 28))
            let extraLen = Int(u16(cursor + 30))
            let commentLen = Int(u16(cursor + 32))
            let localOffset = Int(u32(cursor + 42))

            guard cursor + 46 + nameLen <= bytes.count else { break }
            let nameData = bytes[(cursor + 46)..<(cursor + 46 + nameLen)]
            let name = String(decoding: nameData, as: UTF8.self)

            // 3. Local header 里 name/extra 长度可能不同，数据起点以它为准
            var dataOffset = localOffset + 30 + nameLen + extraLen
            if localOffset + 30 <= bytes.count, u32(localOffset) == 0x04034b50 {
                let ln = Int(u16(localOffset + 26))
                let le = Int(u16(localOffset + 28))
                dataOffset = localOffset + 30 + ln + le
            }
            parsed.append(ZipEntry(name: name,
                                   method: method,
                                   compressedSize: compressedSize,
                                   uncompressedSize: uncompressedSize,
                                   dataOffset: dataOffset))
            cursor += 46 + nameLen + extraLen + commentLen
        }
        self.entries = parsed
    }

    func hasEntry(_ name: String) -> Bool {
        entries.contains { $0.name == name }
    }

    /// 按文件名读取内容；支持大小写与路径前缀容错。
    func read(_ name: String) -> Data? {
        let entry = entries.first { $0.name == name }
            ?? entries.first { ($0.name as NSString).lastPathComponent == (name as NSString).lastPathComponent }
        guard let e = entry else { return nil }
        guard e.dataOffset + e.compressedSize <= bytes.count else { return nil }
        let raw = Data(bytes[(e.dataOffset)..<(e.dataOffset + e.compressedSize)])
        switch e.method {
        case 0: return raw
        case 8: return Self.inflateRaw(raw, expected: e.uncompressedSize)
        default: return nil
        }
    }

    /// ZIP 里是 raw deflate（无 zlib 头），必须用 inflateInit2_(-MAX_WBITS)。
    private static func inflateRaw(_ src: Data, expected: Int) -> Data? {
        guard expected > 0, !src.isEmpty else { return Data() }
        var output = [UInt8](repeating: 0, count: expected)
        let status: Int32 = src.withUnsafeBytes { (rawIn: UnsafeRawBufferPointer) -> Int32 in
            output.withUnsafeMutableBytes { (rawOut: UnsafeMutableRawBufferPointer) -> Int32 in
                guard let inBase = rawIn.baseAddress, let outBase = rawOut.baseAddress else {
                    return Z_DATA_ERROR
                }
                var stream = z_stream()
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inBase.assumingMemoryBound(to: Bytef.self))
                stream.avail_in = uInt(src.count)
                stream.next_out = outBase.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(expected)
                let version = zlibVersion()
                guard inflateInit2_(&stream, -MAX_WBITS, version,
                                    Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    return Z_DATA_ERROR
                }
                let r = inflate(&stream, Z_FINISH)
                inflateEnd(&stream)
                return r
            }
        }
        return status == Z_STREAM_END ? Data(output) : nil
    }
}
