import Foundation

// MARK: - The foreign schema

/// An identifier that stands on a thing: the EAN under a barcode, a manufacturer part
/// number on a board.
///
/// `scanned` is the field that earns its place. iOS decodes a barcode with its check
/// digit and is exact; a number a model read off a blurred label is a guess in which a
/// single confused character points at a different component. Fundus keeps the two
/// apart, and a reader that flattened them would undo that work at the last step —
/// right before the number is read aloud to somebody standing in front of the shelf.
struct FundusCode: Equatable {
    var value: String
    var kind: String
    var scanned: Bool

    /// The same words Fundus writes on the entry, so the answer and the app agree.
    var label: String {
        switch kind {
        case "ean", "upc":    return kind.uppercased()
        case "qr":            return "QR"
        case "dataMatrix":    return "DataMatrix"
        case "code128":       return "Code 128"
        case "manufacturer":  return "Herstellernummer"
        case "serial":        return "Seriennummer"
        default:              return "Kennung"
        }
    }
}

/// A thing in the Fundus inventory, as far as Faden needs it.
///
/// A second, narrower copy of a model that already exists in another app. Deliberate,
/// for the reason the architecture gives for the two string catalogues: sharing it
/// would be worth a library, and until that library exists, duplicated code beats a
/// build dependency between two apps that ship separately.
///
/// Narrower is the point, not an omission. `inventory.json` carries an embedding vector
/// per item — a few hundred floats — plus photo references and provenance timestamps,
/// none of which Faden can do anything with. What is not named here is parsed and
/// dropped rather than held for the life of the app.
struct FundusItem: Identifiable, Equatable {
    var id: UUID
    var name: String
    /// `nil` does not mean zero but uncounted — a box of screws, a reel of wire. It is
    /// rendered as nothing rather than as a number, and the tool description says why.
    var quantity: Int?
    var unit: String
    var note: String
    var placeID: UUID?
    var tags: [String]
    var code: FundusCode?
    /// When somebody last confirmed this thing with their own eyes.
    var lastSeenAt: Date?

    /// For matching: capitalisation, accents and repeated spaces must not decide
    /// whether a thing is found. Mirrors `Item.normalise` in Fundus.
    static func normalise(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct FundusPlace: Identifiable, Equatable {
    var id: UUID
    var name: String
    var parentID: UUID?
}

/// What Fundus keeps in `inventory.json`.
struct FundusInventory: Equatable {
    var items: [FundusItem] = []
    var places: [FundusPlace] = []

    var isEmpty: Bool { items.isEmpty && places.isEmpty }
}

// MARK: - Decoding

/// Missing is fine, and so is the wrong type.
///
/// Faden reads a file another app writes, and the two are updated separately: a device
/// can carry a Fundus newer than this build. A field that has changed shape in the
/// meantime must cost that field, not the inventory.
private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// An element that may fail without taking the array with it.
private struct Skippable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension FundusCode: Decodable {
    private enum Key: String, CodingKey { case value, kind, origin }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        value = c.lenient(String.self, .value) ?? ""
        kind = c.lenient(String.self, .kind) ?? "unknown"
        // Anything that is not literally "scanned" counts as read, and therefore as
        // fallible. The safe side of an unknown value is the cautious one.
        scanned = (c.lenient(String.self, .origin) ?? "read") == "scanned"
    }
}

extension FundusItem: Decodable {
    private enum Key: String, CodingKey {
        case id, name, quantity, unit, note, placeID, tags, code, lastSeenAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = c.lenient(UUID.self, .id) ?? UUID()
        name = c.lenient(String.self, .name) ?? ""
        quantity = c.lenient(Int.self, .quantity)
        unit = c.lenient(String.self, .unit) ?? ""
        note = c.lenient(String.self, .note) ?? ""
        placeID = c.lenient(UUID.self, .placeID)
        tags = c.lenient([String].self, .tags) ?? []
        code = c.lenient(FundusCode.self, .code)
        lastSeenAt = c.lenient(Date.self, .lastSeenAt)
    }
}

extension FundusPlace: Decodable {
    private enum Key: String, CodingKey { case id, name, parentID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = c.lenient(UUID.self, .id) ?? UUID()
        name = c.lenient(String.self, .name) ?? ""
        parentID = c.lenient(UUID.self, .parentID)
    }
}

extension FundusInventory: Decodable {
    private enum Key: String, CodingKey { case items, places }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        items = (c.lenient([Skippable<FundusItem>].self, .items) ?? [])
            .compactMap(\.value)
            // An entry without a name is one Fundus would not show either.
            .filter { !$0.name.isEmpty }
        places = (c.lenient([Skippable<FundusPlace>].self, .places) ?? [])
            .compactMap(\.value)
    }

