import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apples Modell auf dem Gerät, über `FoundationModels`.
///
/// Der eine Anbieter in dieser App, der keiner ist: kein Endpoint, kein Schlüssel,
/// keine Leitung. Das passt zu Fadens Prämisse besser als alles andere — die App
/// bringt keine Infrastruktur mit, und hier gibt es keine, die sie mitbringen
/// könnte. Ein Gespräch mit diesem Modell verlässt das Telefon nicht.
///
/// Der Preis steht in `AppleModel.limitations` und wird in den Einstellungen
/// angezeigt, nicht verschwiegen: kein Werkzeuggebrauch, keine Bilder, ein kleines
/// Kontextfenster. Ein schwaches Modell, das man richtig beschreibt, ist brauchbar;
/// eines, das man als gleichwertig hinstellt, enttäuscht bei der ersten Frage, die
/// eine Websuche gebraucht hätte.
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

        // Die letzte Nutzernachricht ist die Frage, alles davor der Verlauf. Anders
        // als bei den Netz-Anbietern schickt man hier nicht die ganze Historie als
        // eine Anfrage: die Sitzung führt ihr eigenes Protokoll, und der Prompt ist
        // nur der neue Zug.
        guard let lastUser = messages.last(where: { $0.role == .user }) else {
            throw LLMError.transport("Keine Frage in der Unterhaltung gefunden.")
        }
        let history = messages.prefix { $0.id != lastUser.id }

        let session = LanguageModelSession(
            transcript: Transcript(entries: entries(system: system, history: Array(history))))

        var options = GenerationOptions(temperature: config.temperature)
        options.maximumResponseTokens = config.maxOutputTokens

        // Die Schnappschüsse sind kumulativ — jeder enthält den ganzen bisherigen
        // Text, nicht das neue Stück. Faden erwartet Zuwächse, also wird hier
        // differenziert. Ohne das stünde die Antwort nach jedem Schnappschuss
        // vollständig noch einmal da.
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

    /// Fadens Verlauf als Protokoll der Sitzung.
    ///
    /// Bilder, Werkzeugaufrufe und Gedankengänge fallen dabei heraus — das Modell
    /// kann keines davon. Sie stillschweigend als Text mitzuschicken wäre schlimmer
    /// als sie wegzulassen: aus einem Werkzeugergebnis würde eine Behauptung ohne
    /// Herkunft.
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
            // Eine System-Nachricht mitten im Verlauf gehoert nicht ins Protokoll:
            // die Anweisung steht schon als `instructions` am Anfang, und ein
            // zweiter Satz Regeln in der Mitte wuerde dem Modell widersprechen.
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

    /// Apples Fehler in Sätze, die sagen, was zu tun ist.
    ///
    /// Über den in iOS 27 abgekündigten `GenerationError` und nicht über den neuen
    /// `LanguageModelError` — den gibt es erst ab 27, und diese Funktion soll ab 26
    /// laufen. Abgekündigt heißt vorhanden; wenn Faden einmal iOS 27 voraussetzt,
    /// ist das hier die Stelle, die umzieht.
    @available(iOS 26.0, *)
    private static func translate(_ error: Error) -> Error {
        guard let generation = error as? LanguageModelSession.GenerationError else {
            // Apples Sicherheitspruefung sitzt als eigener Systemdienst daneben und
            // fehlt im Simulator ganz. Der rohe Fehler sagt „SensitiveContentAnalysisML
            // 15" und schickt jeden auf die falsche Suche.
            let ns = error as NSError
            if ns.domain.contains("SensitiveContentAnalysis") {
                return LLMError.transport(
                    "Apples Sicherheitsprüfung ist auf diesem System nicht verfügbar — "
                    + "im Simulator fehlt sie immer. Auf einem echten iPhone mit "
                    + "eingeschalteter Apple Intelligence läuft es.")
            }
            return LLMError.transport(error.localizedDescription)
        }
        switch generation {
        case .exceededContextWindowSize:
            return LLMError.transport(
                "Die Unterhaltung ist zu lang für das Modell auf dem Gerät. Sein "
                + "Kontextfenster ist klein — verdichten oder neu anfangen.")
        case .guardrailViolation, .refusal:
            return LLMError.transport(
                "Apples Modell hat die Antwort verweigert. Die Sperren sitzen im "
                + "System und lassen sich von hier nicht abschalten.")
        case .unsupportedLanguageOrLocale:
            return LLMError.transport("Diese Sprache beherrscht das Modell auf dem Gerät nicht.")
        case .rateLimited:
            return LLMError.transport("Das System hat die Anfragen gedrosselt — gleich noch einmal.")
        case .concurrentRequests:
            return LLMError.transport(
                "Es läuft schon eine Anfrage an das Modell. Das System nimmt nur eine "
                + "auf einmal.")
        case .assetsUnavailable:
            return LLMError.transport(
                "Das Modell liegt gerade nicht auf dem Gerät. Das System lädt es bei "
                + "Netz und Ladekabel nach.")
        case .decodingFailure, .unsupportedGuide:
            return LLMError.transport("Die Antwort des Modells war nicht lesbar.")
        @unknown default:
            return LLMError.transport(generation.localizedDescription)
        }
    }
    #endif
}

