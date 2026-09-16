import Foundation

/// A tool the model may call.
struct ToolSpec: Equatable {
    var name: String
    var description: String
    /// JSON Schema for the tool input.
    var inputSchema: JSONValue
}

enum StreamEvent {
    case textDelta(String)
    case thinkingDelta(String)
    case toolUseStarted(id: String, name: String)
    case toolUseCompleted(id: String, name: String, input: JSONValue)
    case usage(input: Int?, output: Int?)
    case stopped(reason: String?)
}

enum LLMError: LocalizedError {
    case notConfigured
    case missingKey
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:          return String(localized: "Kein Modell konfiguriert. Endpoint, Key und Modellname fehlen.")
        case .missingKey:             return String(localized: "Kein API-Key im Schlüsselbund hinterlegt.")
        case .http(let s, _) where Backoff.isBusy(s):
            // After the waits. “HTTP 429” plus JSON would be correct and useless.
            return String(localized: "Der Anbieter drosselt gerade (HTTP \(s)) — auch nach zwei Wartepausen noch.")
        case .http(let s, let b):
            let snippet = b.count > 400 ? String(b.prefix(400)) + "…" : b
            return String(localized: "HTTP \(s)\n\(snippet)")
        case .transport(let m):       return String(localized: "Verbindungsfehler: \(m)")
        case .decoding(let m):        return String(localized: "Antwort nicht lesbar: \(m)")
        }
    }
}

/// Waiting when the provider throttles.
///
/// A 429 means “too many requests”, 503 and 529 mean “overloaded right now”. Those are
/// waiting times, not defects — and the right answer to them is to wait briefly and ask
/// the same model again.
///
/// Faden instead switched to the fallback model at once. That is the most expensive
/// possible reaction: two models from the same provider, measured on the same question,
/// came to 72 seconds against 12 — two seconds of waiting turned into a minute, and the
/// user got the worse answer on top. The fallback model stays, but as the last step and
/// not the first.
enum Backoff {

    static func isBusy(_ status: Int) -> Bool { status == 429 || status == 503 || status == 529 }

    /// At most two waits. Six seconds is the limit of what may be sat out in silence;
    /// after that the fallback model's turn has come.
    static let maxWaits = 2

    /// `Retry-After` first, because the provider knows better than any formula —
    /// capped, so that a header saying “3600” does not stop the app for an hour.
    /// Otherwise 2, then 4 seconds.
    static func pause(retryAfter header: String?, attempt: Int) -> Double {
        if let header, let seconds = Double(header.trimmingCharacters(in: .whitespaces)),
           seconds > 0 {
            return Swift.min(seconds, 30)
        }
        return Double(1 << (attempt + 1))
    }

    /// Opens the connection — and waits rather than giving up on a throttle.
    ///
    /// Shared by both providers, because both carried the same six lines, and a waiting
    /// mechanism in two places is one that gets forgotten in one of them.
    ///
    /// A second attempt is harmless here: not a character has reached the reader yet.
    /// After the first characters it would no longer be.
    static func open(_ build: () throws -> URLRequest) async throws -> URLSession.AsyncBytes {
        var attempt = 0
        while true {
            let (bytes, response) = try await Net.session.bytes(for: try build())
            guard let http = response as? HTTPURLResponse else {
                throw LLMError.transport("Keine HTTP-Antwort")
            }
            if (200 ... 299).contains(http.statusCode) { return bytes }

            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 2_000 { break }
            }
            guard isBusy(http.statusCode), attempt < maxWaits else {
                throw LLMError.http(status: http.statusCode, body: errorBody)
            }
            try await Task.sleep(for: .seconds(
                pause(retryAfter: http.value(forHTTPHeaderField: "Retry-After"), attempt: attempt)))
            attempt += 1
        }
    }
}

extension Array where Element == Message {

