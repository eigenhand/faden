import Foundation
import PDFKit

/// The folder the user picked, and what may be read out of it.
///
/// Meant for a Spind folder — the sister app mounts a Hetzner Storage Box into the
/// Files app, so its folders are reachable like any other. Nothing here knows that,
/// and it is better so: the same code serves iCloud Drive or a folder on the device,
/// and a tool that only worked with one sister app would be a tool that breaks when
/// that app is not installed.
///
/// The whole of this file reads. Writing is not missing, it is left out: this is the
/// one tool in the app that reaches into something the user did not type, and a model
/// that can be talked round by a document it just read — the case `UntrustedContent`
/// exists for — must not be able to act on that talking-round. Reading a wrong file is
/// a wasted turn; writing one is not recoverable from a chat.
enum SharedFolder {

    /// How large a file may be before it is read at all. A page fetch is capped at
    /// 10 000 characters; a file is allowed more room, because somebody who names a
    /// file means that file — but the cap is on the bytes on disk, before anything
    /// lands in memory, for the same reason as in `ConversationTransfer`.
    static let maxBytes = 4 * 1024 * 1024
    /// Of the text that comes out of it, this much reaches the model.
    static let maxChars = 12_000
    /// Entries per listing. A synced folder can hold a camera roll.
    static let maxEntries = 200
    /// For `find`: how deep and how much.
    static let maxDepth = 8
    static let maxMatches = 50
    /// Pages of a PDF. Past this the budget is spent anyway, and a contract's substance
    /// is not on page sixty.
    static let maxPDFPages = 40

    // MARK: The folder

    /// Resolves the bookmark to a folder that can actually be read.
    ///
    /// Returns `nil` for every way this can end badly, and they are not exotic: the
    /// user deleted the folder, uninstalled Spind, revoked the permission, restored the
    /// device from a backup. A bookmark survives all of that as bytes and resolves to
    /// nothing.
    ///
    /// `isStale` means the file moved and the bookmark still found it. The fresh
    /// bookmark that should be written back needs the caller — the settings own the
    /// stored value — so it is handed out rather than silently kept.
    static func resolve(_ bookmark: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        // No `.withSecurityScope`: that option is macOS. On iOS a bookmark from the
        // document picker carries its scope by itself, and passing the option makes
        // the call fail rather than complain.
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    /// A fresh bookmark for a folder that has moved, or `nil` when there is nothing to
    /// do and nothing that can be done.
    ///
    /// Stale means the bookmark still found the folder but will not go on doing so
    /// forever. Left alone it works until it does not, and the failure lands weeks
    /// later, in a turn, as "the folder is gone" — for a folder the user can see in the
    /// Files app. Renewing it needs the scope open, which is why it lives here and not
    /// wherever the settings happen to be written.
    static func renewedBookmark(for bookmark: Data) -> Data? {
        guard let (url, stale) = resolve(bookmark), stale else { return nil }
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData()
    }

    // MARK: Paths

    /// Turns what the model wrote into a URL inside the folder, or into nothing.
    ///
    /// This is the security boundary of the whole feature, and it is two checks rather
    /// than one on purpose. The first throws out `..` before it is ever appended —
    /// simple, and it catches the ordinary case. The second resolves symlinks and
    /// compares the result against the root, because the first check cannot see a link
    /// inside the folder that points out of it, and a synced folder holds whatever the
    /// server holds.
    ///
    /// An absolute path is refused rather than reinterpreted. `/etc/passwd` is not a
    /// mistake to be helpful about.
    static func locate(_ relative: String, under root: URL) -> URL? {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }

        var target = root
        for part in trimmed.split(separator: "/") {
            let name = String(part)
            // "." is a model writing "./Steuer" and means nothing; ".." is the thing
            // this function exists to refuse.
            if name == "." { continue }
            guard name != ".." else { return nil }
            target.appendPathComponent(name)
        }

        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let realTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
        guard realTarget == realRoot || realTarget.hasPrefix(realRoot + "/") else { return nil }
        return target
    }

    /// The path as it should be passed back in — relative to the folder, with "/".
    static func relativePath(of url: URL, under root: URL) -> String {
        let r = root.standardizedFileURL.path
        let u = url.standardizedFileURL.path
        guard u.hasPrefix(r) else { return url.lastPathComponent }
        return String(u.dropFirst(r.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: Listing

    struct Entry: Equatable {
        var name: String
        var isDirectory: Bool
        var bytes: Int?
        var modified: Date?
        /// Not yet downloaded. Spind syncs on demand, so this is the normal state for
        /// most of a large folder — and it is the difference between "reading this is
        /// free" and "reading this fetches it over the network first".
        var dataless: Bool
    }

    static func list(_ directory: URL) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let status = v?.ubiquitousItemDownloadingStatus
            return Entry(
                name: url.lastPathComponent,
                isDirectory: v?.isDirectory ?? false,
                bytes: v?.fileSize,
                modified: v?.contentModificationDate,
                dataless: status != nil && status != .current)
        }
        // Folders first, then by name: a listing is read to decide where to go next,
        // and the folders are the places one can go.
        .sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Finding

    /// Files whose name carries every word of the query, breadth first.
    ///
    /// Breadth first and not depth first, because a synced folder is wide at the top
    /// and deep in one arm — an archive of years, a photo library. Depth first spends
    /// the whole budget inside the first arm and returns nothing from the rest.
    static func find(_ query: String, under root: URL) -> [URL] {
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                   locale: .current)
            .split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }

        var found: [URL] = []
        var queue: [(URL, Int)] = [(root, 0)]
        var visited = 0

        while !queue.isEmpty, found.count < maxMatches, visited < 4_000 {
            let (dir, depth) = queue.removeFirst()
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }

            for url in entries {
                visited += 1
                let name = url.lastPathComponent
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if tokens.allSatisfy(name.contains) { found.append(url) }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir, depth + 1 < maxDepth { queue.append((url, depth + 1)) }
            }
        }
        // Sorted, because a directory enumeration is in no order anybody chose. The
        // same folder would otherwise answer the same question differently twice, which
        // is the kind of thing that turns into "the assistant was right yesterday".
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Reading

