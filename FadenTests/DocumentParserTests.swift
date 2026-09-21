import XCTest
@testable import Faden

/// Reading documents, against files a real writer produced.
///
/// The ZIP reader is the newest and least forgiving code in the app: it walks a binary
/// format by offset, and every mistake in it produces plausible-looking rubbish rather
/// than an error. So the fixtures are genuine archives rather than bytes assembled to
/// match an assumption — see `DocumentFixtures`.
final class DocumentParserTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-docs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func parse(_ name: String, _ data: Data) async throws -> ParsedDocument {
        let url = try write(name, data)
        let parsed = await DocumentParser.parse(url)
        return try XCTUnwrap(parsed, "„\(name)“ wurde nicht gelesen.")
    }

    // MARK: The ZIP container

    func testTheArchiveListsItsEntries() throws {
        let zip = try XCTUnwrap(ZipArchive(data: DocumentFixtures.docx))
        XCTAssertTrue(zip.entries.contains { $0.name == "word/document.xml" })
        XCTAssertNil(zip.entry(named: "gibt/es/nicht.xml"))
    }

    func testADeflatedEntryComesBackWhole() throws {
        let zip = try XCTUnwrap(ZipArchive(data: DocumentFixtures.docx))
        let entry = try XCTUnwrap(zip.entry(named: "word/document.xml"))
        let bytes = try XCTUnwrap(zip.contents(of: entry))
        // Bytes against bytes: `String.count` counts characters, and every umlaut in
        // this fixture is two bytes. Comparing the two would pass or fail depending on
        // how many umlauts somebody put in the test file.
        XCTAssertEqual(bytes.count, entry.uncompressedSize,
                       "Entpackt muss herauskommen, was das Verzeichnis ansagt.")
        let text = try XCTUnwrap(zip.text(of: entry))
        XCTAssertTrue(text.contains("Mietvertrag"), text)
    }

    /// An EPUB must keep its `mimetype` uncompressed. A reader that only handles
    /// deflate passes every other test and fails on every real book.
    func testAStoredEntryIsReadToo() throws {
        let zip = try XCTUnwrap(ZipArchive(data: DocumentFixtures.epub))
        let entry = try XCTUnwrap(zip.entry(named: "mimetype"))
        XCTAssertEqual(entry.method, 0, "Der Eintrag muss unkomprimiert sein.")
        XCTAssertEqual(zip.text(of: entry), "application/epub+zip")
    }

    func testSomethingThatIsNotAZipIsRefused() {
        XCTAssertNil(ZipArchive(data: Data("PK und sonst nichts".utf8)))
        XCTAssertNil(ZipArchive(data: Data()))
        XCTAssertNil(ZipArchive(data: Data(repeating: 0, count: 5_000)))
    }

    /// A small file may claim any uncompressed size it likes. The cap is what stands
    /// between that claim and the memory it names.
    func testAnAbsurdSizeClaimIsRefused() {
        XCTAssertNil(ZipArchive.inflate(Data([0x78, 0x9C]), into: ZipArchive.maxEntryBytes + 1))
        XCTAssertNil(ZipArchive.inflate(Data(), into: 0))
    }

    // MARK: Office

    func testWordGivesUpItsText() async throws {
        let document = try await parse("mietvertrag.docx", DocumentFixtures.docx)
        XCTAssertEqual(document.meta.kind, "Word")
        XCTAssertEqual(document.meta.parser, .xmlParser)
        XCTAssertTrue(document.text.contains("Mietvertrag für die Wohnung"), document.text)
        // Two runs inside one paragraph belong to one sentence.
        XCTAssertTrue(document.text.contains("Die Kaltmiete beträgt 845,00 Euro"), document.text)
    }

    /// `&amp;` has to arrive as `&`. This is the whole reason the parsing goes through
    /// `XMLParser` rather than a regular expression over the markup.
    func testEntitiesArriveDecoded() async throws {
        let document = try await parse("mietvertrag.docx", DocumentFixtures.docx)
        XCTAssertTrue(document.text.contains("drei Monate & schriftlich"), document.text)
        XCTAssertFalse(document.text.contains("&amp;"))
    }

    /// Excel keeps most cell text once in a shared table and puts an index in the cell.
    /// Skipping the table leaves a grid of numbers where the words should be.
    func testExcelResolvesItsSharedStrings() async throws {
        let document = try await parse("umsatz.xlsx", DocumentFixtures.xlsx)
        XCTAssertEqual(document.meta.kind, "Excel")
        XCTAssertTrue(document.text.contains("Monat"), document.text)
        XCTAssertTrue(document.text.contains("Januar"), document.text)
        XCTAssertTrue(document.text.contains("1234.5"), document.text)
        XCTAssertFalse(document.text.contains("\n0\n"), "Der Index darf nicht durchschlagen.")
    }

    func testExcelNamesItsSheet() async throws {
        let document = try await parse("umsatz.xlsx", DocumentFixtures.xlsx)
        XCTAssertEqual(document.blocks.first?.locator, "Blatt „Umsatz“")
        XCTAssertEqual(document.blocks.first?.kind, .sheet)
    }

    func testEachSlideIsItsOwnBlock() async throws {
        let document = try await parse("zahlen.pptx", DocumentFixtures.pptx)
        XCTAssertEqual(document.meta.kind, "PowerPoint")
        XCTAssertEqual(document.blocks.count, 2)
        XCTAssertEqual(document.blocks.map(\.locator), ["Folie 1", "Folie 2"])
        XCTAssertTrue(document.blocks[1].text.contains("Ausblick 2027"))
    }

    // MARK: EPUB and OpenDocument

    func testEachChapterIsItsOwnBlock() async throws {
        let document = try await parse("buch.epub", DocumentFixtures.epub)
        XCTAssertEqual(document.meta.kind, "EPUB")
        XCTAssertEqual(document.meta.parser, .attributedString)
        XCTAssertEqual(document.blocks.count, 2)
        XCTAssertTrue(document.blocks[0].text.contains("Es war ein kalter Morgen."))
        XCTAssertEqual(document.blocks[0].locator, "ch1.xhtml")
    }

    /// OpenDocument nests spans inside paragraphs. Depth counting is what keeps the
    /// sentence in one piece instead of three.
    func testNestedOpenDocumentTextStaysOnePiece() async throws {
        let document = try await parse("notiz.odt", DocumentFixtures.odt)
        XCTAssertEqual(document.meta.kind, "OpenDocument Text")
        XCTAssertTrue(document.text.contains("Ein Absatz mit eingebettetem Text."), document.text)
        XCTAssertTrue(document.text.contains("Überschrift"))
    }

    // MARK: Plain text and markup

    func testPlainTextIsReadWithItsKind() async throws {
        let document = try await parse("notiz.md", Data("# Titel\n\nEin Satz.".utf8))
        XCTAssertEqual(document.meta.kind, "Markdown")
        XCTAssertEqual(document.meta.parser, .plainText)
        XCTAssertTrue(document.text.contains("Ein Satz."))
    }

    func testLongTextIsSplitIntoAddressableSections() async throws {
        let paragraph = String(repeating: "Ein Satz über den Heizkessel. ", count: 40)
        let long = Array(repeating: paragraph, count: 10).joined(separator: "\n\n")
        let document = try await parse("lang.txt", Data(long.utf8))
        XCTAssertGreaterThan(document.blocks.count, 1, "Langer Text braucht Fundstellen.")
        XCTAssertEqual(document.blocks.map(\.index), Array(1...document.blocks.count))
    }

    func testRichTextIsReadByApple() async throws {
        let rtf = #"{\rtf1\ansi Die Rechnung ist bezahlt.}"#
        let document = try await parse("beleg.rtf", Data(rtf.utf8))
        XCTAssertEqual(document.meta.parser, .attributedString)
        XCTAssertTrue(document.text.contains("Die Rechnung ist bezahlt."), document.text)
    }

    // MARK: What is not read

    func testAFormatWithoutAParserIsNotClaimed() {
        XCTAssertFalse(DocumentParser.canRead("film.mov"))
        XCTAssertFalse(DocumentParser.canRead("archiv.zip"))
        XCTAssertTrue(DocumentParser.canRead("Bescheid.PDF"), "Die Endung zählt ohne Rücksicht auf Groß- und Kleinschreibung.")
        XCTAssertTrue(DocumentParser.canRead("brief.docx"))
    }

    func testAnEmptyFileYieldsNothingRatherThanABlankDocument() async throws {
        let url = try write("leer.txt", Data())
        let parsed = await DocumentParser.parse(url)
        XCTAssertNil(parsed)
    }

    /// The end-of-central-directory record sits at the end, so a truncated archive has
    /// no table of contents at all. That is the common damage — a sync that stopped
    /// halfway — and it has to be refused rather than half read.
    func testATruncatedArchiveIsRefused() async throws {
        let truncated = DocumentFixtures.docx.prefix(DocumentFixtures.docx.count - 40)
        XCTAssertNil(ZipArchive(data: Data(truncated)))

        let url = try write("halb.docx", Data(truncated))
        let parsed = await DocumentParser.parse(url)
        XCTAssertNil(parsed)
    }

    func testSomethingNamedDocxThatIsNotOneIsRefused() async throws {
        let url = try write("schwindel.docx", Data("Das ist nur Text.".utf8))
        let parsed = await DocumentParser.parse(url)
        XCTAssertNil(parsed, "Die Endung macht noch kein Word-Dokument.")
    }

    // MARK: The rendered form

    func testTheRenderedDocumentCarriesItsAddresses() async throws {
        let document = try await parse("zahlen.pptx", DocumentFixtures.pptx)
        let rendered = document.render(path: "Vortrag/zahlen.pptx")
        XCTAssertTrue(rendered.hasPrefix("Vortrag/zahlen.pptx · PowerPoint · 2 Folien"), rendered)
        XCTAssertTrue(rendered.contains("[1 · Folie 1]"), rendered)
        XCTAssertTrue(rendered.contains("[2 · Folie 2]"), rendered)
    }

    func testASingleBlockCanBeAskedFor() async throws {
        let document = try await parse("zahlen.pptx", DocumentFixtures.pptx)
        let one = try XCTUnwrap(document.render(block: 2, path: "zahlen.pptx"))
        XCTAssertTrue(one.contains("Ausblick 2027"))
        XCTAssertFalse(one.contains("Quartalszahlen"), "Nur der gefragte Abschnitt.")
        XCTAssertNil(document.render(block: 99, path: "zahlen.pptx"))
    }

    /// Whitespace a parser leaves behind is paid for by the token and carries nothing.
    func testWhitespaceIsNormalised() {
        XCTAssertEqual(ParsedDocument.normalise("Zeile  eins \n\n\n\n Zeile zwei  "),
                       "Zeile eins\n\nZeile zwei")
        XCTAssertEqual(ParsedDocument.normalise("Soft\u{00AD}hyphen"), "Softhyphen")
        XCTAssertEqual(ParsedDocument.normalise("geschütztes\u{00A0}Leerzeichen"),
                       "geschütztes Leerzeichen")
    }

    /// A parser that skips an empty page must not leave a hole in the addresses:
    /// a hole is only noticed when somebody asks for 7 and gets 8.
    func testTidyingRenumbersWithoutGaps() {
        let document = ParsedDocument(
            meta: .init(kind: "PDF", parser: .pdfKit, title: nil, units: 3),
            blocks: [.init(index: 1, locator: "S. 1", kind: .page, text: "Eins"),
                     .init(index: 2, locator: "S. 2", kind: .page, text: "   "),
                     .init(index: 3, locator: "S. 3", kind: .page, text: "Drei")])
        let tidy = document.tidied()
        XCTAssertEqual(tidy.blocks.map(\.index), [1, 2])
        XCTAssertEqual(tidy.blocks.map(\.text), ["Eins", "Drei"])
    }
}
