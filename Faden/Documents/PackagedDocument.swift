import Foundation
import PDFKit

/// The formats that are a ZIP with documents inside.
///
/// `ZipArchive` opens the container; from there everything is Apple again. Which part
/// to reach for is the only knowledge that lives here, and it is the kind that is
/// written down once and then forgotten: Word keeps its text in `word/document.xml`,
/// Keynote keeps a PDF preview under `QuickLook`, EPUB is a folder of XHTML.
enum PackagedDocument {

    static func parse(_ url: URL, extension ext: String) async -> ParsedDocument? {
        guard let zip = ZipArchive(url: url) else { return nil }
        switch ext {
        case "docx":                  return word(zip)
        case "xlsx":                  return excel(zip)
        case "pptx":                  return powerPoint(zip)
        case "pages", "numbers", "key": return iWork(zip, extension: ext)
        case "epub":                  return await epub(zip)
        case "odt", "ods", "odp":     return openDocument(zip, extension: ext)
        default:                      return nil
        }
    }

    // MARK: Office Open XML

    private static func word(_ zip: ZipArchive) -> ParsedDocument? {
        guard let entry = zip.entry(named: "word/document.xml"),
              let data = zip.contents(of: entry) else { return nil }
        let text = XMLText.extract(data, text: ["w:t"],
                                   breaks: ["w:p", "w:br", "w:tr"], tabs: ["w:tab"])
        guard !text.isEmpty else { return nil }
        return ParsedDocument(
            meta: .init(kind: "Word", parser: .xmlParser, title: nil, units: nil),
            blocks: DocumentParser.sections(of: text))
    }

    /// One block per sheet, rows as tab-separated lines.
    ///
    /// The shared string table is the part that has to be read first and the part that
    /// makes a spreadsheet unreadable when it is skipped: Excel stores most cell text
    /// once in `sharedStrings.xml` and puts an index in the cell, so a sheet read on its
    /// own is a grid of numbers where the words should be.
    private static func excel(_ zip: ZipArchive) -> ParsedDocument? {
        let shared: [String] = zip.entry(named: "xl/sharedStrings.xml")
            .flatMap { zip.contents(of: $0) }
            .map { XMLText.sharedStrings($0) } ?? []
        let names = zip.entry(named: "xl/workbook.xml")
            .flatMap { zip.contents(of: $0) }
            .map { XMLText.sheetNames($0) } ?? []

        var blocks: [ParsedDocument.Block] = []
        for (i, entry) in zip.entries(withPrefix: "xl/worksheets/sheet", suffix: ".xml").enumerated() {
            guard let data = zip.contents(of: entry) else { continue }
            let rows = XMLText.sheetRows(data, shared: shared)
            guard !rows.isEmpty else { continue }
            let name = i < names.count ? names[i] : "Blatt \(i + 1)"
            blocks.append(.init(index: blocks.count + 1, locator: "Blatt „\(name)“",
                                kind: .sheet, text: rows.joined(separator: "\n")))
        }
        guard !blocks.isEmpty else { return nil }
        return ParsedDocument(
            meta: .init(kind: "Excel", parser: .xmlParser, title: nil, units: blocks.count),
            blocks: blocks)
    }

    private static func powerPoint(_ zip: ZipArchive) -> ParsedDocument? {
        var blocks: [ParsedDocument.Block] = []
        for entry in zip.entries(withPrefix: "ppt/slides/slide", suffix: ".xml") {
            guard let data = zip.contents(of: entry) else { continue }
            let text = XMLText.extract(data, text: ["a:t"], breaks: ["a:p", "a:br"], tabs: [])
            guard !text.isEmpty else { continue }
            blocks.append(.init(index: blocks.count + 1,
                                locator: "Folie \(blocks.count + 1)",
                                kind: .slide, text: text))
        }
        guard !blocks.isEmpty else { return nil }
        return ParsedDocument(
            meta: .init(kind: "PowerPoint", parser: .xmlParser, title: nil, units: blocks.count),
            blocks: blocks)
    }

    // MARK: iWork

