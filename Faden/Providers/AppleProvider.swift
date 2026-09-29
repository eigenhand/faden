import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, through `FoundationModels`.
///
/// The one provider in this app that is none: no endpoint, no key, no wire. That fits
/// Faden's premise better than anything else — the app brings no infrastructure with it,
/// and here there is none it could bring. A conversation with this model does not leave
/// the phone.
///
/// The price stands in `AppleModel.limitations` and is shown in the settings, not kept
/// quiet: no tool use, no images, a small context window. A weak model described
/// correctly is usable; one presented as an equal disappoints on the first question that
/// would have needed a web search.
struct AppleProvider: LLMProvider {

    func stream(messages: [Message], system: String, tools: [ToolSpec],
                config: LLMConfig, apiKey: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            guard #available(iOS 26.0, *) else {
                continuation.finish(throwing: LLMError.transport(AppleModel.needsOS))
                return
            }
            let task = Task {
                do {
                    try await Self.run(messages: messages, system: system,
                                       config: config, continuation: continuation)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.translate(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
            #else
            continuation.finish(throwing: LLMError.transport(AppleModel.needsOS))
            #endif
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func run(messages: [Message], system: String, config: LLMConfig,
                            continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw LLMError.transport(AppleModel.status.detail)
        }

        // The last user message is the question, everything before it the history.
        // Unlike with the network providers, the whole history is not sent as one
        // request here: the session keeps its own transcript, and the prompt is only the
        // new turn.
        guard let lastUser = messages.last(where: { $0.role == .user }) else {
            throw LLMError.transport(String(localized: "Keine Frage in der Unterhaltung gefunden."))
        }
        let history = messages.prefix { $0.id != lastUser.id }

        let session = LanguageModelSession(
            transcript: Transcript(entries: entries(system: system, history: Array(history))))

        var options = GenerationOptions(temperature: config.temperature)
        options.maximumResponseTokens = config.maxOutputTokens

        // The snapshots are cumulative — each holds all the text so far, not the new
        // piece. Faden expects increments, so the difference is taken here. Without it
        // the answer would stand there in full again after every snapshot.
        var emitted = ""
        for try await snapshot in session.streamResponse(to: prompt(lastUser), options: options) {
            try Task.checkCancellation()
            let full = snapshot.content
            guard full.count > emitted.count else { continue }
            let delta = String(full.dropFirst(emitted.count))
            emitted = full
            if !delta.isEmpty { continuation.yield(.textDelta(delta)) }
        }
        continuation.yield(.stopped(reason: "end_turn"))
        continuation.finish()
    }

    /// Faden's history as the session's transcript.
    ///
    /// Images, tool calls and reasoning fall away in the process — the model can do none
    /// of them. Sending them along silently as text would be worse than leaving them
    /// out: a tool result would turn into an assertion without a source.
    @available(iOS 26.0, *)
    private static func entries(system: String, history: [Message]) -> [Transcript.Entry] {
        var out: [Transcript.Entry] = []
        let cleanSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanSystem.isEmpty {
            out.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: cleanSystem))],
                toolDefinitions: [])))
        }
        for message in history {
            let text = message.blocks.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let segments: [Transcript.Segment] = [.text(Transcript.TextSegment(content: text))]
            switch message.role {
            case .user:      out.append(.prompt(Transcript.Prompt(segments: segments)))
            case .assistant: out.append(.response(Transcript.Response(assetIDs: [], segments: segments)))
            // A system message in the middle of the history does not belong in the
            // transcript: the instruction already stands as `instructions` at the
            // start, and a second set of rules in the middle would contradict it.
            case .system:    break
            }
        }
        return out
    }

    @available(iOS 26.0, *)
    private static func prompt(_ message: Message) -> String {
        message.blocks.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined(separator: "\n")
    }

    /// Apple's errors turned into sentences that say what to do.
    ///
    /// Through `GenerationError`, deprecated in iOS 27, and not through the new
    /// `LanguageModelError` — that one only exists from 27 onwards, and this function
    /// should run from 26. Deprecated means present; if Faden ever requires iOS 27, this
    /// is the place that moves.
    @available(iOS 26.0, *)
    private static func translate(_ error: Error) -> Error {
        guard let generation = error as? LanguageModelSession.GenerationError else {
            // Apple's safety check sits beside it as a system service of its own and
            // is missing from the simulator entirely. The raw error says
            // “SensitiveContentAnalysisML 15” and sends everyone on the wrong hunt.
            let ns = error as NSError
            if ns.domain.contains("SensitiveContentAnalysis") {
                return LLMError.transport(String(localized:
                    "Apples Sicherheitsprüfung ist auf diesem System nicht verfügbar — im Simulator fehlt sie immer. Auf einem echten iPhone mit eingeschalteter Apple Intelligence läuft es."))
            }
            return LLMError.transport(error.localizedDescription)
        }
        switch generation {
        case .exceededContextWindowSize:
            return LLMError.transport(String(localized:
                "Die Unterhaltung ist zu lang für das Modell auf dem Gerät. Sein Kontextfenster ist klein — verdichten oder neu anfangen."))
        case .guardrailViolation, .refusal:
            return LLMError.transport(String(localized:
                "Apples Modell hat die Antwort verweigert. Die Sperren sitzen im System und lassen sich von hier nicht abschalten."))
        case .unsupportedLanguageOrLocale:
            return LLMError.transport(String(localized: "Diese Sprache beherrscht das Modell auf dem Gerät nicht."))
        case .rateLimited:
            return LLMError.transport(String(localized: "Das System hat die Anfragen gedrosselt — gleich noch einmal."))
        case .concurrentRequests:
            return LLMError.transport(String(localized:
                "Es läuft schon eine Anfrage an das Modell. Das System nimmt nur eine auf einmal."))
        case .assetsUnavailable:
            return LLMError.transport(String(localized:
                "Das Modell liegt gerade nicht auf dem Gerät. Das System lädt es bei Netz und Ladekabel nach."))
        case .decodingFailure, .unsupportedGuide:
            return LLMError.transport(String(localized: "Die Antwort des Modells war nicht lesbar."))
        @unknown default:
            return LLMError.transport(generation.localizedDescription)
        }
    }
    #endif
}

