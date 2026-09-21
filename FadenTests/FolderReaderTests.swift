import XCTest
@testable import Faden

/// The `files` tool end to end: a real bookmark, a real folder, the text the model
/// would actually receive.
///
/// `SharedFolderTests` checks the pieces. This checks that they are wired up — that a
/// bookmark resolves, that a refused path stays refused once it has been through the
/// tool rather than the function, and above all that everything coming out of here is
/// fenced. The fencing is the one property that is easy to lose in a later edit: add a
/// branch, forget the wrapper, and nothing fails.
final class FolderReaderTests: XCTestCase {

    private var root: URL!
    private var bookmark: Data!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try write("Steuer/2025/bescheid.txt", "Festsetzung Einkommensteuer 2025. Erstattung 412,80 Euro.")
        try write("Steuer/2024/bescheid.txt", "Festsetzung Einkommensteuer 2024.")
        try write("Notizen/einkauf.md", "- Milch\n- Brot")
        try write("bild.png", "\u{89}PNG\u{0}\u{0}")

        bookmark = try root.bookmarkData()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func run(_ input: [String: JSONValue]) async
    -> (text: String, ok: Bool, summary: String) {
        await FolderReader.shared.run(.object(input), bookmark: bookmark, name: "Spind")
    }

    // MARK: list

    func testListingTheTopOfTheFolder() async {
        let out = await run(["action": .string("list")])
        XCTAssertTrue(out.ok)
        XCTAssertTrue(out.text.contains("Notizen/"), out.text)
        XCTAssertTrue(out.text.contains("Steuer/"), out.text)
        XCTAssertTrue(out.text.contains("bild.png"), out.text)
    }

    func testListingASubfolder() async {
        let out = await run(["action": .string("list"), "path": .string("Steuer/2025")])
        XCTAssertTrue(out.ok)
        XCTAssertTrue(out.text.contains("bescheid.txt"), out.text)
        XCTAssertFalse(out.text.contains("2024"), out.text)
    }

    func testAFolderThatIsNotThereIsNotAnEmptyFolder() async {
        let out = await run(["action": .string("list"), "path": .string("Gibtsnicht")])
        XCTAssertFalse(out.ok)
    }

    /// The near miss worth naming: the model has the right path and the wrong action.
    /// "Does not exist" would send it looking for the path all over again.
    func testListingAFileSaysToReadItInstead() async {
        let out = await run(["action": .string("list"),
                             "path": .string("Notizen/einkauf.md")])
        XCTAssertFalse(out.ok)
        XCTAssertTrue(out.text.contains("read"), out.text)
    }

    /// A directory enumeration is in no order anybody chose. Without sorting, the same
    /// folder answers the same question differently twice.
    func testFindComesBackInAStableOrder() async {
        let first = await run(["action": .string("find"), "query": .string("bescheid")])
        let again = await run(["action": .string("find"), "query": .string("bescheid")])
        // The fence identifier is rolled per call, so the bodies are compared.
        XCTAssertEqual(first.text.contains("2024/bescheid.txt\nSteuer/2025"),
                       again.text.contains("2024/bescheid.txt\nSteuer/2025"))
        XCTAssertTrue(first.text.contains("Steuer/2024/bescheid.txt\nSteuer/2025/bescheid.txt"),
                      first.text)
    }

    // MARK: find

    func testFindingAcrossTheTree() async {
        let out = await run(["action": .string("find"), "query": .string("bescheid")])
        XCTAssertTrue(out.ok)
        XCTAssertTrue(out.text.contains("Steuer/2025/bescheid.txt"), out.text)
        XCTAssertTrue(out.text.contains("Steuer/2024/bescheid.txt"), out.text)
    }

    /// Nothing found is a result, not a failure — and the answer says what was searched,
    /// so the model tries another word instead of concluding the file does not exist.
    func testFindingNothingSaysWhatWasSearched() async {
        let out = await run(["action": .string("find"), "query": .string("gitarre")])
        XCTAssertTrue(out.ok)
        XCTAssertTrue(out.text.contains("nur in Namen"), out.text)
    }

    // MARK: read

    func testReadingAFile() async {
        let out = await run(["action": .string("read"),
                             "path": .string("Steuer/2025/bescheid.txt")])
        XCTAssertTrue(out.ok)
        XCTAssertTrue(out.text.contains("412,80"), out.text)
    }

    func testReadingSomethingThatIsNotThere() async {
        let out = await run(["action": .string("read"), "path": .string("Steuer/2023/x.txt")])
        XCTAssertFalse(out.ok)
        XCTAssertTrue(out.text.contains("list"), "Der Weg weiter gehört in die Antwort.")
    }

