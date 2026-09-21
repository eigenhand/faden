import Foundation
import PDFKit
import UIKit
import Vision

/// Turns a file into a `ParsedDocument`, using whichever Apple framework reads it.
///
/// The dispatch is by extension rather than by sniffing the bytes, and that is not
/// laziness: a synced folder names its files correctly because a person named them, and
/// the formats that matter here are distinguished by structure that a magic number does
/// not capture anyway — a `.docx` and an `.epub` are both a ZIP starting `PK`.
///
/// What each format costs is worth knowing before reading further. Text, RTF, HTML and
/// PDF-with-text are read in milliseconds. OCR is seconds per page and runs only when a
/// document has no text of its own — a scan, a photograph — because it is the
/// difference between "this file is useless" and "this file is readable", and nowhere
/// else worth the battery.
enum DocumentParser {

    /// Pages that OCR will look at. A scanned book is not going to be read to a model
    /// in one turn, and twenty pages is already half a minute of work.
    static let maxOCRPages = 20
    /// Blocks per document. A spreadsheet with four hundred sheets is a database, and
    /// indexing it whole would push everything else out of the search.
    static let maxBlocks = 500

    /// Everything that can be read at all, by extension.
    static let readableExtensions: Set<String> = [
        // Apple reads these end to end
        "pdf", "rtf", "rtfd", "html", "htm", "xhtml",
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml", "yml", "yaml",
        "log", "swift", "py", "js", "ts", "c", "h", "m", "cpp", "sh", "sql", "plist",
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp",
        // ZIP containers, opened here and parsed by Apple inside
        "docx", "xlsx", "pptx", "pages", "numbers", "key", "epub", "odt", "ods", "odp",
    ]

