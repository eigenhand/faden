import Foundation

/// Fragt ein Modell, was es kann — indem es das Modell fragt.
///
/// Die Modellliste ist die billige Quelle und die unzuverlässige. Sie schweigt
/// regelmässig, und wo sie redet, gibt sie wieder, was jemand einmal eingetragen hat.
/// Hier steht die andere Hälfte: eine kurze, echte Anfrage, deren Antwort sich nicht
/// bestreiten lässt.
///
/// Gefragt wird nur, was sich billig und eindeutig beantworten lässt:
///
///  - **Bilder** über `VisionProbe` — ein Bild von 64 Pixeln und die Frage nach zwei
///    Farben. Ein Endpoint ohne Bildunterstützung weist das mit 4xx ab.
///  - **Werkzeuge** über einen Aufruf mit einem Werkzeug, das nichts tut. Ein
///    Endpoint, der den Parameter nicht kennt, weist ihn ebenfalls mit 4xx ab.
///  - **Reasoning** nebenbei: kommt während dieser Anfrage ein Gedankengang mit, ist
///    die Frage beantwortet. Kommt keiner, ist sie **nicht** beantwortet — viele
///    Anbieter halten ihn zurück, solange man nicht ausdrücklich darum bittet. Ein
///    Nein wird daraus also nie.
///
/// Was hier **nicht** gefragt wird, ist die Antwortlänge. Der frühere Weg dorthin war,
/// eine absurde Obergrenze zu schicken und die echte aus der Absage zu lesen. Das
/// funktioniert und ist trotzdem weg: die App erfindet keine Zahlen, um Grenzen
/// auszuloten. Was der Anbieter in seiner Liste nennt, wird übernommen; alles andere
/// lernt die App aus echten Anfragen, wenn eine wirklich an eine Grenze stösst.
enum CapabilityProbe {

    /// Ein Werkzeug, das nichts tut.
    ///
    /// Absichtlich winzig und absichtlich eindeutig benannt: Es soll keine Frage
    /// beantworten, sondern nur beweisen, dass der Endpoint das Feld `tools`
    /// überhaupt annimmt und das Modell es bedienen kann.
    static let echoTool = ToolSpec(
        name: "faden_probe_echo",
        description: "Gibt ein Wort unverändert zurück. Nur zum Prüfen der Verbindung.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "wort": .object([
                    "type": .string("string"),
                    "description": .string("Das Wort, das zurückgegeben wird."),
                ]),
            ]),
            "required": .array([.string("wort")]),
        ]))

    enum ToolOutcome: Equatable {
        /// Das Modell hat das Werkzeug wirklich aufgerufen.
        case used
        /// Der Endpoint hat das Feld angenommen, das Modell hat aber lieber geantwortet.
        /// Kein Fehler — nur kein Beweis.
        case acceptedButUnused
        case refused(String)
        case inconclusive(String)
    }

    struct Reading {
        var tools: ToolOutcome
        /// nil heisst: kein Gedankengang gesehen, und das ist kein Nein.
        var reasoning: Bool?
    }

    /// Ein Aufruf, zwei Antworten.
    ///
    /// Werkzeuge und Reasoning in derselben Anfrage, weil beides an derselben Antwort
    /// abzulesen ist und eine zweite Anfrage nur ein zweites Mal kosten würde.
    static func toolsAndReasoning(config: LLMConfig, apiKey: String) async -> Reading {
        guard config.wireFormat.needsEndpoint else {
            return Reading(tools: .inconclusive("Apples Modell kennt keine Werkzeuge."),
                           reasoning: nil)
        }
        // Konstant, weil die Anfrage gleich in eine nebenläufige Closure wandert und
        // eine veränderliche Kopie dort nicht mitdarf.
        let cfg: LLMConfig = {
            var c = config
            // Genug für einen Werkzeugaufruf, wenig genug, dass ein geschwätziges
            // Modell hier nichts kostet.
            c.maxOutputTokens = max(1_000, min(4_000, config.maxOutputTokens))
            return c
        }()
        let provider = ProviderFactory.make(for: cfg.wireFormat)

        let ask = Message(role: .user,
                          text: "Rufe das Werkzeug faden_probe_echo mit dem Wort „bereit“ auf.")
        let system = "Du prüfst eine Verbindung. Benutze das Werkzeug, statt zu antworten."

        do {
            let seen = try await withTimeout(seconds: 90) {
                var usedTool = false
                var thought = false
                for try await event in provider.stream(messages: [ask], system: system,
                                                       tools: [echoTool],
                                                       config: cfg, apiKey: apiKey) {
                    switch event {
                    case .toolUseStarted, .toolUseCompleted: usedTool = true
                    case .thinkingDelta:                     thought = true
                    default:                                 break
                    }
                    if usedTool && thought { break }
                }
                return (usedTool, thought)
            }
            return Reading(tools: seen.0 ? .used : .acceptedButUnused,
                           reasoning: seen.1 ? true : nil)
        } catch let error as LLMError {
            if case .http(let status, let body) = error {
                // 4xx heisst hier: der Endpoint nimmt das Feld nicht. 5xx sagt nichts
                // über Werkzeuge aus, das ist der Anbieter und nicht das Modell.
                if (400...499).contains(status) {
                    return Reading(tools: .refused("HTTP \(status). "
                                                   + VisionProbe.readableMessage(from: body)),
                                   reasoning: nil)
                }
                return Reading(tools: .inconclusive("HTTP \(status) — das sagt nichts über "
                                                    + "Werkzeuge aus."), reasoning: nil)
            }
            return Reading(tools: .inconclusive(error.errorDescription ?? "Unklar."),
                           reasoning: nil)
        } catch {
            return Reading(tools: .inconclusive(error.localizedDescription), reasoning: nil)
        }
    }
}
