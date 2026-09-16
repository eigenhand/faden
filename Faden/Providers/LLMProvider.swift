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
            // Nach den Wartepausen. „HTTP 429" plus JSON wäre richtig und nutzlos.
            return String(localized: "Der Anbieter drosselt gerade (HTTP \(s)) — auch nach zwei Wartepausen noch.")
        case .http(let s, let b):
            let snippet = b.count > 400 ? String(b.prefix(400)) + "…" : b
            return String(localized: "HTTP \(s)\n\(snippet)")
        case .transport(let m):       return String(localized: "Verbindungsfehler: \(m)")
        case .decoding(let m):        return String(localized: "Antwort nicht lesbar: \(m)")
        }
    }
}

/// Warten, wenn der Anbieter drosselt.
///
/// Ein 429 heißt „zu viele Anfragen", 503 und 529 heißen „gerade überlastet". Das
/// sind Wartezeiten, keine Defekte — und die richtige Antwort darauf ist, kurz zu
/// warten und dasselbe Modell noch einmal zu fragen.
///
/// Faden hat stattdessen sofort auf das Ausweichmodell geschaltet. Das ist die
/// teuerste mögliche Reaktion: zwei Modelle desselben Anbieters, auf derselben
/// Frage gemessen, lagen 72 Sekunden gegen 12 — aus zwei Sekunden Warten wurde
/// eine Minute, und der Nutzer bekam die schlechtere Antwort obendrein. Das
/// Ausweichmodell bleibt, aber als letzter Schritt und nicht als erster.
enum Backoff {

    static func isBusy(_ status: Int) -> Bool { status == 429 || status == 503 || status == 529 }

    /// Höchstens zwei Pausen. Sechs Sekunden sind die Grenze dessen, was man
    /// stillschweigend aussitzen darf; danach ist das Ausweichmodell an der Reihe.
    static let maxWaits = 2

    /// `Retry-After` zuerst, weil der Anbieter es besser weiß als jede Formel —
    /// gedeckelt, damit ein Kopf mit „3600" nicht die App für eine Stunde anhält.
    /// Sonst 2, dann 4 Sekunden.
    static func pause(retryAfter header: String?, attempt: Int) -> Double {
        if let header, let seconds = Double(header.trimmingCharacters(in: .whitespaces)),
           seconds > 0 {
            return Swift.min(seconds, 30)
        }
        return Double(1 << (attempt + 1))
    }

    /// Öffnet die Verbindung — und wartet, statt bei einer Drosselung aufzugeben.
    ///
    /// Gemeinsam für beide Anbieter, weil beide dieselben sechs Zeilen hatten und ein
    /// Wartemechanismus an zwei Stellen einer ist, der an einer Stelle vergessen wird.
    ///
    /// Ein zweiter Versuch ist hier gefahrlos: es ist noch kein Zeichen beim Leser
    /// angekommen. Nach den ersten Zeichen wäre er es nicht mehr.
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

    /// Entfernt Werkzeugaufrufe, zu denen kein Ergebnis in der Historie steht —
    /// und Ergebnisse, zu denen kein Aufruf steht.
    ///
    /// Beide Formate verlangen die Paarung. OpenAI-kompatible Endpoints antworten
    /// auf eine Assistenznachricht mit `tool_calls` ohne passende `tool`-Nachrichten
    /// mit HTTP 400, Anthropic ebenso. Und weil bei jeder Anfrage die *ganze*
    /// Historie mitgeht, ist ein einziges verwaistes Paar kein einmaliger Fehler:
    /// ab da geht in diesem Gespräch keine Nachricht mehr durch. Genau so ist es
    /// aufgefallen — zwei Antworten mit Quellen, und danach nichts mehr.
    ///
    /// Entstehen kann es beim Abbrechen: das Modell hat die Aufrufe schon gestellt,
    /// die Werkzeuge sind noch nicht gelaufen. Die Stelle ist repariert, aber das
    /// hilft keinem Gespräch, das schon auf dem Gerät liegt. Deshalb steht der
    /// Schutz hier, an der Leitung, wo jede Anfrage vorbeimuss.
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
        // Der Normalfall, und er soll nichts kosten: nichts kopieren, wenn alles paart.
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