    static func canRead(_ name: String) -> Bool {
        readableExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Reads the file. `nil` when the format is not one of ours or nothing came out.
    ///
    /// Not `throws`: every caller wants the same thing from a failure — leave the file
    /// out of the index and move on — and a thrown error would only be turned back into
    /// that at every call site.
    static func parse(_ url: URL, name: String? = nil) async -> ParsedDocument? {
        let filename = name ?? url.lastPathComponent
        let ext = (filename as NSString).pathExtension.lowercased()

        let parsed: ParsedDocument?
        switch ext {
        case "pdf":
            parsed = pdf(url)
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp":
            parsed = image(url)
        case "rtf", "rtfd":
            parsed = attributed(url, type: .rtf, kind: "RTF")
        case "html", "htm", "xhtml":
            parsed = await html(url)
        case "docx", "xlsx", "pptx", "pages", "numbers", "key", "epub", "odt", "ods", "odp":
            parsed = await PackagedDocument.parse(url, extension: ext)
        default:
            parsed = plain(url, extension: ext)
        }

        guard var document = parsed?.tidied(), !document.isEmpty else { return nil }
        if document.blocks.count > maxBlocks {
            document.blocks = Array(document.blocks.prefix(maxBlocks))
        }
        return document
    }

    // MARK: PDF

    /// PDFKit first, Vision only if PDFKit found nothing.
    ///
    /// The order is the whole of it. A PDF that carries text gives it up exactly, with
    /// its page breaks; a scan gives up nothing at all, and `page.string` returns an
    /// empty string rather than failing. Treating the second case as "the document is
    /// empty" is what makes a folder of scanned letters look like a folder of blank
    /// files.
    static func pdf(_ url: URL) -> ParsedDocument? {
        guard let document = PDFDocument(url: url) else { return nil }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String

        var blocks: [ParsedDocument.Block] = []
        for i in 0..<document.pageCount {
            guard let text = document.page(at: i)?.string, !text.isEmpty else { continue }
            blocks.append(.init(index: i + 1, locator: "S. \(i + 1)", kind: .page, text: text))
        }

        if !blocks.isEmpty {
            return ParsedDocument(
                meta: .init(kind: "PDF", parser: .pdfKit, title: title, units: document.pageCount),
                blocks: blocks)
        }
        return scannedPDF(document, title: title)
    }

    /// A PDF without a text layer: render each page and read the picture.
    private static func scannedPDF(_ document: PDFDocument, title: String?) -> ParsedDocument? {
        var blocks: [ParsedDocument.Block] = []
        for i in 0..<min(document.pageCount, maxOCRPages) {
            guard let page = document.page(at: i),
                  let image = render(page),
                  let text = recognise(image), !text.isEmpty else { continue }
            blocks.append(.init(index: i + 1, locator: "S. \(i + 1)", kind: .page, text: text))
        }
        guard !blocks.isEmpty else { return nil }
        return ParsedDocument(
            meta: .init(kind: "PDF (gescannt)", parser: .vision, title: title,
                        units: document.pageCount),
            blocks: blocks)
    }

    /// Twice the nominal size, because OCR on a page rendered at 72 dpi reads body text
    /// as noise. Beyond twice the gain flattens and the memory does not.
    private static func render(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: cg)
        }
        return image.cgImage
    }

    // MARK: Images

    static func image(_ url: URL) -> ParsedDocument? {
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data)?.cgImage,
              let text = recognise(image), !text.isEmpty else { return nil }
        return ParsedDocument(
            meta: .init(kind: "Bild", parser: .vision, title: nil, units: nil),
            blocks: [.init(index: 1, locator: "", kind: .body, text: text)])
    }

    /// Vision's text recognition, run to completion.
    ///
    /// German first in the language list and English after it: the order is a
    /// preference, not a filter, and it decides the coin toss on words that exist in
    /// both. `usesLanguageCorrection` is what turns "Rec'hnung" into "Rechnung" — it
    /// also invents the occasional word, which is why the header of every OCR document
    /// says the text came out of a picture.
    static func recognise(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Rich text and markup

    static func attributed(_ url: URL, type: NSAttributedString.DocumentType,
                           kind: String) -> ParsedDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return attributed(data, type: type, kind: kind)
    }

    /// HTML, on the main actor, and that is a requirement rather than a precaution.
    ///
    /// Apple's HTML importer is built on WebKit and puts itself on the main queue
    /// whatever thread it was called from. Parsing runs on an actor, off the main
    /// thread, so calling it directly deadlocks — and it deadlocks on a file, which
    /// means the app hangs on the day somebody puts a web page in their folder and
    /// never before.
    @MainActor
    static func html(_ url: URL) -> ParsedDocument? {
        attributed(url, type: .html, kind: "HTML")
    }

    @MainActor
    static func html(_ data: Data, kind: String) -> ParsedDocument? {
        attributed(data, type: .html, kind: kind)
    }

    /// `NSAttributedString` does the reading, which is why `.docFormat` is not in the
    /// list of types this app handles: on iOS the reader knows plain text, RTF, RTFD
    /// and HTML, and the Office formats are macOS-only. That is the line that decides
    /// which formats had to be opened by hand in `PackagedDocument`.
    static func attributed(_ data: Data, type: NSAttributedString.DocumentType,
                           kind: String) -> ParsedDocument? {
        // On the main thread, and not because of a view: the HTML reader is built on
        // WebKit and puts itself on the main queue regardless. Called from anywhere
        // else it deadlocks rather than fails.
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: type,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let string = try? NSAttributedString(data: data, options: options,
                                                   documentAttributes: nil) else { return nil }
        let text = string.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ParsedDocument(
            meta: .init(kind: kind, parser: .attributedString, title: nil, units: nil),
            blocks: [.init(index: 1, locator: "", kind: .body, text: text)])
    }

    // MARK: Plain text

    static func plain(_ url: URL, extension ext: String) -> ParsedDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A NUL in the first kilobyte is what separates a text file from everything
        // else, without a table of formats to keep up to date.
        guard !data.prefix(1024).contains(0) else { return nil }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return ParsedDocument(
            meta: .init(kind: kindName(for: ext), parser: .plainText, title: nil, units: nil),
            blocks: sections(of: text))
    }

    /// Splits long plain text at blank lines, so a search can point at a part of it.
    ///
    /// One block for a note and many for a long document: below the threshold the
    /// subdivision would be noise, above it a hit that says "somewhere in this file" is
    /// no better than no hit.
    static func sections(of text: String, softLimit: Int = 2_000) -> [ParsedDocument.Block] {
        guard text.count > softLimit else {
            return [.init(index: 1, locator: "", kind: .body, text: text)]
        }
        var blocks: [ParsedDocument.Block] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if current.count + paragraph.count > softLimit, !current.isEmpty {
                blocks.append(.init(index: blocks.count + 1,
                                    locator: "Abschnitt \(blocks.count + 1)",
                                    kind: .section, text: current))
                current = ""
            }
            current += current.isEmpty ? paragraph : "\n\n" + paragraph
        }
        if !current.isEmpty {
            blocks.append(.init(index: blocks.count + 1,
                                locator: "Abschnitt \(blocks.count + 1)",
                                kind: .section, text: current))
        }
        return blocks
    }

    static func kindName(for ext: String) -> String {
        switch ext {
        case "md", "markdown":      return "Markdown"
        case "csv", "tsv":          return "Tabelle (Text)"
        case "json":                return "JSON"
        case "xml", "plist":        return "XML"
        case "yml", "yaml":         return "YAML"
        case "log":                 return "Protokoll"
        case "txt", "text", "":     return "Text"
        default:                    return "Quelltext (.\(ext))"
        }
    }
}
