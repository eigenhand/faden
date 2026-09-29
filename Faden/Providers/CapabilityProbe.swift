import Foundation

/// Asks a model what it can do — by asking the model.
///
/// The model list is the cheap source and the unreliable one. It regularly says nothing,
/// and where it speaks it repeats what somebody once entered. The other half stands
/// here: a short, real request whose answer cannot be disputed.
///
/// Only what can be answered cheaply and unambiguously is asked:
///
///  - **Images** through `VisionProbe` — a 64-pixel picture and the question about two
///    colours. An endpoint without image support refuses that with a 4xx.
///  - **Tools** through a call carrying a tool that does nothing. An endpoint that does
///    not know the parameter refuses it with a 4xx as well.
///  - **Reasoning** in passing: if reasoning comes along during this request, the
///    question is answered. If none comes, it is **not** answered — many providers hold
///    it back unless you explicitly ask. So it never turns into a no.
///
/// What is **not** asked here is the answer length. The earlier route to that was to
/// send an absurd upper bound and read the real one out of the refusal. It works and is
/// gone all the same: the app invents no numbers to sound out limits. What the provider
/// names in its list is taken over; everything else the app learns from real requests,
/// when one actually hits a limit.
enum CapabilityProbe {

    /// A tool that does nothing.
    ///
    /// Deliberately tiny and deliberately named unambiguously: it is not meant to answer
    /// a question, only to prove that the endpoint accepts the `tools` field at all and
    /// that the model can operate it.
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
        /// The model really called the tool.
        case used
        /// The endpoint accepted the field, but the model preferred to answer.
        /// Not an error — just not a proof.
        case acceptedButUnused
        case refused(String)
        case inconclusive(String)
    }

    struct Reading {
        var tools: ToolOutcome
        /// nil means: no reasoning seen, and that is not a no.
        var reasoning: Bool?
    }

    /// One call, two answers.
    ///
    /// Tools and reasoning in the same request, because both can be read off the same
    /// answer and a second request would only cost a second time.
    static func toolsAndReasoning(config: LLMConfig, apiKey: String) async -> Reading {
        guard config.wireFormat.needsEndpoint else {
            return Reading(tools: .inconclusive(String(localized: "Apples Modell kennt keine Werkzeuge.")),
                           reasoning: nil)
        }
        // Constant, because the request is about to travel into a concurrent closure
        // and a mutable copy is not allowed there.
        let cfg: LLMConfig = {
            var c = config
            // Enough for one tool call, little enough that a talkative model costs
            // nothing here.
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
                // A 4xx here means: the endpoint does not take the field. A 5xx says
                // nothing about tools, that is the provider and not the model.
                if (400...499).contains(status) {
                    return Reading(tools: .refused("HTTP \(status). "
                                                   + VisionProbe.readableMessage(from: body)),
                                   reasoning: nil)
                }
                return Reading(tools: .inconclusive(String(localized: "HTTP \(status) — das sagt nichts über Werkzeuge aus.")), reasoning: nil)
            }
            return Reading(tools: .inconclusive(error.errorDescription ?? String(localized: "Unklar.")),
                           reasoning: nil)
        } catch {
            return Reading(tools: .inconclusive(error.localizedDescription), reasoning: nil)
        }
    }
}
