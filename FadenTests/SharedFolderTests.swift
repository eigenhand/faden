import XCTest
@testable import Faden

/// Reading out of the folder the user opened.
///
/// The half that matters here is `locate`. Everything else in this feature fails
/// loudly — a missing file says so, an unreadable one says so — but a path that escapes
/// the folder fails silently and successfully: the model gets a file, the answer looks
/// right, and nobody finds out. That is why most of what follows is one function under
/// attack rather than a tour of the feature.
final class SharedFolderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relative: String, _ contents: String = "Inhalt") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: The boundary

    func testAnOrdinaryPathLandsWhereItShould() throws {
        try write("Steuer/2025/bescheid.txt")
        let url = try XCTUnwrap(SharedFolder.locate("Steuer/2025/bescheid.txt", under: root))
        XCTAssertEqual(url.lastPathComponent, "bescheid.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// The ordinary case, and the one a model produces by itself when it stitches a
    /// path together out of two listings.
    func testClimbingOutIsRefused() {
        for attempt in ["..", "../", "../geheim", "Steuer/../../geheim",
                        "Steuer/2025/../../../etc/passwd", "a/b/../../../..",
                        "./../x"] {
            XCTAssertNil(SharedFolder.locate(attempt, under: root),
                         "„\(attempt)“ hätte abgewiesen werden müssen.")
        }
    }

    /// An encoded separator is a character in a name, not a separator.
    ///
    /// What this asserts is containment and not refusal, and the difference is the
    /// point: nothing decodes `%2F` on the way to the file system, so `..%2F..` is a
    /// legal — if strange — file name that sits inside the folder. Refusing it would be
    /// a rule about a threat that is not there; what has to hold is that it does not
    /// become a way out.
    func testAnEncodedSeparatorStaysInsideTheFolder() throws {
        let url = try XCTUnwrap(SharedFolder.locate("Steuer/..%2F..", under: root))
        let inside = url.resolvingSymlinksInPath().standardizedFileURL.path
            .hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/")
        XCTAssertTrue(inside, url.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Und es gibt sie nicht — „read“ endet hier mit „nicht da“.")
    }

    /// Not reinterpreted as relative and not helpfully corrected. `/etc/passwd` is not
    /// a typo to be fixed.
    func testAnAbsolutePathIsRefused() {
        XCTAssertNil(SharedFolder.locate("/etc/passwd", under: root))
        XCTAssertNil(SharedFolder.locate("/", under: root))
        XCTAssertNil(SharedFolder.locate("~/Documents", under: root))
        XCTAssertNil(SharedFolder.locate("~", under: root))
    }

    /// The check that the first one cannot do. A synced folder holds what the server
    /// holds, and a link inside it that points out of it looks like an ordinary name
    /// until it is resolved.
    func testASymlinkOutOfTheFolderIsRefused() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("geheim".utf8).write(to: outside.appendingPathComponent("secret.txt"))

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("draussen"), withDestinationURL: outside)

        XCTAssertNil(SharedFolder.locate("draussen/secret.txt", under: root),
                     "Ein Link aus dem Ordner heraus ist ein Weg heraus.")
        XCTAssertNil(SharedFolder.locate("draussen", under: root))
    }

    /// A link that stays inside is not an escape and must keep working — otherwise the
    /// rule would be "no links", which is not the rule.
    func testASymlinkInsideTheFolderStillWorks() throws {
        try write("echt/datei.txt")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("kurz"),
            withDestinationURL: root.appendingPathComponent("echt"))

        XCTAssertNotNil(SharedFolder.locate("kurz/datei.txt", under: root))
    }

    func testTheFolderItselfIsInside() {
        XCTAssertEqual(SharedFolder.locate("", under: root)?.standardizedFileURL,
                       root.standardizedFileURL)
        XCTAssertEqual(SharedFolder.locate(".", under: root)?.standardizedFileURL,
                       root.standardizedFileURL)
    }

    /// A sibling folder whose name merely starts with the root's. The prefix comparison
    /// is what this guards: without the separator, `/tmp/foo-evil` counts as inside
    /// `/tmp/foo`.
    func testANeighbourWithASimilarNameIsNotInside() throws {
        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }

        XCTAssertNil(SharedFolder.locate("../\(sibling.lastPathComponent)", under: root))
    }

    func testRelativePathsComeBackInTheFormTheyAreGivenIn() throws {
        let url = try write("Steuer/2025/bescheid.txt")
        XCTAssertEqual(SharedFolder.relativePath(of: url, under: root),
                       "Steuer/2025/bescheid.txt")
        XCTAssertEqual(SharedFolder.relativePath(of: root, under: root), "")
    }

    // MARK: Listing

    func testFoldersComeFirstAndHiddenFilesDoNotCome() throws {
        try write("zebra.txt")
        try write("Archiv/alt.txt")
        try write(".DS_Store")
        try write("apfel.txt")

        let entries = try SharedFolder.list(root)
        XCTAssertEqual(entries.map(\.name), ["Archiv", "apfel.txt", "zebra.txt"])
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].bytes, 6)
    }

    // MARK: Finding

    func testFindNeedsEveryWordOfTheQuery() throws {
        try write("Steuer/2025/Bescheid Finanzamt.pdf")
        try write("Steuer/2024/Bescheid Krankenkasse.pdf")
        try write("Fotos/urlaub.jpg")

        let hits = SharedFolder.find("bescheid finanzamt", under: root)
            .map { SharedFolder.relativePath(of: $0, under: root) }
        XCTAssertEqual(hits, ["Steuer/2025/Bescheid Finanzamt.pdf"])
    }

    func testFindIgnoresCapitalsAndAccents() throws {
        try write("Belege/Grün & Söhne.txt")
        XCTAssertEqual(SharedFolder.find("grun", under: root).count, 1)
    }

    /// A synced folder is wide at the top and deep in one arm. Depth first would spend
    /// the budget inside the first arm and return nothing from the rest.
    func testFindLooksAcrossTheWholeTreeNotJustTheFirstArm() throws {
        for year in 2000...2020 { try write("Archiv/\(year)/notiz.txt") }
        try write("Zuletzt/ziel.txt")

        let hits = SharedFolder.find("ziel", under: root)
        XCTAssertEqual(hits.count, 1)
    }

    // MARK: Reading

    func testATextFileComesBackAsText() {
        let result = SharedFolder.interpret(Data("Hallo Welt".utf8), name: "notiz.txt")
        XCTAssertEqual(result, .text("Hallo Welt", truncated: 0))
    }

    /// A page of mojibake looks like content and costs a turn to recognise as not being
    /// any. Saying what it is lets the model move on at once.
    func testBinaryContentIsNamedRatherThanDumped() {
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x0D])
        guard case .notText = SharedFolder.interpret(data, name: "bild.dat") else {
            return XCTFail("Binärdaten dürfen nicht als Text durchgehen.")
        }
    }

    func testKnownContainerFormatsAreRefusedByName() {
        for name in ["bericht.docx", "zahlen.xlsx", "urlaub.jpg", "archiv.zip"] {
            guard case .notText(let why) = SharedFolder.interpret(Data("PK\u{3}\u{4}".utf8),
                                                                  name: name) else {
                return XCTFail("\(name) hätte als „kein Text“ gelten müssen.")
            }
            XCTAssertTrue(why.contains("."), why)
        }
    }

    func testAnEmptyFileSaysSoRatherThanReturningNothing() {
        guard case .notText = SharedFolder.interpret(Data(), name: "leer.txt") else {
            return XCTFail("Eine leere Datei ist kein Text.")
        }
    }

    func testLongTextIsCutAndSaysByHowMuch() {
        let long = String(repeating: "a", count: SharedFolder.maxChars + 500)
        guard case .text(let text, let missing) = SharedFolder.interpret(Data(long.utf8),
                                                                        name: "lang.txt") else {
            return XCTFail("Langer Text bleibt Text.")
        }
        XCTAssertEqual(text.count, SharedFolder.maxChars)
        XCTAssertEqual(missing, 500)
    }

    func testAFileTooLargeIsNotEvenRead() throws {
        let url = root.appendingPathComponent("gross.txt")
        try Data(count: SharedFolder.maxBytes + 1).write(to: url)
        guard case .tooLarge = SharedFolder.read(url) else {
            return XCTFail("Über der Grenze wird nicht gelesen.")
        }
    }

    func testADirectoryIsNotAFile() {
        guard case .unreadable = SharedFolder.read(root) else {
            return XCTFail("Ein Ordner ist keine Datei.")
        }
    }

    // MARK: The bookmark

    func testAnUnusableBookmarkResolvesToNothing() {
        XCTAssertNil(SharedFolder.resolve(Data("kein Lesezeichen".utf8)))
        XCTAssertNil(SharedFolder.renewedBookmark(for: Data("kein Lesezeichen".utf8)))
    }

    /// Nothing to renew is not a failure, and must not be treated as one: a bookmark
    /// that is simply fine would otherwise be rewritten on every visit to the settings.
    func testAFreshBookmarkIsNotRenewed() throws {
        let bookmark = try root.bookmarkData()
        XCTAssertNotNil(SharedFolder.resolve(bookmark))
        XCTAssertNil(SharedFolder.renewedBookmark(for: bookmark))
    }

    func testAFolderWithoutABookmarkIsNotSet() {
        XCTAssertFalse(FolderConfig().isSet)
        XCTAssertFalse(AppSettings().folder.isSet)
    }
}
