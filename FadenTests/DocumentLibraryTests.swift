import XCTest
@testable import Faden

/// Reading a folder on demand, and saying how far along it is.
///
/// The progress is not decoration. Reading a folder from cold is minutes, and a
/// spinner that says nothing for minutes is indistinguishable from a hang — so what is
/// checked here is that the numbers arrive, that they only ever go forwards, and that
/// the last one says the work is done.
final class DocumentLibraryTests: XCTestCase {

    private var root: URL!
    private var dbURL: URL!
    private var library: DocumentLibrary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dbURL = root.appendingPathComponent("index.sqlite")
        library = DocumentLibrary(index: DocumentIndex(url: dbURL))
    }

    override func tearDownWithError() throws {
        library = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func put(_ relative: String, _ data: Data) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func putText(_ relative: String, _ text: String) throws {
        try put(relative, Data(text.utf8))
    }

    /// Collects what the progress callback reported, in order.
    private actor Reported {
        private(set) var steps: [(Int, Int)] = []
        func note(_ done: Int, _ total: Int) { steps.append((done, total)) }
    }

    // MARK: Progress

    func testProgressArrivesAndEndsAtTheTotal() async throws {
        try putText("a.txt", "Erstes Dokument über den Heizkessel.")
        try putText("b.md", "# Zweites\n\nNoch ein Dokument.")
        try put("c.docx", DocumentFixtures.docx)

        let reported = Reported()
        let progress = await library.index(root: root) { done, total in
            await reported.note(done, total)
        }
        let steps = await reported.steps

        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.parsed, 3)
        XCTAssertFalse(steps.isEmpty, "Ohne Meldungen gäbe es keinen Balken.")
        XCTAssertEqual(steps.last?.0, 3, "Die letzte Meldung sagt: fertig.")
        XCTAssertTrue(steps.allSatisfy { $0.1 == 3 }, "Die Gesamtzahl steht von Anfang an fest.")

        // Monotone: a bar that jumps backwards reads as a restart.
        let dones = steps.map(\.0)
        XCTAssertEqual(dones, dones.sorted(), "Der Fortschritt darf nicht zurückspringen.")
    }

    /// A turn that hangs for minutes is worse than an answer over part of the folder
    /// that says so.
    func testAnExhaustedBudgetIsReportedRatherThanHidden() async throws {
        for i in 1...6 { try putText("datei\(i).txt", "Inhalt \(i) mit genug Text zum Lesen.") }

        let progress = await library.index(root: root, budget: 0)
        XCTAssertTrue(progress.stoppedEarly, "Das Zeitlimit muss in der Antwort stehen.")
        XCTAssertEqual(progress.parsed, 0)
        XCTAssertEqual(progress.total, 6)
    }

    /// Stopping early must not prune: the files it never reached are not missing.
    func testStoppingEarlyDoesNotThrowAwayWhatWasNotReached() async throws {
        try putText("a.txt", "Ein Dokument über Heizkessel und Wartung.")
        await library.index(root: root)
        var summary = await library.summary()
        XCTAssertEqual(summary.documents, 1)

        try putText("b.txt", "Ein zweites Dokument.")
        await library.index(root: root, budget: 0)
        summary = await library.summary()
        XCTAssertEqual(summary.documents, 1, "Das erste bleibt trotz Abbruch erhalten.")
    }

    // MARK: Reading once

    func testASecondRunReadsNothingAgain() async throws {
        try putText("a.txt", "Der Heizkessel wurde 2019 getauscht.")
        try put("b.docx", DocumentFixtures.docx)

        let first = await library.index(root: root)
        XCTAssertEqual(first.parsed, 2)
        XCTAssertEqual(first.skipped, 0)

        let second = await library.index(root: root)
        XCTAssertEqual(second.parsed, 0, "Nichts hat sich geändert.")
        XCTAssertEqual(second.skipped, 2)
    }

    /// The whole point of keying on the file's own stamp: a changed document replaces
    /// what was stored, and the old wording stops being findable.
    func testAChangedFileIsReadAgainAndTheOldTextIsGone() async throws {
        try putText("notiz.md", "Der Heizkessel wurde 2019 getauscht.")
        await library.index(root: root)
        var hits = await library.search("2019")
        XCTAssertEqual(hits.hits.count, 1)

        // A second of distance, so the modification date really differs.
        try await Task.sleep(for: .milliseconds(1_100))
        try putText("notiz.md", "Der Heizkessel wurde 2024 erneuert.")

        let again = await library.index(root: root)
        XCTAssertEqual(again.parsed, 1)

        hits = await library.search("2019")
        XCTAssertTrue(hits.hits.isEmpty, "Der alte Stand darf nicht mehr gefunden werden.")
        hits = await library.search("2024")
        XCTAssertEqual(hits.hits.count, 1)
    }

    func testAFileThatWentAwayIsDroppedFromTheIndex() async throws {
        try putText("a.txt", "Bleibt bestehen und ist lang genug.")
        try putText("b.txt", "Wird gleich gelöscht, auch lang genug.")
        await library.index(root: root)
        var count = await library.summary().documents
        XCTAssertEqual(count, 2)

        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
        await library.index(root: root)
        count = await library.summary().documents
        XCTAssertEqual(count, 1)
    }

    // MARK: Reading one

    func testReadingOneDocumentCachesIt() async throws {
        try put("Wohnung/Mietvertrag.docx", DocumentFixtures.docx)
        let url = root.appendingPathComponent("Wohnung/Mietvertrag.docx")

        let first = await library.document(at: "Wohnung/Mietvertrag.docx", url: url)
        XCTAssertNotNil(first)
        let count = await library.summary().documents
        XCTAssertEqual(count, 1)

        // Now it is current, so a walk has nothing to do for it.
        let walk = await library.index(root: root)
        XCTAssertEqual(walk.parsed, 0)
        XCTAssertEqual(walk.skipped, 1)
    }

    /// Only what a parser here knows is offered to the index. A video counted as a
    /// document would be read, fail, and be read again on every walk.
    func testUnreadableFormatsAreNotEvenListed() throws {
        let files = DocumentLibrary.readableFiles(under: root)
        XCTAssertTrue(files.isEmpty)

        try putText("notiz.txt", "Text")
        try put("film.mov", Data(repeating: 0, count: 32))
        try put("archiv.zip", DocumentFixtures.docx)

        let names = DocumentLibrary.readableFiles(under: root).map(\.0)
        XCTAssertEqual(names, ["notiz.txt"])
    }
}
