import Foundation

/// What the UI observes while a turn is in flight.
enum TurnEvent {
    case thinking(String)
    case text(String)
    case toolStarted(id: String, name: String, summary: String)
    case toolFinished(id: String, ok: Bool, summary: String)
    case usage(input: Int?, output: Int?)
    case finished
    case failed(String)
}

/// Runs one assistant turn to completion: stream, execute whatever tools the model
/// asks for, feed the results back, repeat until it stops calling tools.
struct AgentRunner {

    let config: LLMConfig
    let apiKey: String
    let settings: AppSettings
    let searchKey: String?
    /// Needed by the memory tool, which searches the graph the same way recall does.
    var embeddingKey: String = ""

    var maxIterations = 8
    /// Triplets recalled from the memory graph for this turn.
    var recalled: [Triplet] = []

    // MARK: System prompt

    /// Context awareness starts here: the model is told when and where it is running,
    /// what it can reach, and how to behave when it cannot reach something.
    /// Deliberately free of anything that changes between requests — no clock, no
    /// recalled memories. Those are appended to the last user message instead, so
    /// this whole prompt stays byte-identical and cacheable.
    static func systemPrompt(settings: AppSettings, searchAvailable: Bool,
                             providerName: String?) -> String {
        let persona = settings.persona
        var s = """
        Du bist \(persona.displayName), ein Assistent auf dem iPhone deines Nutzers. Du \
        antwortest auf Deutsch, außer der Nutzer schreibt in einer anderen Sprache — \
        dann in seiner.

        \(persona.instructions)

        Am Ende der letzten Nachricht des Nutzers stehen in eckigen Klammern Datum und \
        Uhrzeit, und gegebenenfalls Auszüge aus früheren Gesprächen, die zur aktuellen \
        Frage passen. Beides kommt vom Gerät, nicht vom Nutzer: du sprichst es nicht an \
        und wiederholst es nicht. Rechne Zeitangaben immer dagegen, nicht gegen deinen \
        Trainingsstand — „heute“, „morgen“ und „nächste Woche“ beziehen sich darauf.

        So schreibst du:
        - Direkt zur Sache. Keine Einleitung, die die Frage wiederholt, kein Rückblick \
        am Ende, was du gerade getan hast.
        - Aufzählungen nur, wenn es wirklich mehrere gleichrangige Punkte gibt.
        - Wenn du etwas nicht sicher weißt, sagst du das. Du erfindest keine Zahlen, \
        keine Namen, keine Quellen und keine Zitate.
        """

        if searchAvailable {
            s += """


            Zur Websuche über \(providerName ?? "den eingerichteten Anbieter"):
            - Du suchst von dir aus, wenn die Antwort aktuell sein muss, lokal ist, sich \
            auf Personen oder Firmen bezieht oder nach deinem Wissensstand entstanden \
            sein könnte. Du fragst nicht vorher um Erlaubnis.
            - Bei mehreren Teilfragen suchst du mehrfach mit engen Anfragen, statt einmal \
            breit zu suchen.
            - Reicht ein Auszug nicht, lädst du die Seite mit fetch_page nach. Es wird \
            kein JavaScript ausgeführt: viele Wetter-, Karten- und Shopseiten geben \
            deshalb nichts her. Wähle von vornherein Quellen, die reinen Text liefern \
            — Wikipedia, Nachrichtenartikel, offene Datendienste wie wttr.in oder \
            Open-Meteo. Meldet das Werkzeug, dass eine Seite nichts hergibt, versuchst \
            du sie nicht erneut, sondern nimmst eine andere.
            - Du nennst deine Quellen im Fließtext mit dem Namen der Seite und der URL. \
            Bei widersprüchlichen Quellen sagst du, dass sie sich widersprechen.
            - Findest du nichts Belastbares, sagst du das, statt zu raten.
            """
        } else {
            s += """


            Es ist kein Suchanbieter eingerichtet. Du hast keinen Zugriff auf das Web. \
            Wenn eine Frage aktuelle Informationen bräuchte, sagst du das offen und weist \
            darauf hin, dass sich in den Einstellungen ein Suchanbieter hinterlegen lässt.
            """
        }

        if settings.memory.isReady {
            s += """


            Zum Gedächtnis:
            - Der Block in eckigen Klammern ist ein Auszug, keine Auskunft: darin steht \
            nur, was zur aktuellen Frage gepasst hat, nicht alles Hinterlegte. Fragt \
            dich jemand, was du über ihn weißt, oder brauchst du etwas, das dort nicht \
            steht, siehst du mit memory nach — „list“ für den Überblick, „search“ für \
            ein bestimmtes Thema. Du antwortest nicht „ich weiß nichts über dich“, ohne \
            vorher nachgesehen zu haben.
            - Stellt sich etwas Hinterlegtes als überholt heraus — ein Umzug, ein neuer \
            Job — oder bittet dich jemand, etwas zu vergessen, räumst du es auf: \
            „forget“ für den alten Eintrag, danach remember für das, was jetzt gilt.
            """
        }

        s += """


        Der Platz im Kontext ist begrenzt und wird bei Bedarf automatisch verdichtet. \
        Was danach noch gebraucht wird, hältst du vorher mit dem Werkzeug remember fest. \
        Erscheint im Verlauf eine Zusammenfassung, ist sie maßgeblich — du tust nicht so, \
        als erinnertest du dich an den Wortlaut davor.
        """
        return s
    }

