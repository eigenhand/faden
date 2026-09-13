import Foundation

/// One model as an endpoint describes it.
struct RemoteModel: Identifiable, Equatable, Hashable {
    var id: String
    var displayName: String?
    var contextLength: Int?
    var maxOutput: Int?
    var owner: String?
    /// Formatted price per million input/output tokens, when the endpoint says.
    var pricing: String?

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

    private static func int(_ v: JSONValue?) -> Int? {
        guard let s = v?.stringValue, let d = Double(s), d > 0 else { return nil }
        return Int(d)
    }

    // MARK: Probing limits the endpoint does not publish

    /// Asks for an absurd `max_tokens` and reads the ceiling out of the rejection.
    ///
    /// Most endpoints answer such a request with a message naming their real limit
    /// ("max_tokens must be <= 8192", "maximum context length is 131072 tokens").
    /// The request is refused before any tokens are generated, so this costs nothing
    /// but a round trip — and it is the only way to learn the limits of a provider
    /// whose model list carries no numbers at all.
    static func probeLimits(config: LLMConfig, apiKey: String, model: String) async -> (context: Int?, output: Int?) {
        var cfg = config
        cfg.model = model
        cfg.maxOutputTokens = 99_999_999
        cfg.requestThinking = false

        guard cfg.wireFormat.needsEndpoint, let url = cfg.endpointURL else { return (nil, nil) }
        var body: [String: Any]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        switch cfg.wireFormat {
        case .anthropic:
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue(AnthropicProvider.version, forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": 99_999_999,
                    "messages": [["role": "user", "content": "hi"]]]
        case .openai:
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            body = ["model": model, "max_tokens": 99_999_999,
                    "messages": [["role": "user", "content": "hi"]]]
        case .appleOnDevice:
            return (nil, nil)  // kein Endpoint, den man nach Grenzen fragen koennte
        }
        for (k, v) in cfg.extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await Net.session.data(for: req),
              let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
        return extractLimits(from: text)
    }

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