    static func decode(_ data: Data) -> FundusInventory? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(FundusInventory.self, from: data)
    }
}

// MARK: - Places

extension FundusInventory {

    /// The path of a place, from the top: "Keller › Regal links".
    ///
    /// The walk is capped and remembers where it has been. A `parentID` chain is a tree
    /// only as long as the file is sound — one cycle in a hand-edited or half-written
    /// file would otherwise hang the turn, and a hung turn looks like a broken model.
    func path(of placeID: UUID?) -> String? { path(of: placeID, in: indexed) }

    /// The variant that takes the index it walks. Every caller here asks for a path per
    /// item or per place, and `indexed` builds a dictionary each time it is read — one
    /// per entry, over a list that can run to a few thousand.
    private func path(of placeID: UUID?, in byID: [UUID: FundusPlace]) -> String? {
        guard let placeID, let place = byID[placeID] else { return nil }
        var parts = [place.name]
        var seen: Set<UUID> = [placeID]
        var cursor = place.parentID
        while let id = cursor, !seen.contains(id), parts.count < 12, let p = byID[id] {
            parts.append(p.name)
            seen.insert(id)
            cursor = p.parentID
        }
        return parts.reversed().joined(separator: " › ")
    }

    var indexed: [UUID: FundusPlace] {
        Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// A place and everything below it. A room holds shelves, and somebody asking about
    /// the cellar means the cellar's boxes too.
    func subtree(of placeID: UUID) -> Set<UUID> {
        var children: [UUID: [UUID]] = [:]
        for p in places { if let parent = p.parentID { children[parent, default: []].append(p.id) } }

        var out: Set<UUID> = [placeID]
        var queue = [placeID]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where !out.contains(child) {
                out.insert(child)
                queue.append(child)
            }
        }
        return out
    }

    /// The places a name could mean. More than one is a real answer, not an error —
    /// "Regal" can stand in the cellar and in the workshop, and guessing which one was
    /// meant is how a wrong shelf ends up in an answer that sounds certain.
    func places(matching needle: String) -> [FundusPlace] {
        let wanted = FundusItem.normalise(needle)
        guard !wanted.isEmpty else { return [] }
        let exact = places.filter { FundusItem.normalise($0.name) == wanted }
        if !exact.isEmpty { return exact }

        // Against the full path, word by word, so that "Keller Regal" finds what
        // "Regal" alone leaves ambiguous. The separator comes out first: it is ours,
        // not part of any name, and a model that writes the path without it has still
        // named the place correctly.
        let tokens = wanted.split(separator: " ").map(String.init)
        let byID = indexed
        let matched = places.filter { p in
            let haystack = FundusItem.normalise(
                (path(of: p.id, in: byID) ?? p.name).replacingOccurrences(of: "›", with: " "))
            return tokens.allSatisfy(haystack.contains)
        }
        return withoutDescendants(of: matched, in: byID)
    }

    /// Drops matches that already lie inside another match.
    ///
    /// Matching against the path means a name high up in the tree matches everything
    /// below it as well. For the search that changes nothing — the subtree covers them
    /// either way — but the answer would name both, and "in the cellar and in the
    /// cellar's left shelf" reads as though two places had been searched.
    private func withoutDescendants(of matched: [FundusPlace],
                                    in byID: [UUID: FundusPlace]) -> [FundusPlace] {
        guard matched.count > 1 else { return matched }
        let ids = Set(matched.map(\.id))
        return matched.filter { p in
            var seen: Set<UUID> = [p.id]
            var cursor = p.parentID
            while let id = cursor, !seen.contains(id) {
                if ids.contains(id) { return false }
                seen.insert(id)
                cursor = byID[id]?.parentID
            }
            return true
        }
    }

    func itemCount(in placeID: UUID) -> Int {
        let ids = subtree(of: placeID)
        return items.filter { $0.placeID.map(ids.contains) ?? false }.count
    }
}

// MARK: - Searching

extension FundusInventory {

    struct Hit: Equatable {
        var item: FundusItem
        var path: String?
        var score: Int
    }

    /// What a search came back with, before any of it is turned into text.
    struct Lookup: Equatable {
        var hits: [Hit]
        /// Before the limit was applied.
        var total: Int
        /// The places the filter resolved to, in case the answer should name them.
        var places: [String]
    }

