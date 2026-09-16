import Foundation

/// Progress messages the setup sheet shows while the endpoint is being learned.
enum SynthesisStep: Equatable {
    case probing(String)
    case gotResponse(status: Int, bytes: Int)
    case asking(model: String)
    case validating
    case success(resultCount: Int)
    case failed(String)

    var text: String {
        switch self {
        case .probing(let what):        return "Probiere \(what) …"
        case .gotResponse(let s, let b):return "HTTP \(s), \(b) Bytes empfangen."
        case .asking(let m):            return "\(m) liest die Antwortstruktur …"
        case .validating:               return "Prüfe den erzeugten Parser lokal …"
        case .success(let n):           return "Fertig — \(n) Treffer über den neuen Parser."
        case .failed(let m):            return m
        }
    }
}

/// Why a synthesis attempt did not produce a usable recipe.
struct SynthesisFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Turns an unknown search endpoint into a `SearchRecipe`.
///
/// Two stages. First the app probes request shapes on its own until the endpoint
/// answers 200 — plain HTTP work, no model involved. Then the 200 body is condensed
/// into a structural digest and handed to the chosen model, which writes the recipe.
/// The recipe is validated locally against that same body before it is kept, so a
/// bad answer from the model cannot be saved. Afterwards every search runs from the
/// stored recipe on device.
struct RecipeSynthesizer {

    let config: LLMConfig
    let apiKey: String

    /// Probe order: the shapes real search APIs actually use.
    static func candidates(from base: SearchRecipe) -> [SearchRecipe] {
        var out: [SearchRecipe] = []
        let hasKey = true

        func variant(_ mutate: (inout SearchRecipe) -> Void) -> SearchRecipe {
            var r = base; mutate(&r); return r
        }

        // What the user typed, first — it may simply be right.
        if !base.url.isEmpty { out.append(base) }

        if hasKey {
            let authStyles: [AuthStyle] = [
                .header(name: "Authorization", valueTemplate: "Bearer {{key}}"),
                .header(name: "X-API-KEY", valueTemplate: "{{key}}"),
                .header(name: "x-api-key", valueTemplate: "{{key}}"),
                .header(name: "X-Subscription-Token", valueTemplate: "{{key}}"),
                .header(name: "Authorization", valueTemplate: "{{key}}"),
                .queryParam(name: "api_key"),
                .queryParam(name: "key"),
                .queryParam(name: "token"),
                .none,
            ]
            let queryParams = ["q", "query", "search", "text"]

            for auth in authStyles {
                for qp in queryParams {
                    out.append(variant {
                        $0.method = .get
                        $0.authStyle = auth
                        $0.queryParamName = qp
                        $0.headers["Accept"] = "application/json"
                    })
                }
            }
            // POST shapes
            let bodies = [
                #"{"query":"{{query}}"}"#,
                #"{"q":"{{query}}"}"#,
                #"{"query":"{{query}}","max_results":{{count}}}"#,
                #"{"query":"{{query}}","api_key":"{{key}}"}"#,
            ]
            for auth in authStyles.prefix(5) {
                for body in bodies {
                    out.append(variant {
                        $0.method = .post
                        $0.authStyle = auth
                        $0.queryParamName = nil
                        $0.bodyTemplate = body
                        $0.headers["Content-Type"] = "application/json"
                        $0.headers["Accept"] = "application/json"
                    })
                }
            }
        }
        return out
    }

    /// Stage one: hunt for a request shape that returns 200 with a JSON body.
    static func probe(
        base: SearchRecipe, key: String, probe query: String, count: Int,
        onStep: @MainActor @escaping (SynthesisStep) -> Void
    ) async -> (recipe: SearchRecipe, json: JSONValue, bytes: Int)? {

        for candidate in candidates(from: base) {
            let label = "\(candidate.method.rawValue) · \(candidate.authStyle.describe)"
            await onStep(.probing(label))

            guard let req = try? RecipeEngine.makeRequest(candidate, query: query, key: key, count: count),
                  let (data, resp) = try? await Net.session.data(for: req),
                  let http = resp as? HTTPURLResponse
            else { continue }

            guard (200...299).contains(http.statusCode) else { continue }
            guard let json = JSONValue.decode(data) else { continue }
            // A 200 that carries no array anywhere is not a search response.
            guard RecipeEngine.discoverResultsArray(json) != nil || json.objectValue != nil else { continue }

            await onStep(.gotResponse(status: http.statusCode, bytes: data.count))
            return (candidate, json, data.count)
        }
        return nil
    }

