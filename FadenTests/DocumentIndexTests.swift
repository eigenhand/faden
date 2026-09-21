import XCTest
@testable import Faden

/// The index the parsed documents live in.
///
/// Two things are checked that nothing else would catch. First, that FTS5 is really in
/// the system SQLite — the whole search rests on it, and a build without it would
/// answer every question with "nothing found" and never fail. Second, that a changed
/// file replaces what was stored rather than adding to it: a document that gets shorter
/// would otherwise keep answering from the paragraphs it no longer contains.
final class DocumentIndexTests: XCTestCase {

    private var url: URL!
    private var index: DocumentIndex!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-index-\(UUID().uuidString).sqlite")
        index = DocumentIndex(url: url)
    }

    override func tearDownWithError() throws {
        index = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + suffix))
        }
    }

    private func document(_ blocks: [(String, String)],
                          kind: String = "PDF",
                          parser: ParsedDocument.Meta.Parser = .pdfKit) -> ParsedDocument {
        ParsedDocument(
            meta: .init(kind: kind, parser: parser, title: "Bescheid", units: blocks.count),
            blocks: blocks.enumerated().map { i, b in
                .init(index: i + 1, locator: b.0, kind: .page, text: b.1)
            })
    }

    private let stamp = DocumentIndex.Stamp(modified: Date(timeIntervalSince1970: 1_700_000_000),
                                            size: 4096)

    // MARK: The foundation

    /// If this fails, nothing else in the feature works and everything still looks fine.
    func testFTS5IsAvailableInTheSystemSQLite() async {
        let usable = await index.isUsable
        XCTAssertTrue(usable, "Ohne FTS5 gibt es keine Volltextsuche.")
    }

    // MARK: Freshness

    func testAnUnknownFileIsNeverFresh() async {
        let fresh = await index.isFresh("Steuer/x.pdf", stamp)
        XCTAssertFalse(fresh)
    }

    func testWhatWasStoredCountsAsFresh() async {
        await index.store(document([("S. 1", "Hallo")]), at: "a.pdf", stamp: stamp)
        let fresh = await index.isFresh("a.pdf", stamp)
        XCTAssertTrue(fresh)
    }

    func testANewModificationDateMakesItStale() async {
        await index.store(document([("S. 1", "Hallo")]), at: "a.pdf", stamp: stamp)
        let later = DocumentIndex.Stamp(modified: stamp.modified.addingTimeInterval(60),
                                        size: stamp.size)
        let fresh = await index.isFresh("a.pdf", later)
        XCTAssertFalse(fresh)
    }

    /// The date alone is what everybody uses and it is not enough: a file synced back
    /// from a server can arrive carrying a date it already had.
    func testADifferentSizeMakesItStaleEvenAtTheSameDate() async {
        await index.store(document([("S. 1", "Hallo")]), at: "a.pdf", stamp: stamp)
        let resized = DocumentIndex.Stamp(modified: stamp.modified, size: stamp.size + 1)
        let fresh = await index.isFresh("a.pdf", resized)
        XCTAssertFalse(fresh)
    }

    /// File systems and providers round differently; microseconds are not a change.
    func testASubSecondDifferenceIsNotAChange() async {
        await index.store(document([("S. 1", "Hallo")]), at: "a.pdf", stamp: stamp)
        let jittered = DocumentIndex.Stamp(modified: stamp.modified.addingTimeInterval(0.4),
                                           size: stamp.size)
        let fresh = await index.isFresh("a.pdf", jittered)
        XCTAssertTrue(fresh)
    }

    // MARK: Replacing

    /// The failure this guards is quiet: a shorter second version leaves the extra
    /// paragraphs of the first behind, and they keep turning up in searches attached to
    /// a file that no longer says any such thing.
    func testAShorterVersionLeavesNothingBehind() async {
        await index.store(document([("S. 1", "Erste Seite"), ("S. 2", "Zweite Seite"),
                                    ("S. 3", "Dritte Seite")]), at: "a.pdf", stamp: stamp)
        var blocks = await index.summary().blocks
        XCTAssertEqual(blocks, 3)

        await index.store(document([("S. 1", "Erste Seite")]), at: "a.pdf", stamp: stamp)
        blocks = await index.summary().blocks
        XCTAssertEqual(blocks, 1)

        let stale = await index.search("Dritte")
        XCTAssertTrue(stale.isEmpty, "Die alte dritte Seite darf nicht mehr gefunden werden.")
    }

    func testTwoDocumentsDoNotOverwriteEachOther() async {
        await index.store(document([("S. 1", "Apfel")]), at: "a.pdf", stamp: stamp)
        await index.store(document([("S. 1", "Birne")]), at: "b.pdf", stamp: stamp)
        let summary = await index.summary()
        XCTAssertEqual(summary.documents, 2)
        XCTAssertEqual(summary.blocks, 2)
    }

    // MARK: Reading back

    func testADocumentComesBackAsItWentIn() async throws {
        let original = document([("S. 1", "Erste Seite"), ("S. 2", "Zweite Seite")])
        await index.store(original, at: "a.pdf", stamp: stamp)

        let fetched = await index.document(at: "a.pdf")
        let back = try XCTUnwrap(fetched)
        XCTAssertEqual(back.meta.kind, "PDF")
        XCTAssertEqual(back.meta.parser, .pdfKit)
        XCTAssertEqual(back.meta.title, "Bescheid")
        XCTAssertEqual(back.blocks.map(\.text), ["Erste Seite", "Zweite Seite"])
        XCTAssertEqual(back.blocks.map(\.locator), ["S. 1", "S. 2"])
        XCTAssertEqual(back.blocks.map(\.index), [1, 2])
    }

    /// Ten blocks means index 10 sorts after index 9, not between 1 and 2. The column
    /// is untyped in an FTS5 table, so the ordering has to say what it means.
    func testBlocksComeBackInNumericOrder() async throws {
        let many = (1...12).map { ("S. \($0)", "Seite \($0)") }
        await index.store(document(many), at: "a.pdf", stamp: stamp)
        let fetched = await index.document(at: "a.pdf")
        let back = try XCTUnwrap(fetched)
        XCTAssertEqual(back.blocks.map(\.index), Array(1...12))
    }

    // MARK: Searching

    func testSearchFindsTheBlockAndSaysWhere() async throws {
        await index.store(document([("S. 1", "Festsetzung Einkommensteuer"),
                                    ("S. 2", "Erstattung 412,80 Euro")]),
                          at: "Steuer/bescheid.pdf", stamp: stamp)

        let hits = await index.search("Erstattung")
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.path, "Steuer/bescheid.pdf")
        XCTAssertEqual(hit.block, 2)
        XCTAssertEqual(hit.locator, "S. 2")
        XCTAssertTrue(hit.snippet.contains("Erstattung"), hit.snippet)
    }

    func testSearchIgnoresCapitalsAndUmlauts() async {
        await index.store(document([("S. 1", "Grüne Tonne am Löschteich")]),
                          at: "a.pdf", stamp: stamp)
        let lower = await index.search("grune")
        XCTAssertEqual(lower.count, 1, "„grune“ muss „Grüne“ finden.")
        let upper = await index.search("LÖSCHTEICH")
        XCTAssertEqual(upper.count, 1)
    }

    func testEveryWordHasToAppear() async {
        await index.store(document([("S. 1", "Rechnung Stadtwerke")]), at: "a.pdf", stamp: stamp)
        await index.store(document([("S. 1", "Rechnung Tischlerei")]), at: "b.pdf", stamp: stamp)
        let both = await index.search("rechnung stadtwerke")
        XCTAssertEqual(both.map(\.path), ["a.pdf"])
    }

    /// FTS5 compares whole tokens, so without prefix matching "Mietvertrag" misses
    /// "Mietvertrags" and "Rechnung" misses "Rechnungen". In a language that inflects
    /// and compounds like German, exact matching turns most honest questions into
    /// "nothing found".
    func testTheSearchReachesInflectionsAndCompounds() async {
        await index.store(document([("S. 1", "Grundsteuerbescheid für 2025")]),
                          at: "a.pdf", stamp: stamp)
        await index.store(document([("S. 1", "Zwei Rechnungen der Tischlerei")]),
                          at: "b.pdf", stamp: stamp)

        let compound = await index.search("grundsteuer")
        XCTAssertEqual(compound.map(\.path), ["a.pdf"], "Das Kompositum muss gefunden werden.")
        let inflected = await index.search("Rechnung")
        XCTAssertEqual(inflected.map(\.path), ["b.pdf"], "Die Mehrzahl muss gefunden werden.")
        let explicit = await index.search("grundsteuer*")
        XCTAssertEqual(explicit.count, 1, "Ein getipptes * ändert nichts mehr.")
    }

    /// A single letter as a prefix matches a quarter of the document. Those come from
    /// splitting — the "s" out of "Müller's" — and are dropped rather than searched.
    func testSingleLetterFragmentsAreDropped() {
        XCTAssertEqual(DocumentIndex.matchExpression(for: "Müller's Rechnung"),
                       "\"Müller\"* \"Rechnung\"*")
        XCTAssertNil(DocumentIndex.matchExpression(for: "a b c"))
    }

    /// FTS5's MATCH takes a query language. An apostrophe, a hyphen or a bare `AND`
    /// is a syntax error rather than a search, and a syntax error here means an empty
    /// answer to a question that had an answer.
    func testPunctuationAndOperatorsDoNotBreakTheSearch() async {
        await index.store(document([("S. 1", "Müllers Rechnung AND Co OR Partner")]),
                          at: "a.pdf", stamp: stamp)
        for query in ["Müllers", "Müller's Rechnung", "AND", "OR Partner",
                      "rechnung -- co", "NEAR(x)", "\"quote"] {
            _ = await index.search(query)   // darf nicht abstürzen
        }
        let hits = await index.search("Müller's Rechnung")
        XCTAssertEqual(hits.count, 1, "Der Apostroph darf die Suche nicht kippen.")
        let operators = await index.search("AND OR")
        XCTAssertEqual(operators.count, 1, "Operatoren sind hier gewöhnliche Wörter.")
    }

    func testAnEmptyQueryFindsNothingRatherThanEverything() async {
        await index.store(document([("S. 1", "Irgendwas")]), at: "a.pdf", stamp: stamp)
        let hits = await index.search("   ")
        XCTAssertTrue(hits.isEmpty)
        XCTAssertNil(DocumentIndex.matchExpression(for: "*"))
    }

    // MARK: Housekeeping

    func testForgettingRemovesBothHalves() async {
        await index.store(document([("S. 1", "Hallo")]), at: "a.pdf", stamp: stamp)
        await index.forget("a.pdf")
        let summary = await index.summary()
        XCTAssertEqual(summary.documents, 0)
        XCTAssertEqual(summary.blocks, 0)
        let doc = await index.document(at: "a.pdf")
        XCTAssertNil(doc)
    }

    /// Paths are relative to a folder. After the user picks a different one they name
    /// files that are not there, and a hit on one of those is worse than no hit.
    func testClearingEmptiesEverything() async {
        await index.store(document([("S. 1", "Hallo")]), at: "a.pdf", stamp: stamp)
        await index.store(document([("S. 1", "Welt")]), at: "b.pdf", stamp: stamp)
        await index.clear()
        let summary = await index.summary()
        XCTAssertEqual(summary, .init(documents: 0, blocks: 0))
    }

    func testPruningDropsWhatIsNoLongerInTheFolder() async {
        await index.store(document([("S. 1", "Hallo")]), at: "a.pdf", stamp: stamp)
        await index.store(document([("S. 1", "Welt")]), at: "b.pdf", stamp: stamp)
        await index.prune(keeping: ["a.pdf"])
        let summary = await index.summary()
        XCTAssertEqual(summary.documents, 1)
        let gone = await index.document(at: "b.pdf")
        XCTAssertNil(gone)
    }
}
