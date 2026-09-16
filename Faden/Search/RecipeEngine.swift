import Foundation

struct SearchResult: Identifiable, Equatable, Codable {
    var id = UUID()
    var title: String
    var url: String
    var snippet: String
    var date: String?
    /// Publication name, when the provider gives one.
    var source: String?
    /// Further passages the provider returned for this hit.
    var extraText: [String] = []
    /// Which list this came from, e.g. "news" — lets the renderer group them.
    var section: String?
}

struct SearchOutcome: Equatable {
    var results: [SearchResult]
    var answer: String?
    /// Kept for the auto-configuration flow: the untouched body of the last call.
    var rawJSON: JSONValue?
    var statusCode: Int
}

enum SearchError: LocalizedError {
    case noRecipe
    case badURL
    case http(status: Int, body: String)
    case transport(String)
    /// The call succeeded but the recipe could not find results in the body.
    /// This is the case that offers auto-configuration.
    case unparsable(status: Int, raw: JSONValue?, rawText: String)

    var errorDescription: String? {
        switch self {
        case .noRecipe:          return String(localized: "Kein Suchanbieter eingerichtet.")
        case .badURL:            return String(localized: "Die URL des Suchanbieters ist ungültig.")
        case .http(let s, let b):
            let snippet = b.count > 300 ? String(b.prefix(300)) + "…" : b
            return String(localized: "Der Anbieter antwortete mit HTTP \(s).\n\(snippet)")
        case .transport(let m):  return String(localized: "Verbindungsfehler: \(m)")
        case .unparsable(let s, _, _):
            return String(localized: "Der Anbieter antwortete mit HTTP \(s), aber die Ergebnisse standen nicht dort, wo erwartet.")
        }
    }
}

/// Executes a `SearchRecipe` entirely on device. No model is involved here — the
/// model's contribution ended when it wrote the recipe.
struct RecipeEngine {

    static func fill(_ template: String, query: String, key: String, count: Int) -> String {
        template
            .replacingOccurrences(of: "{{query}}", with: query)
            .replacingOccurrences(of: "{{key}}", with: key)
            .replacingOccurrences(of: "{{count}}", with: String(count))
    }