    // MARK: Tool execution

    private func execute(name: String, input: JSONValue) async -> (text: String, ok: Bool, summary: String) {
        switch name {
        case "web_search":
            guard let query = input["query"]?.stringValue, !query.isEmpty else {
                return ("Fehler: Es wurde keine Suchanfrage übergeben.", false, "ohne Anfrage")
            }
            guard let recipe = settings.activeRecipe else {
                return ("Fehler: Es ist kein Suchanbieter eingerichtet.", false, "nicht eingerichtet")
            }
            let key = searchKey ?? ""
            do {
                let outcome = try await RecipeEngine.search(
                    recipe, query: query, key: key, count: settings.resultsPerSearch)
                return (Self.render(outcome), true, "\(outcome.results.count) Treffer")
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return ("Die Suche schlug fehl: \(msg)", false, "fehlgeschlagen")
            }

        case "fetch_page":
            guard let url = input["url"]?.stringValue, !url.isEmpty else {
                return ("Fehler: Es wurde keine URL übergeben.", false, "ohne URL")
            }
            let text = await PageFetcher.fetch(url)
            let ok = !text.hasPrefix("Fehler")
            return (text, ok, ok ? "\(text.count) Zeichen" : "nicht ladbar")

        case "memory":
            guard settings.memory.isReady else {
                return ("Fehler: Es ist kein Gedächtnis eingerichtet.", false, "nicht eingerichtet")
            }
            return await Self.runMemory(input, memory: settings.memory, embeddingKey: embeddingKey)

        case "remember":
            guard let note = input["note"]?.stringValue, !note.isEmpty else {
                return ("Fehler: Es wurde keine Notiz übergeben.", false, "leer")
            }
            return ("Notiert.", true, note.count > 40 ? String(note.prefix(40)) + "…" : note)

        default:
            // Naming what does exist turns a dead end into a retry the model can act on.
            let available = Tools.available(searchEnabled: settings.searchEnabled && settings.activeRecipe != nil,
                                        memoryEnabled: settings.memory.isReady)
                .map(\.name).joined(separator: ", ")
            return ("Es gibt kein Werkzeug namens „\(name)“. Verfügbar sind: \(available).",
                    false, "unbekannt: \(name)")
        }
    }

    // MARK: The memory tool