/// Was Apples Modell ist, kann und nicht kann — an einer Stelle, damit Oberfläche
/// und Anbieter dasselbe sagen.
enum AppleModel {

    static let needsOS = "Apples Modell auf dem Gerät gibt es ab iOS 26."

    /// Die Grenzen, ungeschönt. Stehen so in den Einstellungen.
    static let limitations = [
        "Keine Werkzeuge: keine Websuche, kein Gedächtnisabruf, keine Dateien.",
        "Keine Bilder — das Modell liest nur Text.",
        "Kleines Kontextfenster; lange Unterhaltungen brechen früher ab.",
        "Deutlich schwächer als ein großes Modell am Endpoint.",
    ]

    struct Status {
        var isUsable: Bool
        var headline: String
        var detail: String
    }

    /// Was das System gerade sagt — und bei jedem Nein, woran es liegt.
    ///
    /// Drei verschiedene Gründe, und sie verlangen drei verschiedene Handlungen:
    /// ein zu altes Gerät ist endgültig, eine abgeschaltete Apple Intelligence ist
    /// ein Schalter in den Systemeinstellungen, ein nicht geladenes Modell ist
    /// Warten. Alle drei als „nicht verfügbar" zu zeigen hieße, den Nutzer raten zu
    /// lassen, welcher davon gilt.
    static var status: Status {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            return Status(isUsable: false, headline: "Ab iOS 26", detail: needsOS)
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return Status(isUsable: true, headline: "Bereit",
                          detail: "Das Modell liegt auf dem Gerät. Gespräche damit "
                                + "verlassen das Telefon nicht.")
        case .unavailable(.deviceNotEligible):
            return Status(isUsable: false, headline: "Gerät zu alt",
                          detail: "Dieses iPhone unterstützt Apple Intelligence nicht. "
                                + "Nötig ist ein iPhone 15 Pro oder neuer.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return Status(isUsable: false, headline: "Apple Intelligence ist aus",
                          detail: "In den Systemeinstellungen unter „Apple Intelligence & Siri“ "
                                + "einschalten, dann hier zurückkommen.")
        case .unavailable(.modelNotReady):
            return Status(isUsable: false, headline: "Modell wird noch geladen",
                          detail: "Das System lädt das Modell im Hintergrund — das "
                                + "passiert bei Netz und Ladekabel. Später erneut versuchen.")
        @unknown default:
            return Status(isUsable: false, headline: "Nicht verfügbar",
                          detail: "Das System gibt das Modell gerade nicht frei.")
        }
        #else
        return Status(isUsable: false, headline: "Ab iOS 26", detail: needsOS)
        #endif
    }
}
