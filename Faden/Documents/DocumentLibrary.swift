import Foundation

/// The folder as a readable, searchable body of documents.
///
/// Three jobs, and the split between them is what keeps a turn fast. Reading one named
/// document parses on demand and caches — a single file is milliseconds to seconds, and
/// waiting for it is what the user asked for. Searching contents answers from the index
/// alone and never parses, because a question is not the moment to read four hundred
/// files. Filling the index is a third thing that happens outside a turn.
///
/// What that costs is honesty about coverage: a content search can only find what has
/// been read, so the answer says how much that is. A search that quietly reported "not
/// found" for a folder it had never opened would be the worst of the three.
actor DocumentLibrary {
    static let shared = DocumentLibrary()

    private let index: DocumentIndex

    init(index: DocumentIndex = .shared) {
        self.index = index
    }

    // MARK: Reading one

    /// The parsed document, from the index when it is current and from the file when it
    /// is not.
    ///
    /// The stamp is read before anything else and decides everything: same date and
    /// size means what is stored was made from this file as it stands, and nothing is
    /// touched. That is the rule the whole cache rests on, and it is the reason a
    /// second question about the same document costs nothing.
    func document(at path: String, url: URL) async -> ParsedDocument? {
        guard let stamp = Self.stamp(of: url) else { return nil }

        if await index.isFresh(path, stamp), let stored = await index.document(at: path) {
            return stored
        }
        let name = (path as NSString).lastPathComponent
        guard let parsed = await Self.parseCoordinated(url, name: name) else {
            // Nothing readable came out. Remembering that would mean never trying
            // again; a file that is unreadable today may be a downloaded one tomorrow.
            await index.forget(path)
            return nil
        }
        await index.store(parsed, at: path, stamp: stamp)
        return parsed
    }

    /// Parses through file coordination, with a copy that outlives the block.
    ///
    /// Two things force this. The provider has to be asked to fetch a file that is not
    /// downloaded — `Data(contentsOf:)` on a dataless file gets an empty file or an
    /// error depending on the day — and `NSFileCoordinator`'s block is synchronous,
    /// while parsing is not: HTML has to hop to the main actor. A copy into the
    /// temporary directory bridges the two, and it is deleted on the way out.
    ///
    /// The copy is why files are capped before they get here. Four megabytes twice over
    /// is a cost worth paying; a video is not.
    private static func parseCoordinated(_ url: URL, name: String) async -> ParsedDocument? {
        var local: URL?
        var failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { ready in
            let size = (try? ready.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= SharedFolder.maxBytes else { return }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + name)
            if (try? FileManager.default.copyItem(at: ready, to: temporary)) != nil {
                local = temporary
            }
        }
        guard let local else { return nil }
        defer { try? FileManager.default.removeItem(at: local) }
        return await DocumentParser.parse(local, name: name)
    }

    static func stamp(of url: URL) -> DocumentIndex.Stamp? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                             .fileSizeKey]),
              let modified = values.contentModificationDate,
              let size = values.fileSize else { return nil }
        return .init(modified: modified, size: size)
    }

    // MARK: Searching

    struct Result: Equatable {
        var hits: [DocumentIndex.Hit]
        var indexed: Int
    }

    func search(_ text: String, limit: Int = 15) async -> Result {
        let hits = await index.search(text, limit: limit)
        return Result(hits: hits, indexed: await index.summary().documents)
    }

    func summary() async -> DocumentIndex.Summary { await index.summary() }

    // MARK: Filling the index

    struct Progress: Equatable {
        var parsed: Int
        var skipped: Int
        var failed: Int
        var total: Int
        /// The budget ran out before the folder did. Said in the answer rather than
        /// swallowed: a search over half a folder that claims to be a search over the
        /// folder is the one outcome nobody can tell from the real thing.
        var stoppedEarly = false
    }

    private var indexing = false
    var isIndexing: Bool { indexing }

    /// Walks the folder and reads what has changed.
    ///
    /// Files that are already current are skipped without being opened — for a synced
    /// folder that matters more than it looks, because opening a file that is not
    /// downloaded yet fetches it over the network. Only what is stale is materialised.
    ///
    /// `budget` is a wall-clock stop, not a file count. The work per file spans four
    /// orders of magnitude — a text note is instant, twenty OCR pages is half a minute
    /// — so counting files would either stop after nothing or run for an hour.
    @discardableResult
    func index(root: URL, budget: TimeInterval = 60,
               onProgress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in })
    async -> Progress {
        guard !indexing else { return Progress(parsed: 0, skipped: 0, failed: 0, total: 0) }
        indexing = true
        defer { indexing = false }

        let deadline = Date().addingTimeInterval(budget)
        let files = Self.readableFiles(under: root)
        var progress = Progress(parsed: 0, skipped: 0, failed: 0, total: files.count)
        var seen: Set<String> = []

        // Reported at the top of each turn rather than the bottom: the body has three
        // ways out, and a detached task per file would race the counter it reads.
        for (i, (path, url)) in files.enumerated() {
            await onProgress(i, files.count)
            seen.insert(path)
            guard let stamp = Self.stamp(of: url) else { progress.failed += 1; continue }
            if await index.isFresh(path, stamp) { progress.skipped += 1; continue }
            guard Date() < deadline else { progress.stoppedEarly = true; continue }

            if let parsed = await Self.parseCoordinated(url, name: (path as NSString).lastPathComponent) {
                await index.store(parsed, at: path, stamp: stamp)
                progress.parsed += 1
            } else {
                progress.failed += 1
            }
            // A walk of a large folder should not hold the actor against a question.
            await Task.yield()
        }

        await onProgress(files.count, files.count)

        // Only when the walk was complete: pruning after a walk that stopped at the
        // budget would throw away everything it did not reach.
        if seen.count == files.count { await index.prune(keeping: seen) }
        return progress
    }

    func clear() async { await index.clear() }

    /// Every file under the folder that any parser here can read, with its path.
    ///
    /// Breadth first and capped, for the reason `SharedFolder.find` is: a synced folder
    /// is wide at the top and deep in one arm, and a depth-first walk spends the whole
    /// allowance inside the first arm.
    static func readableFiles(under root: URL, max: Int = 2_000) -> [(String, URL)] {
        var out: [(String, URL)] = []
        var queue = [root]
        var visited = 0

        while !queue.isEmpty, out.count < max, visited < 20_000 {
            let directory = queue.removeFirst()
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }

            for url in entries {
                visited += 1
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                if isDirectory {
                    queue.append(url)
                } else if DocumentParser.canRead(url.lastPathComponent) {
                    out.append((SharedFolder.relativePath(of: url, under: root), url))
                }
            }
        }
        return out
    }
}