    /// Pages, Numbers and Keynote through the PDF preview they carry.
    ///
    /// Their real format is an undocumented protobuf archive, and no Apple API on iOS
    /// opens it. What they do carry is a rendered preview, which PDFKit reads exactly —
    /// so the text comes out as it was laid out, which for a Keynote deck is closer to
    /// what somebody means by "what does it say" than the source would be.
    ///
    /// The preview is optional: iWork writes it unless the user turned it off in the
    /// save dialog. When it is missing the file is unreadable, and that is said plainly
    /// rather than papered over.
    private static func iWork(_ zip: ZipArchive, extension ext: String) -> ParsedDocument? {
        guard let entry = zip.firstEntry(named: ["QuickLook/Preview.pdf", "preview.pdf",
                                                 "Preview.pdf", "QuickLook/Thumbnail.pdf"]),
              let data = zip.contents(of: entry),
              let pdf = PDFDocument(data: data) else { return nil }

        var blocks: [ParsedDocument.Block] = []
        for i in 0..<pdf.pageCount {
            guard let text = pdf.page(at: i)?.string, !text.isEmpty else { continue }
            blocks.append(.init(index: blocks.count + 1, locator: unit(ext, i + 1),
                                kind: ext == "key" ? .slide : .page, text: text))
        }
        guard !blocks.isEmpty else { return nil }
        return ParsedDocument(
            meta: .init(kind: kindName(ext), parser: .pdfKit, title: nil, units: pdf.pageCount),
            blocks: blocks)
    }

    private static func unit(_ ext: String, _ n: Int) -> String {
        ext == "key" ? "Folie \(n)" : "S. \(n)"
    }

    private static func kindName(_ ext: String) -> String {
        switch ext {
        case "pages":   return "Pages"
        case "numbers": return "Numbers"
        case "key":     return "Keynote"
        case "odt":     return "OpenDocument Text"
        case "ods":     return "OpenDocument Tabelle"
        case "odp":     return "OpenDocument Präsentation"
        default:        return ext.uppercased()
        }
    }

    // MARK: EPUB

    /// One block per chapter file, in the order the book names them.
    ///
    /// Sorted by name rather than read out of the spine in `content.opf`. The spine is
    /// the correct source and this is not it — but a book whose files are not in
    /// reading order is rarer than a book with no spine this code could find, and the
    /// blocks carry their file name, so a wrong order is visible rather than silent.
    private static func epub(_ zip: ZipArchive) async -> ParsedDocument? {
        let chapters = zip.entries.filter {
            let name = $0.name.lowercased()
            return (name.hasSuffix(".xhtml") || name.hasSuffix(".html") || name.hasSuffix(".htm"))
                && !name.contains("nav") && !name.contains("toc")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var blocks: [ParsedDocument.Block] = []
        for entry in chapters.prefix(DocumentParser.maxBlocks) {
            guard let data = zip.contents(of: entry),
                  let parsed = await DocumentParser.html(data, kind: "EPUB"),
                  let text = parsed.blocks.first?.text, !text.isEmpty else { continue }
            let name = (entry.name as NSString).lastPathComponent
            blocks.append(.init(index: blocks.count + 1, locator: name,
                                kind: .section, text: text))
        }
        guard !blocks.isEmpty else { return nil }
        return ParsedDocument(
            meta: .init(kind: "EPUB", parser: .attributedString, title: nil, units: blocks.count),
            blocks: blocks)
    }

    // MARK: OpenDocument

    private static func openDocument(_ zip: ZipArchive, extension ext: String) -> ParsedDocument? {
        guard let entry = zip.entry(named: "content.xml"),
              let data = zip.contents(of: entry) else { return nil }
        let text = XMLText.extract(
            data,
            text: ["text:p", "text:h", "text:span", "text:a"],
            breaks: ["text:p", "text:h", "table:table-row"],
            tabs: ["table:table-cell"])
        guard !text.isEmpty else { return nil }
        return ParsedDocument(
            meta: .init(kind: kindName(ext), parser: .xmlParser, title: nil, units: nil),
            blocks: DocumentParser.sections(of: text))
    }
}

// MARK: - Pulling text out of XML

/// `XMLParser` with a delegate that knows which elements carry text.
///
/// Apple's parser rather than a regular expression over the markup, and the difference
/// shows on the first real file: entities (`&amp;`, `&#228;`) arrive decoded, CDATA is
/// handled, and an attribute containing a `>` does not end an element. Every one of
/// those turns into wrong text rather than an error.
enum XMLText {

