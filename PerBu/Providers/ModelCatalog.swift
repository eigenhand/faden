import Foundation

/// One model as an endpoint describes it.
/// Ein Modell, wie ein Endpoint es beschreibt.
///
/// `Codable`, seit die Liste eines Anbieters aufbewahrt wird: die Rollen — Haupt,
/// Ausweich, Vision, Vision-Ausweich — werden daraus gewählt, und dafür jedes Mal
/// den Endpoint zu fragen hiesse, dass die Auswahl ohne Netz nicht aufgeht.
struct RemoteModel: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var displayName: String?
    var contextLength: Int?
    var maxOutput: Int?
    var owner: String?
    /// Formatted price per million input/output tokens, when the endpoint says.
    var pricing: String?
    /// Was die Liste über die Fähigkeiten sagt — oft nichts. Siehe `Capabilities`.
    var capabilities = Capabilities()

    var title: String { displayName ?? id }

    /// One line of stats for the list, empty when the endpoint told us nothing.
    var stats: String {
        var parts: [String] = []
        if let c = contextLength { parts.append("\(Self.compact(c)) Kontext") }
        if let m = maxOutput { parts.append("\(Self.compact(m)) Ausgabe") }
        if let p = pricing { parts.append(p) }
        if let o = owner, parts.isEmpty { parts.append(o) }
        return parts.joined(separator: " · ")
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return "\(n / 1_000_000) M"
        case 1_000...:     return "\(n / 1_000) k"
        default:           return "\(n)"
        }
    }
}

/// Reads the model list from an endpoint, and works out token limits even when the
/// endpoint does not publish them.
enum ModelCatalog {

    // MARK: Listing

    static func fetch(config: LLMConfig, apiKey: String) async throws -> [RemoteModel] {
        // Apples Modell hat keine Modellliste — es ist genau eines, und ob es da ist,
        // sagt das System und nicht eine Abfrage.
        guard config.wireFormat.needsEndpoint else { throw LLMError.notConfigured }
        guard let base = config.endpointURL else { throw LLMError.notConfigured }
        // The list lives next to the chat path: …/v1/chat/completions -> …/v1/models
        var url = base.deletingLastPathComponent()
        if url.lastPathComponent == "chat" { url = url.deletingLastPathComponent() }
        url = url.appendingPathComponent("models")

        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        switch config.wireFormat {
        case .anthropic:
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue(AnthropicProvider.version, forHTTPHeaderField: "anthropic-version")
        case .openai:
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        case .appleOnDevice:
            break  // oben schon ausgestiegen; der Fall steht hier nur fuer den Compiler
        }
        for (k, v) in config.extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await Net.session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw LLMError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = JSONValue.decode(data) else { throw LLMError.decoding("Keine JSON-Liste.") }

        // Both shapes put the array under `data`; some proxies return a bare array.
        let items = json["data"]?.arrayValue ?? json.arrayValue ?? []
        let models = items.compactMap(parse)
        guard !models.isEmpty else { throw LLMError.decoding("Die Liste enthielt keine Modelle.") }
        return models.sorted { $0.id < $1.id }
    }

    /// Field names differ per vendor, so every known spelling is tried.
    private static func parse(_ v: JSONValue) -> RemoteModel? {
        guard let id = v["id"]?.stringValue ?? v["name"]?.stringValue else { return nil }
        var m = RemoteModel(id: id)
        m.displayName = v["display_name"]?.stringValue
        m.owner = v["owned_by"]?.stringValue ?? v["organization"]?.stringValue
        m.capabilities = capabilities(from: v)

        for key in ["context_length", "max_input_tokens", "context_window", "max_context_length"] {
            if let n = int(v[key]) { m.contextLength = n; break }
        }
        if m.contextLength == nil, let n = int(v["top_provider"]?["context_length"]) {
            m.contextLength = n
        }
        for key in ["max_output_tokens", "max_tokens", "max_completion_tokens"] {
            if let n = int(v[key]) { m.maxOutput = n; break }
        }
        if m.maxOutput == nil, let n = int(v["top_provider"]?["max_completion_tokens"]) {
            m.maxOutput = n
        }
        if let p = v["pricing"]?.objectValue,
           let pin = p["prompt"]?.stringValue.flatMap(Double.init),
           let pout = p["completion"]?.stringValue.flatMap(Double.init) {
            let inM = pin * 1_000_000, outM = pout * 1_000_000
            if inM > 0 || outM > 0 {
                m.pricing = String(format: "$%.2f/$%.2f pro M", inM, outM)
            }
        }
        return m
    }