    /// Builds the request a recipe describes. Exposed separately so the
    /// auto-configuration can fire the same request and inspect the raw answer.
    static func makeRequest(_ recipe: SearchRecipe, query: String, key: String, count: Int) throws -> URLRequest {
        let urlString = fill(recipe.url, query: query, key: key, count: count)
        guard var comps = URLComponents(string: urlString) else { throw SearchError.badURL }

        if recipe.method == .get {
            var items = comps.queryItems ?? []
            if let qp = recipe.queryParamName, !qp.isEmpty {
                items.append(URLQueryItem(name: qp, value: query))
            }
            for (k, v) in recipe.staticQueryItems.sorted(by: { $0.key < $1.key }) {
                items.append(URLQueryItem(name: k, value: fill(v, query: query, key: key, count: count)))
            }
            if case .queryParam(let name) = recipe.authStyle, !key.isEmpty {
                items.append(URLQueryItem(name: name, value: key))
            }
            comps.queryItems = items.isEmpty ? nil : items
        } else if case .queryParam(let name) = recipe.authStyle, !key.isEmpty {
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: name, value: key))
            comps.queryItems = items
        }

        guard let url = comps.url else { throw SearchError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = recipe.method.rawValue
        req.timeoutInterval = 30

        for (k, v) in recipe.headers {
            req.setValue(fill(v, query: query, key: key, count: count), forHTTPHeaderField: k)
        }
        if case .header(let name, let template) = recipe.authStyle, !key.isEmpty {
            req.setValue(fill(template, query: query, key: key, count: count), forHTTPHeaderField: name)
        }
        if recipe.method == .post {
            let raw = recipe.bodyTemplate ?? #"{"query":"{{query}}"}"#
            // The query must survive as valid JSON.
            let escaped = String(data: try JSONEncoder().encode(query), encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? query
            let filled = raw
                .replacingOccurrences(of: "{{query}}", with: escaped)
                .replacingOccurrences(of: "{{key}}", with: key)
                .replacingOccurrences(of: "{{count}}", with: String(count))
            req.httpBody = filled.data(using: .utf8)
            if req.value(forHTTPHeaderField: "content-type") == nil {
                req.setValue("application/json", forHTTPHeaderField: "content-type")
            }
        }
        return req
    }

    /// Runs a search. Throws `.unparsable` when the endpoint answered 200 but the
    /// response shape did not match — the signal that triggers auto-configuration.
    static func search(_ recipe: SearchRecipe, query: String, key: String, count: Int) async throws -> SearchOutcome {
        let req = try makeRequest(recipe, query: query, key: key, count: count)

        let data: Data, response: URLResponse
        do { (data, response) = try await Net.session.data(for: req) }
        catch { throw SearchError.transport(error.localizedDescription) }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200...299).contains(status) else { throw SearchError.http(status: status, body: text) }

        let json = JSONValue.decode(data)
        guard let json else { throw SearchError.unparsable(status: status, raw: nil, rawText: text) }

        let parsed = parse(json, with: recipe, limit: count)
        guard !parsed.results.isEmpty else {
            throw SearchError.unparsable(status: status, raw: json, rawText: text)
        }
        return SearchOutcome(results: parsed.results, answer: parsed.answer, rawJSON: json, statusCode: status)
    }

    /// Applies the response half of a recipe.
    static func parse(_ json: JSONValue, with recipe: SearchRecipe, limit: Int)
        -> (results: [SearchResult], answer: String?) {

        let answer = recipe.answerPath.flatMap { json.value(atPath: $0)?.stringValue }

        var results: [SearchResult] = []
        var seen = Set<String>()

        func harvest(_ path: String, section: String?, limit: Int) {
            guard let array = json.value(atPath: path)?.arrayValue else { return }
            for item in array {
                guard results.count < limit else { return }
                guard let r = makeResult(item, recipe: recipe, section: section) else { continue }
                guard seen.insert(r.url).inserted else { continue }
                results.append(r)
            }
        }

        // News and similar lists first: when a provider separates them out, they are
        // the timely ones, and a question that triggered a search usually wants those.
        for path in recipe.additionalResultPaths {
            harvest(path, section: path.split(separator: ".").first.map(String.init), limit: max(2, limit / 2))
        }
        harvest(recipe.resultsPath, section: nil, limit: limit)

        // A recipe may go stale when a provider reshapes its response; rather than
        // failing outright, look for the most result-like array in the body.
        if results.isEmpty, let discovered = discoverResultsArray(json) {
            for item in discovered.prefix(limit) {
                guard let r = makeResult(item, recipe: recipe, section: nil) else { continue }
                guard seen.insert(r.url).inserted else { continue }
                results.append(r)
            }
        }
        return (results, answer)
    }

    private static func makeResult(_ item: JSONValue, recipe: SearchRecipe, section: String?) -> SearchResult? {
        let title = firstString(item, recipe.titleKey, fallbacks: ["title", "name", "heading"])
        let url = firstString(item, recipe.urlKey, fallbacks: ["url", "link", "href", "displayUrl", "display_url"])
        guard let url, !url.isEmpty else { return nil }
        let snippet = firstString(item, recipe.snippetKey,
                                  fallbacks: ["description", "snippet", "content", "text", "summary", "excerpt"])
        let date = recipe.dateKey.flatMap { item.value(atPath: $0)?.stringValue }
        let source = recipe.sourceKey.flatMap { item.value(atPath: $0)?.stringValue }

        // The extra passages carry most of the substance — but also page furniture:
        // cookie banners, newsletter pitches, nav breadcrumbs. Passed on unfiltered
        // they crowd out the actual content and read to the model as noise.
        var extra: [String] = []
        if let key = recipe.extraTextKey, let arr = item.value(atPath: key)?.arrayValue {
            let cleanSnippet = cleanFragments((snippet ?? "").strippingHTML)
            var budget = 900
            for raw in arr {
                guard let rawText = raw.stringValue?.strippingHTML, rawText.count > 60 else { continue }
                guard !isBoilerplate(rawText) else { continue }
                let passage = cleanFragments(rawText)
                guard passage.count > 60 else { continue }
                // Skip what merely repeats the teaser, in either direction.
                guard !overlaps(passage, cleanSnippet) else { continue }
                guard !extra.contains(where: { overlaps(passage, $0) }) else { continue }
                let trimmed = passage.count > budget ? String(passage.prefix(budget)) + " …" : passage
                extra.append(trimmed)
                budget -= trimmed.count
                if budget <= 120 { break }
            }
        }

        return SearchResult(
            title: (title ?? url).strippingHTML,
            url: url,
            snippet: cleanFragments((snippet ?? "").strippingHTML),
            date: date,
            source: source?.strippingHTML,
            extraText: extra,
            section: section)
    }

    /// True when two passages say substantially the same thing — providers routinely
    /// return the teaser again as the first "extra" passage.
    private static func overlaps(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let (long, short) = a.count >= b.count ? (a, b) : (b, a)
        guard short.count >= 60 else { return false }
        // Comparing a solid chunk of the shorter one is enough and stays cheap.
        let probe = String(short.prefix(120))
        return long.contains(probe)
    }

    /// Search snippets are stitched from page fragments, joined by "…" or "·" — and
    /// the fragments at the front are often the site's banner rather than the article.
    /// Dropping the whole snippet would lose the real content sitting behind them, so
    /// the fragments are judged one by one.
    static func cleanFragments(_ text: String) -> String {
        let parts = text
            .components(separatedBy: "·")
            .flatMap { $0.components(separatedBy: "...") }
            .flatMap { $0.components(separatedBy: "…") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 25 }

        guard parts.count > 1 else { return text }
        let kept = parts.filter { !isAdFragment($0) }
        // If filtering leaves almost nothing, the judgement was probably wrong —
        // better a noisy snippet than an empty one.
        guard !kept.isEmpty, kept.joined().count >= text.count / 4 else { return text }
        return kept.joined(separator: " … ")
    }

    /// A single fragment that is banner, nav or promo rather than prose.
    private static func isAdFragment(_ fragment: String) -> Bool {
        let lower = fragment.lowercased()
        let markers = [
            "% off", "save up to", "tickets now", "buy tickets", "back by popular demand",
            "image credits", "photo by", "getty images", "subscribe", "newsletter",
            "sign up", "log in", "cookie", "all rights reserved", "terms of service",
            "abonnieren", "anmelden", "datenschutz", "impressum", "werbung",
            "enable javascript", "advertisement",
        ]
        return markers.contains { lower.contains($0) }
    }

    /// Page furniture rather than content: cookie notices, ticket ads, nav trails.
    private static func isBoilerplate(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "cookie", "newsletter", "subscribe", "sign up", "log in", "anmelden",
            "% off", "save up to", "tickets now", "buy tickets", "abonnieren",
            "all rights reserved", "terms of service", "datenschutz", "impressum",
            "javascript", "enable javascript", "browser wird nicht unterstützt",
        ]
        let hits = markers.filter { lower.contains($0) }.count
        if hits >= 2 { return true }

        // Long chains of "·" or "|" are navigation bars, not prose.
        let separators = text.filter { $0 == "·" || $0 == "|" }.count
        if separators >= 3, text.count < 400 { return true }
        if separators >= 5 { return true }

        // Mostly ellipses means stitched-together fragments with little to say.
        let ellipses = text.components(separatedBy: "...").count - 1
        if ellipses >= 4 { return true }

        return false
    }

    private static func firstString(_ item: JSONValue, _ key: String, fallbacks: [String]) -> String? {
        if let v = item.value(atPath: key)?.stringValue, !v.isEmpty { return v }
        for f in fallbacks {
            if let v = item.value(atPath: f)?.stringValue, !v.isEmpty { return v }
        }
        return nil
    }

    /// Depth-first scan for the array that most looks like a list of search hits.
    static func discoverResultsArray(_ json: JSONValue, depth: Int = 0) -> [JSONValue]? {
        guard depth < 5 else { return nil }
        if let arr = json.arrayValue, looksLikeResults(arr) { return arr }
        guard let obj = json.objectValue else { return nil }
        // Prefer conventionally named containers before scanning everything.
        let preferred = ["results", "web", "organic", "data", "items", "hits", "documents", "value"]
        for k in preferred {
            if let v = obj[k], let found = discoverResultsArray(v, depth: depth + 1) { return found }
        }
        for (_, v) in obj.sorted(by: { $0.key < $1.key }) {
            if let found = discoverResultsArray(v, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func looksLikeResults(_ arr: [JSONValue]) -> Bool {
        guard let first = arr.first?.objectValue, arr.count >= 1 else { return false }
        let keys = Set(first.keys.map { $0.lowercased() })
        let urlish = ["url", "link", "href", "display_url", "displayurl"]
        return urlish.contains { keys.contains($0) }
    }

    /// The dotted path at which an array lives — needed to write a recipe back.
    static func path(to target: [JSONValue], in json: JSONValue, prefix: String = "", depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }
        if let arr = json.arrayValue, arr.count == target.count, arr.first == target.first { return prefix }
        guard let obj = json.objectValue else { return nil }
        for (k, v) in obj.sorted(by: { $0.key < $1.key }) {
            let p = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let found = path(to: target, in: v, prefix: p, depth: depth + 1) { return found }
        }
        return nil
    }
}

extension String {
    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–",
        "&lsquo;": "‘", "&rsquo;": "’", "&ldquo;": "“", "&rdquo;": "”",
        "&laquo;": "«", "&raquo;": "»", "&bull;": "•", "&middot;": "·",
        "&euro;": "€", "&pound;": "£", "&copy;": "©", "&reg;": "®", "&trade;": "™",
        "&deg;": "°", "&times;": "×", "&divide;": "÷", "&szlig;": "ß",
        "&auml;": "ä", "&ouml;": "ö", "&uuml;": "ü",
        "&Auml;": "Ä", "&Ouml;": "Ö", "&Uuml;": "Ü",
    ]

    /// Strips markup and decodes entities.
    ///
    /// Search APIs mark up matches (`<strong>`) and escape punctuation, so a snippet
    /// arrives as `Apple&#x27;s`. Left as-is that reaches the model verbatim and ends
    /// up quoted back at the reader, so both numeric and named forms are decoded.
    var strippingHTML: String {
        // Collapsing all whitespace is right for a one-line snippet and wrong for a
        // whole page, where it would flatten the line structure that tells navigation
        // from prose. Page extraction uses `decodingEntities` instead.
        decodingEntities
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips tags and decodes entities, leaving line breaks intact.
    var decodingEntities: String {
        var s = replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        for (entity, char) in Self.namedEntities {
            if s.contains(entity) { s = s.replacingOccurrences(of: entity, with: char) }
        }

        // Numeric entities: &#39; and &#x27;
        if s.contains("&#") {
            let pattern = "&#(x[0-9a-fA-F]+|[0-9]+);"
            if let re = try? NSRegularExpression(pattern: pattern) {
                var out = ""
                var last = s.startIndex
                let full = NSRange(s.startIndex..., in: s)
                for m in re.matches(in: s, range: full) {
                    guard let whole = Range(m.range, in: s),
                          let digits = Range(m.range(at: 1), in: s) else { continue }
                    out += s[last..<whole.lowerBound]
                    let token = String(s[digits])
                    let value = token.hasPrefix("x") || token.hasPrefix("X")
                        ? UInt32(token.dropFirst(), radix: 16)
                        : UInt32(token)
                    if let value, let scalar = Unicode.Scalar(value) {
                        out.append(Character(scalar))
                    } else {
                        out += s[whole]
                    }
                    last = whole.upperBound
                }
                out += s[last...]
                s = out
            }
        }

        // Horizontal runs only — newlines survive.
        return s
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