    /// - Parameters:
    ///   - text: elements whose characters are content.
    ///   - breaks: elements that end a line when they close.
    ///   - tabs: elements that separate with a tab — table cells.
    ///
    /// Nesting needs no flag: the collector counts depth, so an OpenDocument paragraph
    /// with spans and links inside it accumulates into one piece and flushes when the
    /// outermost text element closes.
    static func extract(_ data: Data, text: Set<String>, breaks: Set<String>,
                        tabs: Set<String>) -> String {
        let collector = Collector(text: text, breaks: breaks, tabs: tabs)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return ParsedDocument.normalise(collector.out)
    }

    /// Excel's shared string table, in order — the cells refer to it by position.
    static func sharedStrings(_ data: Data) -> [String] {
        let collector = Collector(text: ["t"], breaks: ["si"], tabs: [], splitOn: "si")
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        // Trimmed, because the `si` break leaves a newline on every entry and these
        // are substituted into cells, not printed as lines.
        return collector.pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func sheetNames(_ data: Data) -> [String] {
        let collector = Collector(text: [], breaks: [], tabs: [], attribute: ("sheet", "name"))
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.pieces
    }

    /// Rows of a worksheet, cells separated by tabs.
    static func sheetRows(_ data: Data, shared: [String]) -> [String] {
        let collector = Collector(text: ["v", "t"], breaks: ["row"], tabs: ["c"],
                                  splitOn: "row", shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.pieces
            .map { ParsedDocument.normalise($0.replacingOccurrences(of: "\n", with: "\t")) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private final class Collector: NSObject, XMLParserDelegate {
        private let textElements: Set<String>
        private let breakElements: Set<String>
        private let tabElements: Set<String>
        private let splitElement: String?
        /// Excel only: a cell marked `t="s"` holds an index into this.
        private let shared: [String]
        /// For `sheetNames`: collect an attribute instead of characters.
        private let attribute: (element: String, name: String)?

        private var depthInText = 0
        private var buffer = ""
        /// Whether the cell currently open refers to the shared string table.
        private var cellIsShared = false

        private(set) var out = ""
        private(set) var pieces: [String] = []

        init(text: Set<String>, breaks: Set<String>, tabs: Set<String>,
             splitOn: String? = nil, shared: [String] = [],
             attribute: (String, String)? = nil) {
            self.textElements = text
            self.breakElements = breaks
            self.tabElements = tabs
            self.splitElement = splitOn
            self.shared = shared
            self.attribute = attribute
        }

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            let name = qualifiedName ?? element
            if let attribute, name == attribute.element,
               let value = attributes[attribute.name] {
                pieces.append(value)
            }
            if name == "c" { cellIsShared = attributes["t"] == "s" }
            if textElements.contains(name) { depthInText += 1 }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard depthInText > 0 else { return }
            buffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard depthInText > 0, let s = String(data: CDATABlock, encoding: .utf8) else { return }
            buffer += s
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let name = qualifiedName ?? element

            if textElements.contains(name) {
                depthInText = max(0, depthInText - 1)
                if depthInText == 0 {
                    // A shared-string cell holds the index, not the text.
                    if cellIsShared, !shared.isEmpty,
                       let i = Int(buffer.trimmingCharacters(in: .whitespaces)),
                       shared.indices.contains(i) {
                        out += shared[i]
                    } else {
                        out += buffer
                    }
                    buffer = ""
                }
            }
            if tabElements.contains(name) { out += "\t" }
            if breakElements.contains(name) { out += "\n" }
            if let splitElement, name == splitElement {
                pieces.append(out)
                out = ""
            }
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            if splitElement != nil, !out.isEmpty {
                pieces.append(out)
                out = ""
            }
        }
    }
}