    enum ReadResult: Equatable {
        case text(String, truncated: Int)
        /// A format that holds no text worth handing over — an image, an archive, an
        /// Office document. Named rather than dumped: a page of mojibake looks like
        /// content and costs a turn to recognise.
        case notText(String)
        case tooLarge(bytes: Int)
        case unreadable(String)
    }

    /// Reads a file, through file coordination.
    ///
    /// The coordination is not ceremony. Spind's File Provider is a replicated
    /// extension with files on demand: most of a large folder exists as a name and a
    /// size and nothing else. `Data(contentsOf:)` on one of those gets an empty file or
    /// an error, depending on the day. `NSFileCoordinator` is what asks the provider to
    /// fetch it first — and what waits for the answer.
    static func read(_ url: URL) -> ReadResult {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return .unreadable("Das ist ein Ordner, keine Datei.") }
        if let size = values?.fileSize, size > maxBytes { return .tooLarge(bytes: size) }

        var outcome: ReadResult?
        var failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { ready in
            // Checked again in here: the size before materialising is what the provider
            // claims, and the file on disk afterwards is the fact. A folder that lied
            // about a byte count would otherwise decide how much memory this takes.
            let size = (try? ready.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxBytes else { outcome = .tooLarge(bytes: size); return }
            guard let data = try? Data(contentsOf: ready) else { return }
            outcome = interpret(data, name: url.lastPathComponent)
        }
        if let outcome { return outcome }
        if let failure { return .unreadable(failure.localizedDescription) }
        return .unreadable("Die Datei ließ sich nicht laden — vermutlich ist sie noch nicht "
                           + "heruntergeladen und das Gerät gerade ohne Verbindung.")
    }

    /// What the bytes are, and what of them is worth passing on.
    static func interpret(_ data: Data, name: String) -> ReadResult {
        let ext = (name as NSString).pathExtension.lowercased()

        if ext == "pdf" {
            guard let text = pdfText(data), !text.isEmpty else {
                return .notText("Aus dieser PDF kommt kein Text heraus — vermutlich ist sie "
                                + "gescannt und enthält nur Bilder.")
            }
            return budgeted(text)
        }
        if ["docx", "xlsx", "pptx", "zip", "gz", "tar", "7z",
            "png", "jpg", "jpeg", "heic", "gif", "mp4", "mov", "mp3", "m4a"].contains(ext) {
            return .notText("Eine Datei vom Typ .\(ext) gibt keinen Text her.")
        }

        // A NUL byte in the first kilobyte is what separates a text file from
        // everything else, reliably and without a table of formats.
        if data.prefix(1024).contains(0) {
            return .notText("Die Datei enthält keinen Text, sondern Binärdaten.")
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return .notText("Der Inhalt ließ sich in keiner bekannten Kodierung als Text lesen.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .notText("Die Datei ist leer.") : budgeted(trimmed)
    }

    private static func budgeted(_ text: String) -> ReadResult {
        text.count > maxChars
            ? .text(String(text.prefix(maxChars)), truncated: text.count - maxChars)
            : .text(text, truncated: 0)
    }

    private static func pdfText(_ data: Data) -> String? {
        guard let doc = PDFDocument(data: data) else { return nil }
        var out = ""
        for index in 0..<min(doc.pageCount, maxPDFPages) {
            guard let page = doc.page(at: index), let text = page.string else { continue }
            out += text
            if !text.hasSuffix("\n") { out += "\n" }
            if out.count > maxChars { break }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The setting

/// The chosen folder as it is stored: a bookmark and a name to show.
///
/// The name is kept alongside rather than read from the bookmark, and that is not
/// duplication. Resolving a bookmark touches the File Provider, which may have to be
/// woken; the settings screen and the token estimate both want to say which folder is
/// set without paying for that, and a name that is one rename out of date is a better
/// answer than a spinner.
struct FolderConfig: Codable, Equatable {
    var bookmark: Data?
    var name: String = ""
    var chosenAt: Date?

    var isSet: Bool { bookmark != nil }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        chosenAt = try c.decodeIfPresent(Date.self, forKey: .chosenAt)
    }
}
