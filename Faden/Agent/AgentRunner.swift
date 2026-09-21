import Foundation

/// What the UI observes while a turn is in flight.
enum TurnEvent {
    case thinking(String)
    case text(String)
    case toolStarted(id: String, name: String, summary: String)
    case toolFinished(id: String, ok: Bool, summary: String)
    /// A tool that takes long enough to be worth watching says how far it is.
    ///
    /// Only reading documents does this. The others are one request each and finish
    /// before a bar would have drawn; reading a folder is minutes, and a spinner that
    /// says nothing for minutes is indistinguishable from a hang.
    case toolProgress(id: String, done: Int, total: Int)
    case usage(input: Int?, output: Int?)
    /// The provider named its own limits in a refusal.
    ///
    /// The only honest source for an endpoint that publishes none. The app used to ask
    /// by sending an absurd upper bound; that is gone. What arrives here was triggered
    /// by a real turn.
    case learnedLimits(context: Int?, output: Int?)
    /// The answer length grew out of use.
    ///
    /// Not guessed and not probed: a turn was cut off at this limit, and that is the
    /// occasion.
    case grewOutputBudget(Int)
    /// The turn starts over. What was visible so far no longer holds.
    case restarted(reason: String)
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
    /// The short prompt for Apple's on-device model.
    ///
    /// The long prompt describes web search, `fetch_page`, memory recall and a block in
    /// square brackets at the end of the user message. This model has none of that — and
    /// it obliged at once by announcing that it would look in the memory instead of
    /// answering. A small model recounts what stands in the prompt, not what it can do.
    ///
    /// The date sits in here rather than at the end of the message: there the model
    /// copied it into the answer, against explicit instruction. The caching reason it
    /// sits at the back for network providers does not apply here anyway.
    static func compactSystemPrompt(settings: AppSettings, at date: Date = Date()) -> String {
        let persona = settings.persona
        let df = DateFormatter()
        df.locale = Locale(identifier: "de_DE")
        df.timeZone = .current
        df.dateFormat = "EEEE, d. MMMM yyyy, HH:mm"
        var s = """
        Du bist \(persona.displayName), ein Assistent auf dem iPhone deines Nutzers. Du \
        antwortest auf Deutsch, ausser der Nutzer schreibt in einer anderen Sprache.

        Jetzt ist \(df.string(from: date)) Uhr.

        So schreibst du:
        - Direkt zur Sache, ohne Einleitung und ohne Rueckblick am Ende.
        - Kurz. Zwei bis vier Saetze, ausser es wird ausdruecklich mehr verlangt.
        - Was du nicht weisst, sagst du. Du erfindest keine Zahlen, Namen und Quellen.
        - Du kuendigst nichts an, was du tun wirst. Du antwortest.

        Du hast keine Werkzeuge: keine Websuche, keinen Zugriff auf Dateien und keinen \
        auf ein Gedaechtnis. Braeuchte eine Frage das, sagst du es in einem Satz.
        """
        if !persona.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "\n\n" + persona.instructions
        }
        return s
    }

    static func systemPrompt(settings: AppSettings, searchAvailable: Bool,
                             providerName: String?, inventoryAvailable: Bool,
                             folderAvailable: Bool) -> String {
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

        if inventoryAvailable {
            s += """


            Zum Bestand in Fundus:
            - Fragt jemand, wo etwas liegt, wie viel er davon hat oder was an einem Ort \
            steht, siehst du mit inventory nach, statt aus dem Gespräch zu schließen. \
            Ein Bestand ist genau die Sorte Frage, bei der eine plausible Antwort \
            schlechter ist als keine.
            - Kennst du die Ortsnamen nicht, holst du sie dir mit „places“ und suchst \
            danach gezielt.
            - Was dort nicht steht, ist nicht „nicht vorhanden“, sondern nicht \
            eingetragen. Den Unterschied sagst du.
            - Du kannst nur lesen. Bittet dich jemand, etwas einzutragen oder zu ändern, \
            sagst du, dass das in Fundus selbst geschieht.
            """
        }

        if folderAvailable {
            s += """


            Zum freigegebenen Ordner:
            - Der Nutzer hat dir einen Ordner geöffnet, meist aus Spind. Geht es um eine \
            Datei, ein Dokument oder etwas, das „bei mir liegt", siehst du mit files nach, \
            statt zu fragen, wo es liegt.
            - Kennst du den Namen ungefähr, nimmst du „find". Dich Ebene für Ebene durch \
            „list" zu hangeln kostet je eine Runde.
            - Du liest nur, was die Frage braucht. Einen Ordner der Reihe nach \
            durchzulesen ist keine Recherche, sondern verbraucht den Kontext.
            - Du kannst nichts schreiben, umbenennen oder löschen. Wird das verlangt, \
            sagst du es, statt es zu versprechen.
            """
        }

        // Once, and only when something can actually bring foreign text in. The
        // paragraph explains marks — in a build where nothing produces them it would be
        // a rule about an event that cannot occur, and the room it takes is paid for.
        let fenced = Tools.fencedTools(searchEnabled: searchAvailable,
                                       folderEnabled: folderAvailable)
        if !fenced.isEmpty {
            s += "\n\n\n" + UntrustedContent.rule(for: fenced)
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

    private func execute(name: String, input: JSONValue,
                         onProgress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in })
    async -> (text: String, ok: Bool, summary: String) {
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
                // Fenced: result texts are foreign content like any page. A search
                // result is in fact the more convenient place for an attack — optimise
                // a page for a keyword and your text lands in front of the model
                // without anyone having to call it up.
                let fenced = UntrustedContent.wrap(Self.render(outcome),
                                                   source: "Websuche „\(query)“")
                return (fenced, true, "\(outcome.results.count) Treffer")
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
            // An error message comes from us and stays unwrapped; everything else is
            // the text of a foreign page.
            return (ok ? UntrustedContent.wrap(text, source: url) : text,
                    ok, ok ? "\(text.count) Zeichen" : "nicht ladbar")

        case "memory":
            guard settings.memory.isReady else {
                return ("Fehler: Es ist kein Gedächtnis eingerichtet.", false, "nicht eingerichtet")
            }
            return await Self.runMemory(input, memory: settings.memory, embeddingKey: embeddingKey)

        case "inventory":
            guard settings.inventoryEnabled, FundusInventory.isPresent else {
                return ("Fehler: Es ist kein Bestand erreichbar.", false, "nicht erreichbar")
            }
            return await Self.runInventory(input)

        case "files":
            guard let bookmark = settings.folder.bookmark else {
                return ("Fehler: Es ist kein Ordner freigegeben.", false, "nicht eingerichtet")
            }
            return await FolderReader.shared.run(input, bookmark: bookmark,
                                                 name: settings.folder.name,
                                                 onProgress: onProgress)

        case "remember":
            guard let note = input["note"]?.stringValue, !note.isEmpty else {
                return ("Fehler: Es wurde keine Notiz übergeben.", false, "leer")
            }
            return ("Notiert.", true, note.count > 40 ? String(note.prefix(40)) + "…" : note)

        default:
            // Naming what does exist turns a dead end into a retry the model can act on.
            let available = Tools.available(searchEnabled: settings.searchEnabled && settings.activeRecipe != nil,
                                        memoryEnabled: settings.memory.isReady,
                                        inventoryEnabled: settings.inventoryEnabled && FundusInventory.isPresent,
                                        folderEnabled: settings.folder.isSet)
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

    // MARK: The inventory tool

    /// Reads Fundus's stock. Thin on purpose — searching and rendering sit with the
    /// data in `FundusInventory`, where they can be tested without a turn.
    ///
    /// Not fenced with `UntrustedContent`, and that is a decision rather than an
    /// oversight. The fence says in so many words that what follows comes from the net,
    /// and for this it would be false: the inventory is local, it is the user's own,
    /// and nothing enters it in Fundus without a tick. Fencing it anyway would buy no
    /// protection and spend the one thing the fence lives on — that it means something
    /// where it stands. The day a tool writes back into the inventory, or pulls text
    /// that nobody confirmed into it, this sentence has to be read again.
    private static func runInventory(_ input: JSONValue) async
    -> (text: String, ok: Bool, summary: String) {
        let inventory = await FundusReader.shared.inventory()
        let action = input["action"]?.stringValue ?? "search"
        let place = input["place"]?.stringValue
        let query = input["query"]?.stringValue ?? ""

        switch action {
        case "places":
            return (inventory.renderPlaces(), true,
                    inventory.places.isEmpty ? "keine Orte" : "\(inventory.places.count) Orte")

        case "search":
            guard !inventory.items.isEmpty else {
                return ("Der Bestand ist leer — in Fundus ist noch nichts eingetragen.",
                        true, "leer")
            }
            // A place the inventory does not know is worth its own answer: the model
            // asked for a shelf by a name it guessed, and the list of real names turns
            // that into one more call instead of a wrong "nothing there".
            if let place, !place.trimmingCharacters(in: .whitespaces).isEmpty,
               inventory.places(matching: place).isEmpty {
                return ("""
                    Einen Ort „\(place)“ gibt es im Bestand nicht.

                    \(inventory.renderPlaces())
                    """, false, "Ort unbekannt: \(place)")
            }
            let lookup = inventory.search(query, place: place)
            let text = FundusInventory.render(lookup, query: query, place: place)
            let label = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? (place ?? "alles") : query
            return (text, true, "\(lookup.total)× \(label)")

        default:
            return ("Es gibt keine Aktion „\(action)“. Möglich sind: search, places.",
                    false, "unbekannt: \(action)")
        }
    }

    // MARK: Ausweichen

    // Which model handles a turn and what it falls back to now lives in `LLMConfig` —
    // `model(forImages:)` and `fallback(forImages:after:)`. There, because it weighs
    // four fields of the same configuration against each other and needs nothing else;
    // it only stood here while the answer came from the build.

    /// Whether another model could fix this error at all.
    ///
    /// Excluded is everything settled locally — no endpoint, no key — and HTTP 401,
    /// because a wrong key stays wrong with every model name.
    ///
    /// **403 is expressly included**, and that is measured, not reasoned. The first
    /// attempt had `status != 403` here, because a 403 looks like a key problem. But
    /// this is exactly how the provider answers for an unknown model:
    /// “key not allowed to access model. This key can only access models=['public']”.
    /// That is a refusal aimed at the *model*, not at the key — so the very case the
    /// fallback was built for, and it would have been skipped in silence.
    // MARK: Answer length

    /// Whether the turn ran out of room.
    ///
    /// Two signs. The provider says so — “max_tokens”, “length” — or it says nothing
    /// and sends a turn consisting of **nothing but** reasoning: no text, no tool call,
    /// and finished all the same. The second is the case the app used to book silently
    /// as a finished answer.
    ///
    /// A turn with a tool call does not count, even when no text came with it: that is
    /// the normal shape of a round in which the model wants to look something up first.
    static func ranOutOfRoom(stopReason: String?, text: String,
                             thinking: String, toolCalls: Int) -> Bool {
        if stopReason == "max_tokens" || stopReason == "length" { return true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !thinking.isEmpty && toolCalls == 0
    }

    /// Whether the turn may start over.
    ///
    /// Only when there is nothing to lose. If text already stands on screen, a fresh
    /// attempt would not be a second try but a step backwards: the reader would watch
    /// half an answer disappear and wait from the beginning. The grown number stays put
    /// all the same — the next turn starts high.
    static func shouldAskAgain(text: String, toolCalls: Int, alreadyGrew: Int) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && toolCalls == 0
            && alreadyGrew < maxGrowths
    }

    /// How often a turn may add more room.
    ///
    /// Three doublings, so from 4,096 at most 32,768 in one round. Each one costs the
    /// whole request again — the history travels with it every time — which is why
    /// there is a limit here and not “until it fits”. What was learned in this round
    /// stays: the next turn starts high.
    static let maxGrowths = 3

    /// The last barrier when the provider names none.
    ///
    /// No model today writes more than this in one turn. Whoever has one sets the
    /// number by hand — and switches the growing off in doing so.
    static let outputCeiling = 128_000

    /// The next answer length when the last one was not enough.
    ///
    /// Doubling and not guessing. The app used to send an absurd upper bound to learn
    /// the real one; that is gone and must not come back. What happens here is the
    /// answer to a turn that actually hit the limit.
    ///
    /// `nil` means: this is the end. Either the provider stands in the way with the
    /// limit it named, or the last barrier does.
    static func nextOutputBudget(after current: Int, ceiling: Int?) -> Int? {
        let doubled = current * 2
        if let ceiling {
            guard current < ceiling else { return nil }
            return min(doubled, ceiling)
        }
        guard doubled <= outputCeiling else { return nil }
        return doubled
    }

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
        // Apple's model has no tools, and a prompt describing some makes it talk
        // about them instead of answering.
        let onDevice = config.wireFormat == .appleOnDevice
        let inventoryAvailable = settings.inventoryEnabled && FundusInventory.isPresent
        let folderAvailable = settings.folder.isSet
        let tools = onDevice ? [] : Tools.available(
            searchEnabled: settings.searchEnabled && settings.activeRecipe != nil,
            memoryEnabled: settings.memory.isReady,
            inventoryEnabled: inventoryAvailable,
            folderEnabled: folderAvailable)
        let system = onDevice
            ? Self.compactSystemPrompt(settings: settings)
            : Self.systemPrompt(
                settings: settings,
                searchAvailable: settings.searchEnabled && settings.activeRecipe != nil,
                providerName: settings.activeRecipe?.name,
                inventoryAvailable: inventoryAvailable,
                folderAvailable: folderAvailable)
        let provider = ProviderFactory.make(for: config.wireFormat)

        // Does an image hang on this turn? Asked across the whole history and not
        // only the last message: every request carries the entire conversation, so the
        // image from ten turns ago as well. Check only the last message and you send it
        // to a model that cannot see.
        let hasImages = history.contains(where: \.hasImage)

        // Mutable, because the model is switched on a failure. The user's settings
        // stay untouched — this holds for this turn only.
        var activeConfig = config
        activeConfig.model = config.model(forImages: hasImages)
        var didFallBack = false
        var grewTimes = 0

        var iteration = 0
        while iteration < maxIterations {
            iteration += 1

            var text = ""
            var thinking = ""
            var pendingCalls: [(id: String, name: String, input: JSONValue)] = []
            var failure: String?
            var caught: Error?
            var stopReason: String?

            do {
                // Stamped here rather than stored: the conversation on disk stays
                // free of timestamps, and each request carries a fresh one at the end.
                for try await event in provider.stream(
                    // Without the memory block and without the timestamp: both stood
                    // at the end of the user message, and the small model obeyed one
                    // as if it were a question and copied the other into the answer.
                    messages: onDevice ? history
                                       : TurnContext.applied(to: history, memories: recalled),
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
                    case .stopped(let reason):
                        // Thrown away before, and that was the mistake: a turn that
                        // spends its whole budget on reasoning looks, without this
                        // reason, like a finished answer.
                        stopReason = reason
                    }
                }
            } catch is CancellationError {
                failure = nil
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                caught = error
            }

            if let failure {
                // A refusal that names a number is the only chance to learn the
                // limits of a provider that publishes none. It passes through here
                // whether the fallback happens or not.
                if let llm = caught as? LLMError, case .http(_, let body) = llm {
                    let limits = ModelCatalog.extractLimits(from: body)
                    if limits.context != nil || limits.output != nil {
                        await onEvent(.learnedLimits(context: limits.context,
                                                     output: limits.output))
                    }
                }

                // Once to the fallback model, and only while nothing has arrived.
                // After the first characters it would no longer be a second try but a
                // second answer behind half of the first — the reader would see the
                // break mid-sentence.
                if !didFallBack,
                   text.isEmpty, thinking.isEmpty, pendingCalls.isEmpty,
                   let error = caught, Self.isWorthRetrying(error),
                   let fallback = config.fallback(forImages: hasImages,
                                                  after: activeConfig.model) {
                    didFallBack = true
                    activeConfig.model = fallback
                    iteration -= 1          // dieselbe Runde noch einmal
                    continue
                }
                await onEvent(.failed(failure))
                return
            }

            // The budget was not enough.
            //
            // Two signs of it. The provider says so — “max_tokens”, “length” — or it
            // says nothing and sends a turn consisting of nothing but reasoning: no
            // text, no tool call, and finished all the same. The second is the case the
            // app used to book silently as a finished answer, and to a user it looks as
            // if the thinking stopped mid-sentence.
            let ranOut = Self.ranOutOfRoom(stopReason: stopReason, text: text,
                                           thinking: thinking, toolCalls: pendingCalls.count)
            if ranOut, !config.maxOutputTokensIsCustom,
               let bigger = Self.nextOutputBudget(after: activeConfig.maxOutputTokens,
                                                  ceiling: activeConfig.reportedOutputLimit) {
                activeConfig.maxOutputTokens = bigger
                await onEvent(.grewOutputBudget(bigger))

                // The budget always grows; the turn is only asked again when there
                // is nothing to lose. If text already arrived, half an answer is worth
                // more than a whole one that makes the reader wait twice — and the
                // grown number already stands ready for the next turn.
                if Self.shouldAskAgain(text: text, toolCalls: pendingCalls.count,
                                       alreadyGrew: grewTimes) {
                    grewTimes += 1
                    await onEvent(.restarted(reason: String(
                        localized: "Der Gedankengang war länger als der Vorrat. Antwortlänge auf \(bigger) Token erhöht.")))
                    iteration -= 1      // dieselbe Runde noch einmal, mit mehr Luft
                    continue
                }
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
            // The model that actually answered — not the one that was configured.
            reply.producedBy = activeConfig.model
            history.append(reply)

            guard !pendingCalls.isEmpty else {
                await onEvent(.finished)
                return
            }
            if Task.isCancelled {
                // Do not simply bail out: the calls already stand in the history, and
                // without results beside them the provider refuses *every* further
                // request in this conversation — the whole history travels along every
                // time. So the cancellation is written down rather than kept quiet.
                history.append(Message(role: .user, blocks: pendingCalls.map {
                    .toolResult(toolUseID: $0.id, content: "Abgebrochen.", isError: true)
                }))
                await onEvent(.finished)
                return
            }

            // Parallel calls run concurrently, and every result goes back in one
            // user message — splitting them teaches the model to stop parallelising.
            var results = [ContentBlock?](repeating: nil, count: pendingCalls.count)
            await withTaskGroup(of: (Int, ContentBlock, Bool, String).self) { group in
                for (i, call) in pendingCalls.enumerated() {
                    let callID = call.id
                    group.addTask {
                        let r = await execute(name: call.name, input: call.input) { done, total in
                            await onEvent(.toolProgress(id: callID, done: done, total: total))
                        }
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