    /// Removes tool calls that have no result in the history — and results that have
    /// no call.
    ///
    /// Both formats demand the pairing. OpenAI-compatible endpoints answer an assistant
    /// message carrying `tool_calls` without matching `tool` messages with HTTP 400, and
    /// Anthropic does the same. And because the *whole* history travels with every
    /// request, a single orphaned pair is not a one-off error: from then on no message
    /// gets through in that conversation again. That is exactly how it came to light —
    /// two answers with sources, and after that nothing.
    ///
    /// It can arise on cancellation: the model has already made the calls, the tools
    /// have not run yet. That place is repaired, but it helps no conversation already
    /// sitting on the device. Which is why the protection stands here, on the wire,
    /// where every request has to pass.
    func pairingToolCallsAndResults() -> [Message] {
        var called: Set<String> = []
        var answered: Set<String> = []
        for m in self {
            for b in m.blocks {
                switch b {
                case .toolUse(let id, _, _):    called.insert(id)
                case .toolResult(let id, _, _): answered.insert(id)
                default: break
                }
            }
        }
        // The normal case, and it should cost nothing: copy nothing when everything
        // pairs up.
        guard called != answered else { return self }

        return compactMap { m in
            var kept: [ContentBlock] = []
            for b in m.blocks {
                switch b {
                case .toolUse(let id, _, _):    if answered.contains(id) { kept.append(b) }
                case .toolResult(let id, _, _): if called.contains(id) { kept.append(b) }
                default: kept.append(b)
                }
            }
            guard !kept.isEmpty else { return nil }
            var out = m
            out.blocks = kept
            return out
        }
    }
}

protocol LLMProvider: Sendable {
    /// Streams a single assistant turn.
    func stream(
        messages: [Message],
        system: String,
        tools: [ToolSpec],
        config: LLMConfig,
        apiKey: String
    ) -> AsyncThrowingStream<StreamEvent, Error>

    /// Exact token count if the provider offers one; nil means "use the estimator".
    func countTokens(
        messages: [Message],
        system: String,
        config: LLMConfig,
        apiKey: String
    ) async -> Int?
}

extension LLMProvider {
    func countTokens(messages: [Message], system: String, config: LLMConfig, apiKey: String) async -> Int? { nil }

    /// Plain-text completion for the app's own background work — compaction and
    /// recipe synthesis.
    ///
    /// Deliberately built on `stream` rather than a one-shot POST. Endpoints differ
    /// wildly in how well they serve non-streaming requests: one tested provider
    /// answered streamed calls in seconds while non-streamed calls of the same size
    /// never returned at all. Streaming is also what every vendor recommends for
    /// long outputs, so routing everything through one path removes a whole class
    /// of stalls and leaves a single code path to get right.
    func complete(
        messages: [Message],
        system: String,
        config: LLMConfig,
        apiKey: String,
        maxTokens: Int
    ) async throws -> String {
        var cfg = config
        cfg.maxOutputTokens = maxTokens
        // Background work wants an answer, not deliberation: thinking would eat the
        // allowance and can leave no text at all.
        cfg.requestThinking = false
        var text = ""
        var sawThinking = false
        var stopReason: String?

        for try await event in stream(messages: messages, system: system, tools: [],
                                      config: cfg, apiKey: apiKey) {
            switch event {
            case .textDelta(let d):   text += d
            case .thinkingDelta:      sawThinking = true
            case .stopped(let r):     stopReason = r
            default:                  break
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // A reasoning model that spent its whole allowance thinking looks like a
            // silent success otherwise, which is worse than an error.
            if sawThinking || stopReason == "length" || stopReason == "max_tokens" {
                throw LLMError.decoding(String(
                    localized: "Das Modell hat nur nachgedacht und keinen Text geliefert. Eine höhere maximale Antwortlänge hilft."))
            }
            throw LLMError.decoding("Das Modell hat keinen Text geliefert.")
        }
        return trimmed
    }
}

enum ProviderFactory {
    static func make(for format: LLMWireFormat) -> LLMProvider {
        switch format {
        case .anthropic:     return AnthropicProvider()
        case .openai:        return OpenAIProvider()
        case .appleOnDevice: return AppleProvider()
        }
    }
}

/// Shared URLSession with generous timeouts — long tool loops and slow local models.
enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 600
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    static func body(of response: URLResponse, data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}

struct TimeoutError: LocalizedError {
    let seconds: Int
    var errorDescription: String? { "Zeitüberschreitung nach \(seconds) Sekunden." }
}

/// Runs `work`, giving up after `seconds`. Background jobs must not wait forever —
/// a slow reasoning model on a long prompt can otherwise stall indefinitely.
func withTimeout<T: Sendable>(
    seconds: Int,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            throw TimeoutError(seconds: seconds)
        }
        guard let first = try await group.next() else { throw TimeoutError(seconds: seconds) }
        group.cancelAll()
        return first
    }
}
