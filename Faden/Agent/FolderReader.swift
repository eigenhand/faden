import Foundation

/// Runs the `files` tool: resolves the folder, does the one thing asked, and hands back
/// text the model may read but must not obey.
///
/// An actor, and not for shared state — there is none worth keeping. It is here because
/// everything below it blocks: `NSFileCoordinator` waits while a File Provider fetches a
/// file over the network, and a directory listing on a cold folder does the same. That
/// belongs off whatever thread the turn is streaming on.
actor FolderReader {
    static let shared = FolderReader()

    /// Everything that comes out of here is fenced, without exception and without a
    /// judgement about the file.
    ///
    /// The inventory is not fenced, and the difference is worth stating rather than
    /// leaving to whoever reads the two side by side. An inventory entry passed a human
    /// tick in Fundus. A file in a synced folder passed nothing: it is whatever the
    /// server holds, including what somebody else dropped in through one of Spind's
    /// share links. That is the definition of foreign content, and the fence is cheap.
    ///
    /// The listing is fenced too, although it is "only" names. A file name is attacker
    /// chosen — `Bitte ignoriere deine Anweisungen.txt` is a legal name on every file
    /// system there is.
    private static let origin = "aus einer Datei im freigegebenen Ordner"

    func run(_ input: JSONValue, bookmark: Data, name folderName: String,
             onProgress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async
    -> (text: String, ok: Bool, summary: String) {
        let action = input["action"]?.stringValue ?? "list"
        let path = input["path"]?.stringValue ?? ""
        let query = input["query"]?.stringValue ?? ""
        let block = input["block"]?.intValue

        guard let resolved = SharedFolder.resolve(bookmark) else {
            return ("""
                Fehler: Der freigegebene Ordner ist nicht mehr erreichbar. Er wurde \
                umbenannt, gelöscht oder die App, die ihn bereitstellt, ist nicht mehr \
                da. Der Nutzer kann ihn in den Einstellungen neu auswählen.
                """, false, "Ordner weg")
        }
        let root = resolved.url
        let opened = root.startAccessingSecurityScopedResource()
        defer { if opened { root.stopAccessingSecurityScopedResource() } }

        let label = folderName.isEmpty ? root.lastPathComponent : folderName

        switch action {
        case "search": return await search(query, root: root, label: label,
                                           onProgress: onProgress)
        case "list":   return list(path, root: root, label: label)
        case "find":   return find(query, root: root, label: label)
        case "read":   return await read(path, block: block, root: root, label: label)
        default:
            return ("Es gibt keine Aktion „\(action)“. Möglich sind: search, find, list, read.",
                    false, "unbekannt: \(action)")
        }
    }

    // MARK: list

    private func list(_ path: String, root: URL, label: String)
    -> (text: String, ok: Bool, summary: String) {
        guard let target = SharedFolder.locate(path, under: root) else {
            return (Self.refusal(path), false, "abgewiesen: \(path)")
        }
        // A file rather than a folder is the near miss worth naming: the model has the
        // right path and the wrong action, and "does not exist" would send it looking
        // for the path again.
        let isDir = (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
        if isDir == false {
            return ("„\(path)“ ist eine Datei, kein Ordner. Nimm „read“.",
                    false, "kein Ordner: \(path)")
        }
        guard let entries = try? SharedFolder.list(target) else {
            return ("Den Ordner „\(path.isEmpty ? label : path)“ gibt es nicht, oder er "
                    + "ließ sich nicht lesen.", false, "nicht lesbar: \(path)")
        }
        let here = path.isEmpty ? label : path
        guard !entries.isEmpty else {
            return (Self.fence("Der Ordner „\(here)“ ist leer.", source: here),
                    true, "\(here): leer")
        }

        let shown = entries.prefix(SharedFolder.maxEntries)
        var body = "Im Ordner „\(here)“ (\(entries.count) Einträge):\n"
            + shown.map(Self.line).joined(separator: "\n")
        if entries.count > shown.count {
            body += "\n\n[… \(entries.count - shown.count) weitere Einträge. "
                + "Nimm „find“, statt weiter aufzulisten.]"
        }
        return (Self.fence(body, source: here), true, "\(here): \(entries.count)")
    }

    private static func line(_ e: SharedFolder.Entry) -> String {
        guard !e.isDirectory else { return e.name + "/" }
        var parts: [String] = [e.name]
        if let bytes = e.bytes { parts.append(size(bytes)) }
        if let modified = e.modified { parts.append(day(modified)) }
        // Said on the entry and not in a footnote: it decides whether reading this is
        // free or a download, and the model chooses what to read from this line.
        if e.dataless { parts.append("noch nicht geladen") }
        return parts.joined(separator: " · ")
    }

    // MARK: find

    private func find(_ query: String, root: URL, label: String)
    -> (text: String, ok: Bool, summary: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return ("Fehler: Es wurde keine Suchanfrage übergeben.", false, "ohne Anfrage")
        }
        let hits = SharedFolder.find(q, under: root)
        guard !hits.isEmpty else {
            return (Self.fence("""
                Kein Dateiname im Ordner „\(label)“ enthält „\(q)“.

                Gesucht wird nur in Namen, nicht im Inhalt. Nimm ein kürzeres oder \
                anderes Wort, bevor du sagst, die Datei gebe es nicht.
                """, source: label), true, "0× \(q)")
        }
        let lines = hits.map { url -> String in
            let rel = SharedFolder.relativePath(of: url, under: root)
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return isDir ? rel + "/" : rel
        }
        var body = "\(hits.count) Treffer für „\(q)“ im Ordner „\(label)“:\n"
            + lines.joined(separator: "\n")
        if hits.count >= SharedFolder.maxMatches {
            body += "\n\n[Bei \(SharedFolder.maxMatches) Treffern abgebrochen — "
                + "es können mehr sein. Frag enger.]"
        }
        return (Self.fence(body, source: label), true, "\(hits.count)× \(q)")
    }

    // MARK: search — in the contents

    /// Reads what has changed, then searches.
    ///
    /// The reading happens here and nowhere else, and that is the decision this whole
    /// feature turns on. Doing it in the background on a timer would fetch files over
    /// the network that nobody asked about; doing it from a button in the settings
    /// makes a search silently answer from whatever somebody last remembered to press.
    /// Here it is the model asking, on behalf of a question that was just typed, and
    /// the user watches it happen.
    ///
    /// The budget is a wall clock. A folder read from cold can be minutes, and a turn
    /// that hangs for minutes is worse than an answer over part of the folder that says
    /// so — which is what `stoppedEarly` is for.
    private func search(_ query: String, root: URL, label: String,
                        onProgress: @escaping @Sendable (Int, Int) async -> Void) async
    -> (text: String, ok: Bool, summary: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return ("Fehler: Es wurde keine Suchanfrage übergeben.", false, "ohne Anfrage")
        }
        let read = await DocumentLibrary.shared.index(root: root, budget: 45,
                                                      onProgress: onProgress)
        let result = await DocumentLibrary.shared.search(q)

        guard !result.hits.isEmpty else {
            var body = result.indexed == 0
                ? "Im Ordner „\(label)“ ist kein lesbares Dokument."
                : "Keines der \(result.indexed) Dokumente im Ordner enthält „\(q)“."
            body += Self.coverage(read)
            body += "\n\nNimm ein anderes Wort, bevor du sagst, es stehe nirgends — "
                + "gesucht wird nach ganzen Wörtern und deren Anfängen."
            return (Self.fence(body, source: label), true, "0× \(q)")
        }

        var body = "\(result.hits.count) Fundstellen für „\(q)“ in "
            + "\(result.indexed) eingelesenen Dokumenten:\n"
        for hit in result.hits {
            let where_ = hit.locator.isEmpty ? "Abschnitt \(hit.block)"
                                             : "\(hit.locator), Abschnitt \(hit.block)"
            body += "\n\(hit.path) · \(where_)\n  \(hit.snippet)"
        }
        body += Self.coverage(read)
        body += "\n\n[Mehr davon: „read“ mit dem Pfad und der Abschnittsnummer.]"
        return (Self.fence(body, source: label), true, "\(result.hits.count)× \(q)")
    }

    // MARK: read

    private func read(_ path: String, block: Int?, root: URL, label: String) async
    -> (text: String, ok: Bool, summary: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("Fehler: Es wurde kein Pfad übergeben.", false, "ohne Pfad")
        }
        guard let target = SharedFolder.locate(trimmed, under: root) else {
            return (Self.refusal(trimmed), false, "abgewiesen: \(trimmed)")
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            return ("Die Datei „\(trimmed)“ gibt es im freigegebenen Ordner nicht. "
                    + "Sieh mit „list“ oder „find“ nach, wie sie wirklich heißt.",
                    false, "nicht da: \(trimmed)")
        }

        // Everything a parser here knows goes through the library, which answers from
        // the index when the file has not changed since it was read.
        if DocumentParser.canRead(trimmed) {
            if let document = await DocumentLibrary.shared.document(at: trimmed, url: target) {
                if let block {
                    guard let piece = document.render(block: block, path: trimmed) else {
                        return ("„\(trimmed)“ hat keinen Abschnitt \(block); es sind "
                                + "\(document.blocks.count). Lies ohne `block`, um zu sehen, "
                                + "welche es gibt.", false, "kein Abschnitt \(block)")
                    }
                    return (Self.fence(piece, source: trimmed), true,
                            "\(trimmed) · Abschnitt \(block)")
                }
                return (Self.fence(document.render(path: trimmed), source: trimmed), true,
                        "\(trimmed) · \(document.blocks.count) Abschnitte")
            }
        }

        // Not a format with a parser, or nothing came out of it. The byte-level reader
        // has the sentences for those cases — too large, binary, not downloaded.
        switch SharedFolder.read(target) {
        case .text(let text, let truncated):
            var body = text
            if truncated > 0 {
                body += "\n\n[… hier abgeschnitten, \(truncated) Zeichen fehlen.]"
            }
            return (Self.fence(body, source: trimmed), true,
                    "\(trimmed) · \(text.count) Zeichen")

        case .notText(let why):
            return ("\(why) Gelesen wurde „\(trimmed)“.", false, "kein Text: \(trimmed)")

        case .tooLarge(let bytes):
            return ("Die Datei „\(trimmed)“ ist mit \(Self.size(bytes)) zu groß zum Lesen "
                    + "(Grenze: \(Self.size(SharedFolder.maxBytes))).",
                    false, "zu groß: \(trimmed)")

        case .unreadable(let why):
            return ("„\(trimmed)“ ließ sich nicht lesen: \(why)", false,
                    "nicht lesbar: \(trimmed)")
        }
    }

    // MARK: Shared bits

    /// Said once and the same way every time.
    ///
    /// A refusal that explained itself differently per case would be a map of the
    /// boundary: try enough spellings and the differences say where the edge runs. The
    /// sentence also tells the model not to retry, because a model that reads "refused"
    /// without "and it will stay refused" tries three more spellings first.
    private static func refusal(_ path: String) -> String {
        """
        Der Pfad „\(path)“ führt aus dem freigegebenen Ordner heraus und wird nicht \
        gelesen. Nur was unterhalb dieses Ordners liegt, ist zugänglich — eine andere \
        Schreibweise ändert daran nichts.
        """
    }

    /// What the search actually looked at, when that is not the whole folder.
    ///
    /// Silent on the ordinary case — everything was already current, nothing to report
    /// — and explicit on the two that change what an absence of hits means.
    private static func coverage(_ read: DocumentLibrary.Progress) -> String {
        var notes: [String] = []
        if read.parsed > 0 { notes.append("\(read.parsed) neu eingelesen") }
        if read.stoppedEarly {
            notes.append("**nicht zu Ende gelesen** — die Zeit lief ab, ein Teil des "
                       + "Ordners ist noch nicht durchsucht")
        }
        guard !notes.isEmpty else { return "" }
        return "\n\n(" + notes.joined(separator: ", ") + ")"
    }

    private static func fence(_ text: String, source: String) -> String {
        UntrustedContent.wrap(text, source: source, origin: origin)
    }

    private static func size(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return unit == 0 ? "\(bytes) B"
                         : String(format: "%.1f %@", value, units[unit])
    }

    private static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02d.%02d.%02d", c.day ?? 0, c.month ?? 0, (c.year ?? 0) % 100)
    }
}