    /// Lexical, and it says so.
    ///
    /// Fundus searches its own inventory semantically, with an embedding per entry.
    /// Faden could not do that here without a second embedding endpoint and a key for
    /// it, and a search that silently compares between two different vector spaces is
    /// worse than one that plainly matches words. So: normalised substrings, every word
    /// of the query has to land somewhere, and where it lands decides the rank.
    ///
    /// An empty query with a place is not a degenerate case but the common one — "what
    /// is in the cellar" is a listing, not a search.
    func search(_ query: String, place: String? = nil, limit: Int = 50) -> Lookup {
        var pool = items
        var placeNames: [String] = []

        if let place, !place.trimmingCharacters(in: .whitespaces).isEmpty {
            let matched = places(matching: place)
            placeNames = matched.compactMap { path(of: $0.id) }
            guard !matched.isEmpty else { return Lookup(hits: [], total: 0, places: []) }
            let ids = matched.reduce(into: Set<UUID>()) { $0.formUnion(subtree(of: $1.id)) }
            pool = pool.filter { $0.placeID.map(ids.contains) ?? false }
        }

        let tokens = FundusItem.normalise(query)
            .split(separator: " ").map(String.init)

        let byID = indexed
        var scored: [Hit] = []
        for item in pool {
            let score = tokens.isEmpty ? 1 : Self.score(item, tokens: tokens)
            guard score > 0 else { continue }
            scored.append(Hit(item: item, path: path(of: item.placeID, in: byID), score: score))
        }

        scored.sort {
            $0.score != $1.score ? $0.score > $1.score
                                 : $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending
        }
        return Lookup(hits: Array(scored.prefix(max(1, limit))),
                      total: scored.count, places: placeNames)
    }

    /// Zero means the item is not an answer at all: every word of the query has to land
    /// somewhere. Without that rule a two-word query returns everything that matches
    /// either word, and the list stops meaning anything at the third entry.
    private static func score(_ item: FundusItem, tokens: [String]) -> Int {
        let name = FundusItem.normalise(item.name)
        let words = name.split(separator: " ").map(String.init)
        let note = FundusItem.normalise(item.note)
        let tags = item.tags.map(FundusItem.normalise)
        let code = FundusItem.normalise(item.code?.value ?? "")

        var total = 0
        for token in tokens {
            var best = 0
            if name == token { best = 6 }
            else if words.contains(where: { $0.hasPrefix(token) }) { best = 5 }
            else if name.contains(token) { best = 4 }
            // A number is the most specific thing an entry carries: whoever types
            // "MP1584EN" wants that part and nothing similar to it.
            if !code.isEmpty, code.contains(token) { best = max(best, 5) }
            if tags.contains(token) { best = max(best, 4) }
            else if tags.contains(where: { $0.contains(token) }) { best = max(best, 3) }
            if best == 0, note.contains(token) { best = 2 }
            guard best > 0 else { return 0 }
            total += best
        }
        return total
    }
}

// MARK: - Rendering

extension FundusInventory {

    /// The places, with how much stands in each.
    ///
    /// The counts are the useful half: they tell the model where looking is worth it,
    /// which is what turns a second call into a targeted one instead of a broad one.
    func renderPlaces() -> String {
        guard !places.isEmpty else {
            return items.isEmpty
                ? "Das Inventar ist leer."
                : "Im Inventar sind keine Orte angelegt. \(items.count) Dinge liegen ohne Ort darin."
        }
        let byID = indexed
        let lines = places
            .compactMap { p -> (String, Int)? in
                path(of: p.id, in: byID).map { ($0, itemCount(in: p.id)) }
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            .map { "\($0.0) (\($0.1))" }

        var out = "Orte im Inventar (\(places.count)), in Klammern die Zahl der Dinge "
            + "darin, Unterorte eingerechnet:\n" + lines.joined(separator: "\n")
        let unplaced = items.filter { $0.placeID == nil }.count
        if unplaced > 0 { out += "\n\nOhne Ort: \(unplaced)" }
        return out
    }

    /// One line per thing, and a header that says what was left out.
    ///
    /// Saying how many were cut, and by what to narrow, is what keeps the model from
    /// answering "you have twelve" off a list that was capped at ten.
    static func render(_ lookup: Lookup, query: String, place: String?) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        let asked = place?.trimmingCharacters(in: .whitespaces)

        // The place Fundus knows rather than the one that was typed, when the two
        // differ: "in „Keller › Regal links“" tells the reader which shelf was meant,
        // and a header that echoed "Regal" would not.
        var atPlace = ""
        if let asked, !asked.isEmpty {
            atPlace = lookup.places.isEmpty
                ? " in „\(asked)“"
                : " in " + lookup.places.map { "„\($0)“" }.joined(separator: " und ")
        }
        // Without a query this is a listing, and a listing has no subject to be "about"
        // — "Einträge zu Dinge in „Keller“" is what happens when one sentence has to
        // carry both cases.
        let scope = q.isEmpty ? (atPlace.isEmpty ? " im Bestand" : atPlace)
                              : " zu „\(q)“" + atPlace

        guard !lookup.hits.isEmpty else {
            return q.isEmpty
                ? "Im Bestand steht nichts\(atPlace)."
                : "Nichts im Inventar passt auf „\(q)“\(atPlace)."
        }

        var out = lookup.total > lookup.hits.count
            ? "\(lookup.total) Einträge\(scope), die \(lookup.hits.count) passendsten:"
            : "\(lookup.total) \(lookup.total == 1 ? "Eintrag" : "Einträge")\(scope):"
        out += "\n" + lookup.hits.map(line).joined(separator: "\n")

        if lookup.total > lookup.hits.count {
            out += "\n\n[… \(lookup.total - lookup.hits.count) weitere. Frag enger — "
                + "mit einem Ort oder einem genaueren Begriff.]"
        }
        return out
    }