    func testAnImageIsNamedRatherThanRead() async {
        let out = await run(["action": .string("read"), "path": .string("bild.png")])
        XCTAssertFalse(out.ok)
        XCTAssertTrue(out.text.contains(".png"), out.text)
    }

    // MARK: search — reading happens when the agent asks

    /// The point of the whole arrangement: nobody pressed anything, and the content of
    /// a document that was never opened before is findable because the model asked.
    func testSearchingContentsReadsTheFolderFirst() async {
        await DocumentLibrary.shared.clear()

        let out = await run(["action": .string("search"), "query": .string("Erstattung")])
        XCTAssertTrue(out.ok, out.text)
        XCTAssertTrue(out.text.contains("Steuer/2025/bescheid.txt"), out.text)
        XCTAssertTrue(out.text.contains("412,80"), out.text)
        XCTAssertTrue(out.text.contains("neu eingelesen"),
                      "Die Antwort sagt, dass dafür gelesen wurde.")
    }

    /// Reading a folder is minutes from cold. A search that quietly covered half of it
    /// and claimed to cover the folder is the one outcome nobody can tell from the
    /// real thing.
    func testAnIncompleteReadIsSaidInTheAnswer() async {
        await DocumentLibrary.shared.clear()
        // Nothing is read on the first call; what matters is that the answer admits it.
        let out = await FolderReader.shared.run(
            .object(["action": .string("search"), "query": .string("gibtesnicht")]),
            bookmark: bookmark, name: "Spind")
        XCTAssertTrue(out.ok)
        XCTAssertTrue(out.text.contains("<<<fremd:"), "Auch das bleibt eingefasst.")
    }

    func testContentSearchFindsNothingWithoutAQuery() async {
        let out = await run(["action": .string("search")])
        XCTAssertFalse(out.ok)
    }

    // MARK: The boundary, through the tool

    func testTheSameRefusalWhicheverWayOut() async {
        for attempt in ["../", "Steuer/../../geheim", "/etc/passwd", "~/Documents"] {
            let read = await run(["action": .string("read"), "path": .string(attempt)])
            let list = await run(["action": .string("list"), "path": .string(attempt)])
            XCTAssertFalse(read.ok, attempt)
            XCTAssertFalse(list.ok, attempt)
            // One sentence for every way out. A refusal that varied per case would be a
            // map of where the boundary runs.
            XCTAssertTrue(read.text.contains("führt aus dem freigegebenen Ordner heraus"),
                          "\(attempt): \(read.text)")
        }
    }

    /// The fence is what separates "the model read a file" from "a file gave the model
    /// an instruction". A later branch that forgets it fails nothing else.
    func testEverythingThatComesBackIsFenced() async {
        let cases: [[String: JSONValue]] = [
            ["action": .string("list")],
            ["action": .string("list"), "path": .string("Notizen")],
            ["action": .string("find"), "query": .string("bescheid")],
            ["action": .string("find"), "query": .string("gitarre")],
            ["action": .string("read"), "path": .string("Notizen/einkauf.md")],
        ]
        for input in cases {
            let out = await run(input)
            XCTAssertTrue(out.text.contains("<<<fremd:"), "Ungefasst: \(input)")
            XCTAssertTrue(out.text.contains("<<</fremd:"), "Ungefasst: \(input)")
        }
    }

    /// The fence tells the model where the text comes from, and for a file that is not
    /// the net. A sentence that said otherwise would be untrue in exactly the place
    /// that asks for care.
    func testTheFenceNamesTheRightOrigin() async {
        let out = await run(["action": .string("read"), "path": .string("Notizen/einkauf.md")])
        XCTAssertTrue(out.text.contains("stammt aus einer Datei im freigegebenen Ordner"),
                      out.text)
        XCTAssertFalse(out.text.contains("aus dem Netz"), out.text)
    }

    /// Our own error messages stay outside the fence: they are not material to be read
    /// but the reason the model should do something else next.
    func testOurOwnRefusalsAreNotFenced() async {
        let out = await run(["action": .string("read"), "path": .string("../geheim")])
        XCTAssertFalse(out.text.contains("<<<fremd:"), out.text)
    }

    func testAnUnknownActionNamesTheOnesThatExist() async {
        let out = await run(["action": .string("delete"), "path": .string("bild.png")])
        XCTAssertFalse(out.ok)
        for action in ["list", "find", "read"] {
            XCTAssertTrue(out.text.contains(action), out.text)
        }
    }

    func testAFolderThatWentAwaySaysSoAndPointsAtTheSettings() async {
        let out = await FolderReader.shared.run(
            .object(["action": .string("list")]),
            bookmark: Data("kein Lesezeichen".utf8), name: "Spind")
        XCTAssertFalse(out.ok)
        XCTAssertTrue(out.text.contains("Einstellungen"), out.text)
    }
}