    /// A short handle instead of a UUID.
    ///
    /// Thirty-six characters per line is most of the budget for a listing, and eight
    /// hex digits separate everything a personal graph will ever hold.
    private static func handle(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    private static func resolve(_ raw: String, in nodes: [MemoryNode]) -> MemoryNode? {
        let wanted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .lowercased()
        guard !wanted.isEmpty else { return nil }
        return nodes.first { handle($0.id) == wanted }
            ?? nodes.first { $0.id.uuidString.lowercased().hasPrefix(wanted) }
    }

    private static func line(_ n: MemoryNode) -> String {
        var out = "[\(handle(n.id))] \(n.name) (\(n.type))"
        if !n.nodeDescription.isEmpty { out += ": \(n.nodeDescription)" }
        if n.mentions > 1 { out += " · \(n.mentions)× erwähnt" }
        if !n.isValid { out += " · überholt" }
        return out
    }

    private static func runMemory(_ input: JSONValue, memory: MemoryConfig,
                                  embeddingKey: String) async
    -> (text: String, ok: Bool, summary: String) {
        await MemoryStore.shared.load()
        let action = input["action"]?.stringValue ?? "search"

        switch action {
        case "search":
            guard let query = input["query"]?.stringValue, !query.isEmpty else {
                return ("Fehler: „search“ braucht eine `query`.", false, "ohne Suchbegriff")
            }
            do {
                let triplets = try await Cognify.recall(question: query, memory: memory,
                                                        embeddingKey: embeddingKey)
                guard !triplets.isEmpty else {
                    return ("Dazu ist im Gedächtnis nichts hinterlegt.", true, "nichts gefunden")
                }
                // The triplet reads as a sentence; the handles below it are what the
                // model needs to change or drop anything.
                var seen = Set<UUID>()
                var lines: [String] = []
                for t in triplets.prefix(8) {
                    lines.append(t.text)
                    for n in [t.source, t.target] where seen.insert(n.id).inserted {
                        lines.append("  [\(handle(n.id))] \(n.name)")
                    }
                }
                return (lines.joined(separator: "\n"), true, "\(triplets.count) Treffer")
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return ("Die Suche im Gedächtnis schlug fehl: \(msg)", false, "fehlgeschlagen")
            }

        case "list":
            let nodes = await MemoryStore.shared.allNodes()
                .filter(\.isValid)
                .sorted { ($0.mentions, $0.updatedAt) > ($1.mentions, $1.updatedAt) }
            guard !nodes.isEmpty else {
                return ("Das Gedächtnis ist noch leer.", true, "leer")
            }
            let shown = nodes.prefix(30).map(line).joined(separator: "\n")
            let rest = nodes.count > 30 ? "\n\n[… \(nodes.count - 30) weitere]" : ""
            return (shown + rest, true, "\(nodes.count) Einträge")

        case "update":
            guard let raw = input["id"]?.stringValue,
                  let fact = input["fact"]?.stringValue,
                  !fact.trimmingCharacters(in: .whitespaces).isEmpty else {
                return ("Fehler: „update“ braucht `id` und `fact`.", false, "unvollständig")
            }
            guard var node = resolve(raw, in: await MemoryStore.shared.allNodes()) else {
                return ("Es gibt keinen Eintrag mit der Kennung „\(raw)“.", false, "nicht gefunden")
            }
            let before = node.name
            node.nodeDescription = fact
            node.updatedAt = Date()
            node.version += 1
            // The stored vector describes the old wording. Clearing it puts the node
            // back in the embedding queue instead of leaving it findable under text
            // that is no longer there.
            node.embedding = nil
            await MemoryStore.shared.replace(node)
            return ("Geändert: \(line(node))", true, before)

        case "forget":
            guard let raw = input["id"]?.stringValue else {
                return ("Fehler: „forget“ braucht eine `id`.", false, "ohne Kennung")
            }
            guard let node = resolve(raw, in: await MemoryStore.shared.allNodes()) else {
                return ("Es gibt keinen Eintrag mit der Kennung „\(raw)“.", false, "nicht gefunden")
            }
            await MemoryStore.shared.forget(nodeID: node.id)
            return ("Vergessen: \(node.name). Die Verknüpfungen dazu sind mit entfernt.",
                    true, node.name)

        default:
            return ("Unbekannte Aktion „\(action)“. Möglich sind: search, list, update, forget.",
                    false, "unbekannt: \(action)")
        }
    }

    /// Formats hits for the model.
    ///
    /// Every passage the provider returned goes in, not just the teaser: the extra
    /// snippets are usually several times longer than the description and are the
    /// difference between an answer and a guess. Source and date sit on the heading
    /// line so a citation can be written without a second call.
    private static func render(_ outcome: SearchOutcome) -> String {
        var out = ""
        if let answer = outcome.answer, !answer.isEmpty {
            out += "Zusammenfassung des Anbieters: \(answer)\n\n"
        }
        if outcome.results.isEmpty { return out + "Keine Treffer." }

        for (i, r) in outcome.results.enumerated() {
            var heading = "[\(i + 1)] \(r.title)"
            var meta: [String] = []
            if let s = r.source, !s.isEmpty { meta.append(s) }
            if let d = r.date, !d.isEmpty { meta.append(d) }
            if r.section == "news" { meta.append("Nachricht") }
            if !meta.isEmpty { heading += " — " + meta.joined(separator: ", ") }

            out += heading + "\n" + r.url + "\n"
            if !r.snippet.isEmpty { out += r.snippet + "\n" }
            for passage in r.extraText.prefix(4) {
                out += "· " + passage + "\n"
            }
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Ausweichen

    /// Das Ausweichmodell für diesen Endpoint, oder nil.
    ///
    /// Gebunden an die Basis-URL, nicht an „dies ist ein Testflight-Build": das
    /// Ausweichmodell liegt bei einem bestimmten Anbieter, und wer in derselben App
    /// seinen eigenen Endpoint einträgt, bekäme sonst einen Modellnamen vorgesetzt,
    /// den sein Anbieter nicht kennt — ein zweiter Fehlschlag statt einer Rettung.
    static func fallbackModel(for config: LLMConfig) -> String? {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard base == BundledSetup.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
              !BundledSetup.fallbackChatModel.isEmpty,
              config.model != BundledSetup.fallbackChatModel
        else { return nil }
        return BundledSetup.fallbackChatModel
    }

    /// Ob ein anderes Modell diesen Fehler überhaupt beheben könnte.
    ///
    /// Ausgenommen ist, was lokal feststeht — kein Endpoint, kein Schlüssel — und
    /// HTTP 401, weil ein falscher Schlüssel mit jedem Modellnamen falsch bleibt.
    ///
    /// **403 ist ausdrücklich dabei**, und das ist gemessen, nicht überlegt. Beim
    /// ersten Versuch stand hier `status != 403`, weil 403 nach Schlüsselproblem
    /// aussieht. Der Anbieter antwortet auf ein unbekanntes Modell aber genau so:
    /// „key not allowed to access model. This key can only access models=['public']".
    /// Das ist eine Absage an das *Modell*, nicht an den Schlüssel — also der Fall,
    /// für den das Ausweichen gebaut wurde, und er wäre still übersprungen worden.
    static func isWorthRetrying(_ error: Error) -> Bool {
        if let llm = error as? LLMError {
            switch llm {
            case .notConfigured, .missingKey: return false
            case .http(let status, _):        return status != 401
            case .transport, .decoding:       return true
            }
        }
        return true
    }

    // MARK: The loop

    /// Streams one turn. `history` is mutated in place so the caller keeps the exact
    /// message list that was sent — including the tool round trips.
    func run(
        history: inout [Message],
        onEvent: @MainActor @escaping (TurnEvent) -> Void
    ) async {
        let tools = Tools.available(searchEnabled: settings.searchEnabled && settings.activeRecipe != nil,
                                        memoryEnabled: settings.memory.isReady)
        let system = Self.systemPrompt(
            settings: settings,
            searchAvailable: settings.searchEnabled && settings.activeRecipe != nil,
            providerName: settings.activeRecipe?.name)
        let provider = ProviderFactory.make(for: config.wireFormat)

        // Veränderbar, weil bei einem Fehlschlag das Modell gewechselt wird. Die
        // Einstellungen des Nutzers bleiben unberührt — das gilt für diesen Zug.
        var activeConfig = config
        var didFallBack = false

        var iteration = 0
        while iteration < maxIterations {
            iteration += 1

            var text = ""
            var thinking = ""
            var pendingCalls: [(id: String, name: String, input: JSONValue)] = []
            var failure: String?
            var caught: Error?

            do {
                // Stamped here rather than stored: the conversation on disk stays
                // free of timestamps, and each request carries a fresh one at the end.
                for try await event in provider.stream(
                    messages: TurnContext.applied(to: history, memories: recalled),
                    system: system, tools: tools,
                    config: activeConfig, apiKey: apiKey
                ) {
                    if Task.isCancelled { break }
                    switch event {
                    case .textDelta(let d):
                        text += d
                        await onEvent(.text(d))
                    case .thinkingDelta(let d):
                        thinking += d
                        await onEvent(.thinking(d))
                    case .toolUseStarted(let id, let name):
                        await onEvent(.toolStarted(id: id, name: name, summary: ""))
                    case .toolUseCompleted(let id, let name, let input):
                        pendingCalls.append((id, name, input))
                    case .usage(let i, let o):
                        await onEvent(.usage(input: i, output: o))
                    case .stopped:
                        break
                    }
                }
            } catch is CancellationError {
                failure = nil
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                caught = error
            }

            if let failure {
                // Einmal auf das Ausweichmodell, und nur solange nichts angekommen
                // ist. Nach den ersten Zeichen wäre es kein zweiter Versuch mehr,
                // sondern eine zweite Antwort hinter der halben ersten — der Leser
                // sähe den Bruch mitten im Satz.
                if !didFallBack,
                   text.isEmpty, thinking.isEmpty, pendingCalls.isEmpty,
                   let error = caught, Self.isWorthRetrying(error),
                   let fallback = Self.fallbackModel(for: activeConfig) {
                    didFallBack = true
                    activeConfig.model = fallback
                    iteration -= 1          // dieselbe Runde noch einmal
                    continue
                }
                await onEvent(.failed(failure))
                return
            }

            // Record the assistant turn exactly as it came back.
            var blocks: [ContentBlock] = []
            if !thinking.isEmpty { blocks.append(.thinking(thinking)) }
            if !text.isEmpty { blocks.append(.text(text)) }
            for c in pendingCalls { blocks.append(.toolUse(id: c.id, name: c.name, input: c.input)) }

            if blocks.isEmpty {
                await onEvent(.failed("Das Modell hat nichts zurückgegeben."))
                return
            }
            var reply = Message(role: .assistant, blocks: blocks)
            // Das Modell, das wirklich geantwortet hat — nicht das eingestellte.
            reply.producedBy = activeConfig.model
            history.append(reply)

            guard !pendingCalls.isEmpty else {
                await onEvent(.finished)
                return
            }
            if Task.isCancelled { await onEvent(.finished); return }

            // Parallel calls run concurrently, and every result goes back in one
            // user message — splitting them teaches the model to stop parallelising.
            var results = [ContentBlock?](repeating: nil, count: pendingCalls.count)
            await withTaskGroup(of: (Int, ContentBlock, Bool, String).self) { group in
                for (i, call) in pendingCalls.enumerated() {
                    group.addTask {
                        let r = await execute(name: call.name, input: call.input)
                        return (i, .toolResult(toolUseID: call.id, content: r.text, isError: !r.ok),
                                r.ok, r.summary)
                    }
                }
                for await (i, block, ok, summary) in group {
                    results[i] = block
                    await onEvent(.toolFinished(id: pendingCalls[i].id, ok: ok, summary: summary))
                }
            }
            history.append(Message(role: .user, blocks: results.compactMap { $0 }))
        }

        await onEvent(.failed("Abgebrochen nach \(maxIterations) Werkzeugrunden."))
    }
}