    /// Die Fähigkeiten, wie sie in den drei gängigen Schreibweisen dastehen.
    ///
    /// Es gibt keinen Standard dafür, und das ist der ganze Aufwand hier. LiteLLM und
    /// die Häuser, die es einsetzen, schreiben `supports_vision` als Boolean.
    /// OpenRouter beschreibt stattdessen, was hineingeht (`architecture`
    /// `input_modalities` mit „image") und welche Parameter die Anfrage annimmt
    /// (`supported_parameters` mit „tools" oder „reasoning"). Andere hängen alles
    /// unter `capabilities`.
    ///
    /// Fehlt ein Feld, bleibt die Antwort **nil** und nicht `false`. Ein Anbieter,
    /// der zu Bildern schweigt, hat nicht gesagt, dass sein Modell keine sieht.
    static func capabilities(from v: JSONValue) -> Capabilities {
        var caps = Capabilities()

        func flag(_ keys: [String]) -> Bool? {
            for key in keys {
                if let b = v[key]?.boolValue { return b }
                if let b = v["capabilities"]?[key]?.boolValue { return b }
            }
            return nil
        }
        caps.vision = flag(["supports_vision", "vision"])
        caps.tools = flag(["supports_function_calling", "supports_tools", "tools",
                           "function_calling"])
        caps.reasoning = flag(["supports_reasoning", "reasoning"])

        // OpenRouter: was hineingeht, und welche Parameter die Anfrage annimmt.
        let modalities = (v["architecture"]?["input_modalities"]?.arrayValue ?? [])
            .compactMap { $0.stringValue?.lowercased() }
        if caps.vision == nil, !modalities.isEmpty {
            caps.vision = modalities.contains("image")
        }
        let parameters = (v["supported_parameters"]?.arrayValue ?? [])
            .compactMap { $0.stringValue?.lowercased() }
        if !parameters.isEmpty {
            if caps.tools == nil { caps.tools = parameters.contains("tools") }
            if caps.reasoning == nil {
                caps.reasoning = parameters.contains("reasoning")
                    || parameters.contains("include_reasoning")
            }
        }
        return caps
    }

    private static func int(_ v: JSONValue?) -> Int? {
        guard let s = v?.stringValue, let d = Double(s), d > 0 else { return nil }
        return Int(d)
    }

    // MARK: Grenzen, die der Anbieter nicht nennt

    // Hier stand ein Test, der eine absurde Obergrenze schickte und die echte aus der
    // Absage las. Er funktionierte — und ist trotzdem weg. Die App erfindet keine
    // Zahlen, um Grenzen auszuloten; sie nimmt, was in der Modellliste steht, und
    // lernt den Rest aus echten Anfragen. `extractLimits` bleibt deshalb, nur der
    // Aufrufer ist ein anderer: nicht mehr ein Test beim Einrichten, sondern die
    // Absage, die ein Nutzer tatsaechlich kassiert hat.

    /// Pulls plausible token ceilings out of an error message.
    static func extractLimits(from text: String) -> (context: Int?, output: Int?) {
        let lower = text.lowercased()
        var context: Int?
        var output: Int?

        // Numbers that appear right after a phrase naming the limit.
        let patterns: [(regex: String, isContext: Bool)] = [
            ("max_tokens[^0-9]{0,40}?([0-9]{3,9})", false),
            ("maximum (?:number of )?(?:output |completion )?tokens[^0-9]{0,40}?([0-9]{3,9})", false),
            ("max(?:imum)? context (?:length|window)[^0-9]{0,40}?([0-9]{3,9})", true),
            ("context length[^0-9]{0,40}?([0-9]{3,9})", true),
            ("context_length[^0-9]{0,40}?([0-9]{3,9})", true),
        ]
        for (pattern, isContext) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: lower),
                  let n = Int(lower[r]), n >= 256, n <= 20_000_000
            else { continue }
            if isContext { context = context ?? n } else { output = output ?? n }
        }
        return (context, output)
    }
}
