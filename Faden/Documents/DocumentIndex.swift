import Foundation
import SQLite3

/// Parsed documents, kept so they are parsed once rather than once per question.
///
/// SQLite and not a folder of JSON files, which is what the rest of this app uses for
/// storage. The reason is the search: a model that asks "where does it say anything
/// about the boiler" has to be answered across every document in the folder, ranked,
/// with an excerpt — and doing that over JSON means loading every file into memory on
/// every question. FTS5 is part of the system SQLite on iOS, so this costs a link flag
/// and no dependency.
///
/// The freshness rule is the modification date and the size together. The date alone
/// is what everybody uses and it is not enough: a file synced back from a server can
/// arrive with a date it already had, and a second later the content is different.
/// Size is cheap to read and catches most of what the date misses. What neither
/// catches — an edit that keeps the byte count — would need a hash of the whole file,
/// which for a synced folder means downloading everything to check whether anything
/// changed. That trade is written down here rather than discovered later.
actor DocumentIndex {
    static let shared = DocumentIndex()

    /// The connection, in a box that closes it.
    ///
    /// Not a stored `OpaquePointer` on the actor: an actor's `deinit` is nonisolated
    /// and may not touch a non-Sendable property, so the handle would have to leak for
    /// the life of the process. A box with its own `deinit` closes at the right moment.
    /// `@unchecked` is accurate rather than a shrug — the pointer is read only from
    /// inside the actor, and the box is never handed out.
    private final class Connection: @unchecked Sendable {
        let db: OpaquePointer?
        init(path: String) {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            db = sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK ? handle : nil
            if db == nil, handle != nil { sqlite3_close_v2(handle) }
        }
        deinit { if let db { sqlite3_close_v2(db) } }
    }

    private let connection: Connection
    private var db: OpaquePointer? { connection.db }

    /// Where the index lives. Beside the conversations, in Application Support — it is
    /// derived data and has no business in the shared container or in the user's
    /// folder.
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("PerBu", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("documents.sqlite")
    }

    // SQLite needs to be told that the string it was handed will not outlive the call.
    // Swift does not import the macro, so it stands here once.
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL? = nil) {
        connection = Connection(path: (url ?? Self.url).path)
        Self.migrate(connection.db)
    }

    /// Static and outside the actor, because an actor's `init` may not call an isolated
    /// method: at that point `self` is not yet an actor anybody could be talking to,
    /// but the compiler has no way to know that. The schema is plain C calls anyway.
    private nonisolated static func migrate(_ db: OpaquePointer?) {
        guard let db else { return }
        func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }
        // WAL, because a parse writes while a search reads. Without it the search
        // blocks behind the indexing of a folder nobody asked about yet.
        exec("PRAGMA journal_mode = WAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS documents (
              path      TEXT PRIMARY KEY,
              modified  REAL    NOT NULL,
              size      INTEGER NOT NULL,
              parsed_at REAL    NOT NULL,
              kind      TEXT    NOT NULL,
              parser    TEXT    NOT NULL,
              title     TEXT,
              units     INTEGER,
              blocks    INTEGER NOT NULL
            );
            """)
        // `remove_diacritics 2` is the one that handles German: it folds the umlaut in
        // "Grün" without also folding the ß, so a search for "grun" finds it and a
        // search for "Strasse" does not silently become a search for "Straße".
        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS blocks USING fts5(
              path UNINDEXED, idx UNINDEXED, locator UNINDEXED, kind UNINDEXED, text,
              tokenize = 'unicode61 remove_diacritics 2'
            );
            """)
    }

    /// Whether FTS5 is really there. Asked rather than assumed: the whole search rests
    /// on it, and a build where it is missing should say so once instead of returning
    /// nothing to every question.
    var isUsable: Bool {
        guard db != nil else { return false }
        return query("SELECT count(*) FROM blocks;") { sqlite3_column_int64($0, 0) }.first != nil
    }

    // MARK: Freshness

    struct Stamp: Equatable {
        var modified: Date
        var size: Int
    }

    /// `true` when what is stored was parsed from exactly this file, as it stands now.
    func isFresh(_ path: String, _ stamp: Stamp) -> Bool {
        let rows = query("SELECT modified, size FROM documents WHERE path = ?;",
                         bind: [.text(path)]) {
            (sqlite3_column_double($0, 0), sqlite3_column_int64($0, 1))
        }
        guard let (modified, size) = rows.first else { return false }
        // A second of tolerance: file systems and providers round differently, and a
        // difference of microseconds is not a changed document.
        return abs(modified - stamp.modified.timeIntervalSince1970) < 1
            && size == Int64(stamp.size)
    }

    // MARK: Writing

    /// Replaces whatever was stored for this path.
    ///
    /// Delete then insert, in one transaction. Updating in place would leave the blocks
    /// of a longer previous version behind when a document gets shorter — and those
    /// would keep turning up in searches, attached to a file that no longer says any
    /// such thing.
    func store(_ document: ParsedDocument, at path: String, stamp: Stamp) {
        exec("BEGIN IMMEDIATE;")
        defer { exec("COMMIT;") }

        exec("DELETE FROM blocks WHERE path = ?;", bind: [.text(path)])
        exec("DELETE FROM documents WHERE path = ?;", bind: [.text(path)])

        exec("""
            INSERT INTO documents (path, modified, size, parsed_at, kind, parser, title, units, blocks)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, bind: [
                .text(path),
                .real(stamp.modified.timeIntervalSince1970),
                .int(Int64(stamp.size)),
                .real(Date().timeIntervalSince1970),
                .text(document.meta.kind),
                .text(document.meta.parser.rawValue),
                document.meta.title.map { .text($0) } ?? .null,
                document.meta.units.map { .int(Int64($0)) } ?? .null,
                .int(Int64(document.blocks.count)),
            ])

        for block in document.blocks {
            exec("INSERT INTO blocks (path, idx, locator, kind, text) VALUES (?, ?, ?, ?, ?);",
                 bind: [.text(path), .int(Int64(block.index)), .text(block.locator),
                        .text(block.kind.rawValue), .text(block.text)])
        }
    }

    func forget(_ path: String) {
        exec("DELETE FROM blocks WHERE path = ?;", bind: [.text(path)])
        exec("DELETE FROM documents WHERE path = ?;", bind: [.text(path)])
    }

    /// Throws away everything. For the moment the user points the app at a different
    /// folder: the paths are relative to a root, so after a change they name files that
    /// are not there, and a hit on one of those is worse than no hit.
    func clear() {
        exec("DELETE FROM blocks;")
        exec("DELETE FROM documents;")
        exec("VACUUM;")
    }

    /// Drops what is no longer in the folder. Called after a walk, with the paths that
    /// were seen.
    func prune(keeping present: Set<String>) {
        let stored = query("SELECT path FROM documents;") { String(cString: sqlite3_column_text($0, 0)) }
        for path in stored where !present.contains(path) { forget(path) }
    }

    // MARK: Reading

    func document(at path: String) -> ParsedDocument? {
        let metaRows = query("""
            SELECT kind, parser, title, units FROM documents WHERE path = ?;
            """, bind: [.text(path)]) { s -> (String, String, String?, Int?) in
                (String(cString: sqlite3_column_text(s, 0)),
                 String(cString: sqlite3_column_text(s, 1)),
                 sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, 2)),
                 sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, 3)))
            }
        guard let (kind, parser, title, units) = metaRows.first else { return nil }

        let blocks = query("""
            SELECT idx, locator, kind, text FROM blocks WHERE path = ? ORDER BY CAST(idx AS INTEGER);
            """, bind: [.text(path)]) { s in
                ParsedDocument.Block(
                    index: Int(sqlite3_column_int64(s, 0)),
                    locator: String(cString: sqlite3_column_text(s, 1)),
                    kind: ParsedDocument.Block.Kind(rawValue: String(cString: sqlite3_column_text(s, 2))) ?? .body,
                    text: String(cString: sqlite3_column_text(s, 3)))
            }

        return ParsedDocument(
            meta: .init(kind: kind,
                        parser: ParsedDocument.Meta.Parser(rawValue: parser) ?? .plainText,
                        title: title, units: units),
            blocks: blocks)
    }

    struct Hit: Equatable {
        var path: String
        var block: Int
        var locator: String
        /// The passage with the match in it, cut to a readable length by SQLite.
        var snippet: String
    }

    /// Searches the contents of everything indexed.
    func search(_ text: String, limit: Int = 20) -> [Hit] {
        guard let expression = Self.matchExpression(for: text) else { return [] }
        return query("""
            SELECT path, idx, locator, snippet(blocks, 4, '', '', '…', 14)
            FROM blocks WHERE blocks MATCH ? ORDER BY bm25(blocks) LIMIT ?;
            """, bind: [.text(expression), .int(Int64(max(1, limit)))]) { s in
                Hit(path: String(cString: sqlite3_column_text(s, 0)),
                    block: Int(sqlite3_column_int64(s, 1)),
                    locator: String(cString: sqlite3_column_text(s, 2)),
                    snippet: String(cString: sqlite3_column_text(s, 3)))
            }
    }

    /// Turns what somebody typed into something FTS5 will accept.
    ///
    /// Not cosmetic: FTS5's MATCH takes a query language, so a bare apostrophe, a
    /// hyphen or the word `AND` is a syntax error rather than a search. Every token is
    /// quoted and the operators never reach the parser — the cost is that `OR` and
    /// `NEAR` cannot be used deliberately, which nobody asking about their documents
    /// was going to do anyway.
    ///
    /// Every token is matched as a prefix, and that is a decision about German rather
    /// than a convenience. FTS5 compares whole tokens, so "Mietvertrag" does not find
    /// "Mietvertrags", "Rechnung" does not find "Rechnungen", and "Müller's" splits at
    /// the apostrophe into a token that matches nothing. Exact matching is defensible
    /// in a language that inflects less; here it turns most honest questions into
    /// "nothing found". The price is that a short word reaches further than asked —
    /// bm25 ranks those down, and the limit cuts the tail.
    ///
    /// Fragments of one character are dropped. They are what splitting produces — the
    /// "s" out of "Müller's" — and as a prefix a single letter matches a quarter of the
    /// document.
    static func matchExpression(for raw: String) -> String? {
        let tokens = raw
            .replacingOccurrences(of: "[^\\p{L}\\p{N}*]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map { $0.hasSuffix("*") ? String($0.dropLast()) : String($0) }
            .filter { $0.count > 1 }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: Statistics

    struct Summary: Equatable {
        var documents: Int
        var blocks: Int
    }

    func summary() -> Summary {
        let docs = query("SELECT count(*) FROM documents;") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        let blocks = query("SELECT count(*) FROM blocks;") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        return Summary(documents: docs, blocks: blocks)
    }

    // MARK: The thin SQLite layer

    private enum Value {
        case text(String), int(Int64), real(Double), null
    }

    private func bind(_ statement: OpaquePointer?, _ values: [Value]) {
        for (i, value) in values.enumerated() {
            let column = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(statement, column, s, -1, transient)
            case .int(let n):  sqlite3_bind_int64(statement, column, n)
            case .real(let d): sqlite3_bind_double(statement, column, d)
            case .null:        sqlite3_bind_null(statement, column)
            }
        }
    }

    @discardableResult
    private func exec(_ sql: String, bind values: [Value] = []) -> Bool {
        guard let db else { return false }
        // Several statements in one string only work through `sqlite3_exec`; anything
        // with parameters has to go through prepare.
        guard !values.isEmpty else { return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        bind(statement, values)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func query<T>(_ sql: String, bind values: [Value] = [],
                          read: (OpaquePointer?) -> T) -> [T] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        bind(statement, values)
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { out.append(read(statement)) }
        return out
    }
}
