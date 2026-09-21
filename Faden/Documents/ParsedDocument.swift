import Foundation

/// A document after parsing: metadata, and the text as addressable blocks.
///
/// Blocks rather than one string, and that is the whole point of this type. A model
/// that searches a folder gets back a hit, and a hit is only useful if it can be
/// pointed at — "page 3 of the tax assessment" is an answer, "somewhere in the tax
/// assessment" is not. So the text carries its position from the moment it is parsed,
/// and the position survives into the database, the search result and the answer.
///
/// The block boundaries come from the format, not from a guess at paragraphs: a page
/// in a PDF, a sheet in a spreadsheet, a slide in a deck, a heading-led section in a
/// text document. Where a format has no such structure the whole thing is one block,
/// which is honest rather than a made-up subdivision.
struct ParsedDocument: Equatable {
    var meta: Meta
    var blocks: [Block]

    struct Block: Equatable {
        /// Stable within the document, starting at 1. This is the address the model
        /// gets back and passes in again.
        var index: Int
        /// Where this stands, in the document's own terms: "S. 3", "Blatt „Umsatz"",
        /// "Folie 4". Empty when the format has no positions to speak of.
        var locator: String
        var kind: Kind
        var text: String

        enum Kind: String, Equatable {
            case page, sheet, slide, section, body
        }
    }

    struct Meta: Equatable {
        /// What the file is, in a word: "PDF", "Word", "Tabelle", "Bild".
        var kind: String
        /// Which Apple framework read it. Kept because it decides how far the text can
        /// be trusted: PDFKit reads what the document says, Vision reads what a
        /// photograph of a page looks like, and those are not the same claim.
        var parser: Parser
        /// The document's own title, when it carries one.
        var title: String?
        /// Pages, sheets, slides — whatever the unit is. `nil` when there is none.
        var units: Int?

        enum Parser: String, Equatable {
            case pdfKit = "PDFKit"
            case attributedString = "NSAttributedString"
            case vision = "Vision (OCR)"
            case xmlParser = "XMLParser"
            case plainText = "Text"
        }
    }

    var text: String { blocks.map(\.text).joined(separator: "\n\n") }
    var isEmpty: Bool { blocks.allSatisfy { $0.text.isEmpty } }

    /// Everything after the parse: blank blocks out, whitespace normalised, addresses
    /// renumbered without gaps.
    ///
    /// Renumbering last matters. A parser that skips an empty page would otherwise
    /// leave a hole in the addresses, and a hole is the kind of thing that is only
    /// noticed when somebody asks for block 7 and gets block 8.
    func tidied() -> ParsedDocument {
        var out = self
        out.blocks = blocks
            .map { block in
                var b = block
                b.text = ParsedDocument.normalise(b.text)
                return b
            }
            .filter { !$0.text.isEmpty }
        for i in out.blocks.indices { out.blocks[i].index = i + 1 }
        return out
    }

    /// Collapses the whitespace a document parser leaves behind.
    ///
    /// Every one of these has a source. PDFKit hands back hard line breaks at the
    /// width of the page, so a sentence arrives in four pieces; `NSAttributedString`
    /// turns an HTML table into runs of tabs; OCR produces trailing spaces on every
    /// line. None of it carries meaning, and all of it is paid for by the token.
    static func normalise(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // Soft hyphen and the zero-width family: invisible, and they split words
            // for a search that goes looking for them.
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "[\u{200B}\u{200C}\u{200D}\u{FEFF}]",
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        s = s.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Rendering

extension ParsedDocument {

    /// The document as the model receives it.
    ///
    /// One header line saying what this is and how it was read, then one block per
    /// line prefixed with its address. The address is the part that earns its
    /// characters: it lets an answer cite a page, and it lets a second call ask for
    /// that block alone instead of the document again.
    func render(path: String, limit: Int = 12_000) -> String {
        var out = header(path: path)
        var budget = limit
        var written = 0

        for block in blocks {
            let prefix = block.locator.isEmpty ? "[\(block.index)] "
                                               : "[\(block.index) · \(block.locator)] "
            let piece = prefix + block.text
            guard piece.count <= budget else { break }
            out += "\n" + piece
            budget -= piece.count + 1
            written += 1
        }

        if written < blocks.count {
            out += "\n\n[… \(blocks.count - written) weitere Abschnitte. Frag nach einer "
                + "Nummer oder such gezielt im Inhalt.]"
        }
        return out
    }

    /// A single block, for the second call that asks for one.
    func render(block index: Int, path: String) -> String? {
        guard let block = blocks.first(where: { $0.index == index }) else { return nil }
        let where_ = block.locator.isEmpty ? "Abschnitt \(block.index)"
                                           : "\(block.locator), Abschnitt \(block.index)"
        return "\(path) · \(where_)\n\n\(block.text)"
    }

    private func header(path: String) -> String {
        var parts = [meta.kind]
        if let units = meta.units, units > 1 { parts.append("\(units) \(unitWord())") }
        parts.append("gelesen mit \(meta.parser.rawValue)")
        var line = "\(path) · " + parts.joined(separator: " · ")
        if let title = meta.title, !title.isEmpty,
           title != (path as NSString).lastPathComponent {
            line += "\nTitel: \(title)"
        }
        // Said once, at the top, because it changes how every line below should be
        // read: OCR is a reading of a picture, not of a document.
        if meta.parser == .vision {
            line += "\nDer Text wurde aus einem Bild erkannt und kann Lesefehler enthalten."
        }
        return line
    }

    private func unitWord() -> String {
        switch blocks.first?.kind {
        case .page:  return "Seiten"
        case .sheet: return "Blätter"
        case .slide: return "Folien"
        default:     return "Abschnitte"
        }
    }
}