/// What Apple's model is, can and cannot do — in one place, so that the interface and
/// the provider say the same thing.
enum AppleModel {

    // Computed, not stored: the interface language can change at runtime.
    static var needsOS: String { String(localized: "Apples Modell auf dem Gerät gibt es ab iOS 26.") }

    /// The limits, unvarnished. They stand like this in the settings.
    static var limitations: [String] {
        [
            String(localized: "Keine Werkzeuge: keine Websuche, kein Gedächtnisabruf, keine Dateien."),
            String(localized: "Keine Bilder — das Modell liest nur Text."),
            String(localized: "Kleines Kontextfenster; lange Unterhaltungen brechen früher ab."),
            String(localized: "Deutlich schwächer als ein großes Modell am Endpoint."),
        ]
    }

    struct Status {
        var isUsable: Bool
        var headline: String
        var detail: String
    }

    /// What the system says right now — and, on every no, what it is down to.
    ///
    /// Three different reasons, and they call for three different actions: a device too
    /// old is final, Apple Intelligence switched off is a toggle in the system settings,
    /// a model not yet downloaded is waiting. Showing all three as “not available” would
    /// mean leaving the user to guess which one applies.
    static var status: Status {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            return Status(isUsable: false, headline: String(localized: "Ab iOS 26"), detail: needsOS)
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return Status(isUsable: true, headline: String(localized: "Bereit"),
                          detail: String(localized: "Das Modell liegt auf dem Gerät. Gespräche damit verlassen das Telefon nicht."))
        case .unavailable(.deviceNotEligible):
            return Status(isUsable: false, headline: String(localized: "Gerät zu alt"),
                          detail: String(localized: "Dieses iPhone unterstützt Apple Intelligence nicht. Nötig ist ein iPhone 15 Pro oder neuer."))
        case .unavailable(.appleIntelligenceNotEnabled):
            return Status(isUsable: false, headline: String(localized: "Apple Intelligence ist aus"),
                          detail: String(localized: "In den Systemeinstellungen unter „Apple Intelligence & Siri“ einschalten, dann hier zurückkommen."))
        case .unavailable(.modelNotReady):
            return Status(isUsable: false, headline: String(localized: "Modell wird noch geladen"),
                          detail: String(localized: "Das System lädt das Modell im Hintergrund — das passiert bei Netz und Ladekabel. Später erneut versuchen."))
        @unknown default:
            return Status(isUsable: false, headline: String(localized: "Nicht verfügbar"),
                          detail: String(localized: "Das System gibt das Modell gerade nicht frei."))
        }
        #else
        return Status(isUsable: false, headline: String(localized: "Ab iOS 26"), detail: needsOS)
        #endif
    }
}
