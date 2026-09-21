import Foundation
import Compression

/// Just enough ZIP to get at the parts of a document.
///
/// This exists because iOS ships no ZIP reader, and the formats people actually keep in
/// a folder — `.docx`, `.xlsx`, `.pptx`, `.pages`, `.numbers`, `.key`, `.epub`, `.odt`
/// — are all ZIP containers. Without these hundred lines the parser can read a PDF and
/// a text file and nothing anybody writes a document in.
///
/// Only the container is read here. What is inside goes back to Apple: iWork files
/// carry a PDF preview that PDFKit reads, an EPUB is XHTML for `NSAttributedString`,
/// Office and OpenDocument parts are XML for `XMLParser`. The decompression itself is
/// Apple's too — `COMPRESSION_ZLIB` is raw DEFLATE, which is what ZIP stores.
///
/// Read-only, one entry at a time, no writing and no streaming. A document part is a
/// few hundred kilobytes; anything that needs more than that is not a document.
struct ZipArchive {

    /// Largest entry that will be unpacked. A ZIP can claim any uncompressed size it
    /// likes, and a small file claiming four gigabytes is the oldest trick there is.
    static let maxEntryBytes = 64 * 1024 * 1024

    struct Entry {
        var name: String
        var compressedSize: Int
        var uncompressedSize: Int
        var method: UInt16
        var localHeaderOffset: Int
    }

    private let data: Data
    let entries: [Entry]

    init?(data: Data) {
        guard data.count > 22 else { return nil }
        self.data = data
        guard let directory = Self.centralDirectory(in: data) else { return nil }
        self.entries = directory
    }

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// The first entry whose name matches, in the order given. For formats that moved
    /// a part between versions — iWork's preview has lived in two places.
    func firstEntry(named candidates: [String]) -> Entry? {
        for name in candidates {
            if let found = entry(named: name) { return found }
        }
        return nil
    }

    func entries(withPrefix prefix: String, suffix: String = "") -> [Entry] {
        entries
            .filter { $0.name.hasPrefix(prefix) && $0.name.hasSuffix(suffix) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The entry's bytes, decompressed.
    func contents(of entry: Entry) -> Data? {
        guard entry.uncompressedSize <= Self.maxEntryBytes,
              let payload = compressedPayload(of: entry) else { return nil }

        switch entry.method {
        case 0:
            return payload                      // stored, as iWork keeps its preview
        case 8:
            return Self.inflate(payload, into: entry.uncompressedSize)
        default:
            // bzip2, LZMA, XZ, Zstandard. Legal in a ZIP, vanishingly rare in a
            // document, and not worth a second decompressor.
            return nil
        }
    }

    func text(of entry: Entry) -> String? {
        guard let data = contents(of: entry) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: Reading the container

    /// Walks back from the end for the end-of-central-directory record.
    ///
    /// Backwards, because the record sits at the end and may be followed by a comment
    /// of up to 64 KB. Forwards would mean finding the signature by accident inside
    /// compressed data, which happens often enough to matter.
    private static func centralDirectory(in data: Data) -> [Entry]? {
        let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let searchLimit = min(data.count, 65_557)
        var eocd: Int?
        var i = data.count - 22
        let floor = data.count - searchLimit
        while i >= max(0, floor) {
            if data[i] == eocdSignature[0], data[i + 1] == eocdSignature[1],
               data[i + 2] == eocdSignature[2], data[i + 3] == eocdSignature[3] {
                eocd = i
                break
            }
            i -= 1
        }
        guard let eocd else { return nil }

        let count = Int(data.u16(eocd + 10))
        var offset = Int(data.u32(eocd + 16))
        // ZIP64 puts 0xFFFFFFFF here and the real offset in a separate record. Reading
        // that is a second format; a document that large is not one this app will read
        // anyway, so it is refused rather than mis-parsed.
        guard offset != 0xFFFF_FFFF, offset >= 0, offset < data.count else { return nil }

        var out: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.u32(offset) == 0x0201_4B50 else { break }
            let method = data.u16(offset + 10)
            let compressed = Int(data.u32(offset + 20))
            let uncompressed = Int(data.u32(offset + 24))
            let nameLength = Int(data.u16(offset + 28))
            let extraLength = Int(data.u16(offset + 30))
            let commentLength = Int(data.u16(offset + 32))
            let local = Int(data.u32(offset + 42))

            guard offset + 46 + nameLength <= data.count else { break }
            let nameBytes = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            let name = String(data: nameBytes, encoding: .utf8)
                ?? String(data: nameBytes, encoding: .isoLatin1) ?? ""

            if !name.hasSuffix("/") {
                out.append(Entry(name: name, compressedSize: compressed,
                                 uncompressedSize: uncompressed, method: method,
                                 localHeaderOffset: local))
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
        return out.isEmpty ? nil : out
    }

    /// The bytes of the entry, found through its local header.
    ///
    /// The local header has to be read even though the central directory already has
    /// the sizes: only the local header says how long its own name and extra field are,
    /// and the data starts after them. The sizes come from the central directory all
    /// the same — a local header may carry zeros and put the truth in a data descriptor
    /// after the fact.
    private func compressedPayload(of entry: Entry) -> Data? {
        let header = entry.localHeaderOffset
        guard header >= 0, header + 30 <= data.count,
              data.u32(header) == 0x0403_4B50 else { return nil }
        let nameLength = Int(data.u16(header + 26))
        let extraLength = Int(data.u16(header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count, end >= start else { return nil }
        return data.subdata(in: start..<end)
    }

    /// Raw DEFLATE, through Apple's compression framework.
    ///
    /// The expected size comes from the central directory, so one buffer is enough and
    /// there is no streaming to get wrong. When the claim and the reality disagree the
    /// result is whatever really came out, truncated to the claim — a ZIP that lies
    /// about its sizes gets to fill a buffer it named, and no more.
    static func inflate(_ payload: Data, into expected: Int) -> Data? {
        guard expected > 0, expected <= maxEntryBytes else { return nil }
        var out = Data(count: expected)
        let written: Int = out.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source -> Int in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, expected, src, payload.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return written == expected ? out : out.prefix(written)
    }
}

// MARK: - Little-endian reads

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8)
             | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}