    /// Condense a response into something small enough to reason about: keys are kept,
    /// values are truncated, arrays are cut to two entries, depth is capped.
    static func digest(_ v: JSONValue, depth: Int = 0) -> JSONValue {
        guard depth < 6 else { return .string("…") }
        switch v {
        case .string(let s):
            return .string(s.count > 100 ? String(s.prefix(100)) + "…" : s)
        case .array(let a):
            return .array(a.prefix(2).map { digest($0, depth: depth + 1) })
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, val) in o.prefix(40) { out[k] = digest(val, depth: depth + 1) }
            if o.count > 40 { out["…"] = .string("\(o.count - 40) weitere Felder") }
            return .object(out)
        default:
            return v
        }
    }

    private static let systemPrompt = """
    Du analysierst die JSON-Antwort einer Websuch-API und beschreibst, wo die \
    Ergebnisse stehen. Antworte ausschließlich mit einem JSON-Objekt, ohne Markdown, \
    ohne Erklärung, mit genau diesen Feldern:

    {
      "resultsPath": "Punkt-Pfad zum Array der Treffer, z. B. \\"web.results\\" oder \\"organic\\"",
      "titleKey":    "Feldname für den Titel innerhalb eines Treffers",
      "urlKey":      "Feldname für die URL innerhalb eines Treffers",
      "snippetKey":  "Feldname für den Textauszug innerhalb eines Treffers",
      "dateKey":     "Feldname für das Datum, oder null",
      "answerPath":  "Punkt-Pfad zu einer vorformulierten Antwort des Anbieters, oder null"
    }

    Regeln:
    - Pfade sind relativ zur Wurzel der Antwort und mit Punkten getrennt.
    - Feldnamen (titleKey usw.) sind relativ zu einem einzelnen Treffer und dürfen \
    ebenfalls Punkte enthalten, falls sie verschachtelt sind (z. B. "meta.title").
    - Wähle für snippetKey das Feld mit dem längsten beschreibenden Text.
    - Erfinde keine Felder. Nutze nur, was in der gezeigten Struktur wirklich vorkommt.
    """

    /// Stage two: let the model read the digest and write the response half of the recipe.
    func synthesize(
        base: SearchRecipe, json: JSONValue,
        onStep: @MainActor @escaping (SynthesisStep) -> Void
    ) async -> Result<SearchRecipe, SynthesisFailure> {

        await onStep(.asking(model: config.model))

        let d = Self.digest(json)
        let pretty = (try? JSONEncoder.pretty.encode(d)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let provider = ProviderFactory.make(for: config.wireFormat)

        var attempt = 0
        var lastProblem: String?

        while attempt < 2 {
            attempt += 1
            var built = "Struktur der Antwort:\n```json\n\(pretty)\n```"
            if let lastProblem {
                built += "\n\nDein vorheriger Vorschlag hat nicht funktioniert: \(lastProblem)\n"
                    + "Sieh dir die Struktur erneut an und liefere korrigierte Pfade."
            }
            let prompt = built

            let reply: String
            do {
                // Generous on purpose: the answer itself is a few lines of JSON, but a
                // reasoning model spends most of its allowance thinking first and
                // returns nothing at all if the budget runs out before it writes.
                reply = try await withTimeout(seconds: 120) {
                    try await provider.complete(
                        messages: [Message(role: .user, text: prompt)],
                        system: Self.systemPrompt,
                        config: config, apiKey: apiKey,
                        maxTokens: max(4000, min(8000, config.maxOutputTokens)))
                }
            } catch {
                return .failure(SynthesisFailure(message: "Das Modell war nicht erreichbar: \(error.localizedDescription)"))
            }

            guard let spec = Self.extractJSONObject(reply) else {
                lastProblem = "Die Antwort war kein JSON-Objekt."
                continue
            }

            var recipe = base
            recipe.resultsPath = spec["resultsPath"]?.stringValue ?? ""
            recipe.titleKey    = spec["titleKey"]?.stringValue ?? "title"
            recipe.urlKey      = spec["urlKey"]?.stringValue ?? "url"
            recipe.snippetKey  = spec["snippetKey"]?.stringValue ?? "description"
            recipe.dateKey     = spec["dateKey"]?.stringValue
            recipe.answerPath  = spec["answerPath"]?.stringValue
            recipe.synthesizedBy = config.model
            recipe.synthesizedAt = Date()

            // Validate against the very body the recipe was written for.
            await onStep(.validating)
            let parsed = RecipeEngine.parse(json, with: recipe, limit: 10)
            if parsed.results.isEmpty {
                lastProblem = "Unter \"\(recipe.resultsPath)\" standen keine Treffer mit einer URL."
                continue
            }
            // A URL alone is not enough: when the title field does not exist, the
            // engine falls back to showing the URL as the title, and the recipe
            // would be quietly saved half-wrong.
            let titled = parsed.results.filter { !$0.title.isEmpty && $0.title != $0.url }
            if titled.isEmpty {
                lastProblem = "Das Feld \"\(recipe.titleKey)\" gibt es in den Treffern nicht — "
                    + "dort stand kein Titel. Nenne das Feld, das den Titel wirklich enthält."
                continue
            }
            let described = parsed.results.filter { !$0.snippet.isEmpty }
            if described.isEmpty {
                lastProblem = "Das Feld \"\(recipe.snippetKey)\" gibt es in den Treffern nicht — "
                    + "dort stand kein Text. Nenne das Feld mit dem beschreibenden Text."
                continue
            }
            await onStep(.success(resultCount: parsed.results.count))
            return .success(recipe)
        }

        return .failure(SynthesisFailure(message: lastProblem ?? "Der Parser ließ sich nicht ableiten."))
    }

    /// Models sometimes wrap JSON in prose or a fence; take the outermost object.
    static func extractJSONObject(_ s: String) -> [String: JSONValue]? {
        if let data = s.data(using: .utf8), let o = JSONValue.decode(data)?.objectValue { return o }
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { inString.toggle() }
            else if !inString {
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        let sub = String(s[start...i])
                        return sub.data(using: .utf8).flatMap { JSONValue.decode($0)?.objectValue }
                    }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