    private static func line(_ hit: Hit) -> String {
        var parts: [String] = []
        parts.append(hit.item.name)
        if let amount = amount(hit.item) { parts.append(amount) }
        if !hit.item.note.isEmpty {
            let n = hit.item.note.replacingOccurrences(of: "\n", with: " ")
            parts.append(n.count > 70 ? String(n.prefix(70)) + "…" : n)
        }
        if let code = hit.item.code, !code.value.isEmpty {
            // "abgelesen" is not decoration. It is the difference between a number
            // worth searching for and one worth checking first.
            parts.append("\(code.label) \(code.value)\(code.scanned ? "" : " (abgelesen)")")
        }
        if let seen = hit.item.lastSeenAt { parts.append("bestätigt \(day(seen))") }

        return "\(hit.path ?? "ohne Ort") — " + parts.joined(separator: " · ")
    }

    /// Quantity and unit as they stand on one line — and nothing at all when the
    /// quantity is missing. An invented 1 would be a number that looks like a count.
    private static func amount(_ item: FundusItem) -> String? {
        guard let q = item.quantity else { return item.unit.isEmpty ? nil : item.unit }
        return item.unit.isEmpty ? "\(q)×" : "\(q) \(item.unit)"
    }

    /// Built from components rather than a `DateFormatter`: this runs per line, and the
    /// format has to be the same in both app languages — it is a stamp, not prose.
    private static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02d.%02d.%02d", c.day ?? 0, c.month ?? 0, (c.year ?? 0) % 100)
    }
}

// MARK: - Reading it

/// Reads Fundus's inventory, and no more often than it has to.
///
/// The cache is not premature. A model that is asked where something is calls this two
/// or three times in one turn — once for the places, then for a search, then narrowed —
/// and the file carries an embedding vector per entry, so it is the largest thing
/// either app writes. Re-reading and re-parsing it three times a turn would be paid for
/// in the seconds before an answer appears.
///
/// Fundus writes atomically, so there is no half file to catch. What the modification
/// date does catch is the ordinary case: Fundus was in the foreground a moment ago and
/// the user is now asking Faden about what they just entered.
actor FundusReader {
    static let shared = FundusReader()

    private var cached: FundusInventory?
    private var stamp: Date?

    func inventory() -> FundusInventory {
        guard let url = SharedContainer.fundusInventoryURL else { return FundusInventory() }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        if let cached, stamp == modified { return cached }

        guard let data = try? Data(contentsOf: url),
              let inventory = FundusInventory.decode(data) else {
            // Not cached: a file that cannot be read today is usually one that is being
            // written right now, and the next call should look again.
            return FundusInventory()
        }
        cached = inventory
        stamp = modified
        return inventory
    }

    /// Drops the cache. For the settings screen, which asks after the user has been in
    /// Fundus and wants the figure it shows to be the current one.
    func forget() {
        cached = nil
        stamp = nil
    }
}

extension FundusInventory {
    /// Whether there is anything to read at all.
    ///
    /// A `stat` call, and therefore cheap enough for the places that ask it — the token
    /// estimate recomputes it on every turn, and caching a filesystem fact would only
    /// buy a stale answer the first time Fundus is installed.
    static var isPresent: Bool {
        guard let url = SharedContainer.fundusInventoryURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
