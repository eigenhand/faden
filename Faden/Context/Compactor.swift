import Foundation

/// Condenses a long conversation so it keeps fitting in the window.
///
/// The approach mirrors what a careful assistant does by hand: everything up to a
/// safe cut is rewritten into a structured brief — task, established facts with their
/// sources, decisions, open threads, verbatim details — while the most recent turns
/// stay untouched, because that is where the live thread of the conversation is.
/// Notes the model wrote with the `remember` tool are carried over word for word.
struct Compactor {

    let config: LLMConfig
    let apiKey: String

    private static let systemPrompt = """
    Du verdichtest den bisherigen Verlauf einer Unterhaltung, damit er weniger Platz \
    braucht. Die Zusammenfassung ersetzt den Verlauf vollständig — was du weglässt, ist \
    für den weiteren Gesprächsverlauf verloren. Schreibe daher dicht, aber vollständig.

    Gliedere genau so, und lass Abschnitte weg, die leer wären:

    ## Auftrag
    Was der Nutzer will, in seinen eigenen Worten. Auch Vorgaben zu Form, Sprache und \
    Tonfall, die er unterwegs gemacht hat.

    ## Stand
    Was inhaltlich erarbeitet oder herausgefunden wurde. Fakten mit Quelle, wenn eine \
    genannt wurde. Zahlen, Namen, URLs und Zitate wörtlich übernehmen — niemals \
    umschreiben oder runden.

    ## Entscheidungen
    Was festgelegt wurde und warum, einschließlich verworfener Alternativen mit Grund.

    ## Offen
    Was noch aussteht, wo der nächste Schritt liegt, welche Fragen unbeantwortet blieben.

    Regeln:
    - Schreibe im Präteritum über den Verlauf, sachlich, ohne Anrede.
    - Keine Einleitung, kein Fazit, keine Meta-Kommentare über die Zusammenfassung.
    - Erfinde nichts. Was du nicht sicher weißt, lässt du weg.
    - Lieber ein Detail zu viel als ein verlorener Faden.
    """

    /// True for a user message that starts a fresh turn — one carrying no tool
    /// results, so cutting in front of it orphans nothing.
    private static func opensTurn(_ m: Message) -> Bool {
        guard m.role == .user else { return false }
        return !m.blocks.contains { block in
            if case .toolResult = block { return true }
            return false
        }
    }

    /// Finds a cut that does not orphan a tool result from its tool call.
    /// Returns the index of the first message that stays verbatim.
    static func safeCutIndex(_ messages: [Message], keepingAtLeast keep: Int) -> Int? {
        guard messages.count > keep + 2 else { return nil }
        let target = messages.count - keep

        // Prefer the latest turn opener at or before the target, which keeps at
        // least `keep` messages verbatim.
        var idx = target
        while idx > 0 {
            if opensTurn(messages[idx]) { return idx }
            idx -= 1
        }

        // A single long tool exchange can span everything before the target — the
        // agentic case, and exactly when compaction matters most. Fall forward to
        // the next opener and keep fewer messages rather than give up entirely.
        idx = target + 1
        while idx < messages.count - 1 {
            if opensTurn(messages[idx]) { return idx }
            idx += 1
        }
        return nil
    }

    /// Notes are the one thing that survives verbatim.
    static func collectNotes(_ messages: [Message]) -> [String] {
        messages.flatMap { m in
            m.blocks.compactMap { b -> String? in
                if case .toolUse(_, let name, let input) = b, name == "remember" {
                    return input["note"]?.stringValue
                }
                return nil
            }
        }
    }

    struct Result {
        var messages: [Message]
        var summaryText: String
        var replacedCount: Int
    }

    /// Runs the compaction. Returns nil when there is nothing worth compacting.
    func compact(_ messages: [Message], keepingRecent keep: Int) async throws -> Result? {
        guard let cut = Self.safeCutIndex(messages, keepingAtLeast: keep) else { return nil }

        let older = Array(messages[..<cut])
        let recent = Array(messages[cut...])
        guard older.count >= 2 else { return nil }

        let transcript = Self.render(older)
        let notes = Self.collectNotes(older)

        var built = "Der zu verdichtende Verlauf:\n\n\(transcript)"
        if !notes.isEmpty {
            built += "\n\nDiese Notizen wurden ausdrücklich festgehalten und müssen "
                + "vollständig in der Zusammenfassung auftauchen:\n"
                + notes.map { "- \($0)" }.joined(separator: "\n")
        }
        let prompt = built

        let provider = ProviderFactory.make(for: config.wireFormat)
        let summary = try await withTimeout(seconds: 120) {
            try await provider.complete(
                messages: [Message(role: .user, text: prompt)],
                system: Self.systemPrompt,
                config: config, apiKey: apiKey,
                maxTokens: min(3000, config.maxOutputTokens))
        }

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var marker = Message(role: .user, text: """
        [Zusammenfassung des bisherigen Verlaufs — der ursprüngliche Wortlaut steht \
        nicht mehr zur Verfügung, diese Fassung ist maßgeblich.]

        \(trimmed)
        """)
        marker.isCompactionSummary = true
        marker.replacedMessageCount = older.count

        // The summary takes the place of the history, so the thread still opens with
        // a user turn — which is what both wire formats expect.
        var out: [Message] = [marker]
        out.append(Message(role: .assistant, text: "Verstanden, ich habe den bisherigen Stand."))
        out.append(contentsOf: recent)

        return Result(messages: out, summaryText: trimmed, replacedCount: older.count)
    }

    /// Flattens messages into a readable transcript for the summarising model.
    static func render(_ messages: [Message]) -> String {
        var out: [String] = []
        for m in messages {
            var parts: [String] = []
            for b in m.blocks {
                switch b {
                case .text(let t):
                    if !t.isEmpty { parts.append(t) }
                case .thinking:
                    continue
                case .image:
                    parts.append("[Bild angehaengt]")
                case .toolUse(_, let name, let input):
                    parts.append("→ \(name)(\(input.compactDescription))")
                case .toolResult(_, let c, let isError):
                    // Tool output is the bulk of an agentic transcript and the least
                    // worth repeating in full — the summary needs the gist, not the
                    // page. Sending it whole made the request slow enough to hang.
                    let capped = c.count > 400 ? String(c.prefix(400)) + " […]" : c
                    parts.append(isError ? "← Fehler: \(capped)" : "← \(capped)")
                }
            }
            guard !parts.isEmpty else { continue }
            let who = m.role == .user ? "Nutzer" : "Assistent"
            out.append("\(who): \(parts.joined(separator: "\n"))")
        }
        return cap(out.joined(separator: "\n\n"))
    }

    /// Hard ceiling on what goes to the model. Keeps the opening (the task) and the
    /// tail (the live thread) and drops the middle, which is where redundancy sits.
    private static let transcriptLimit = 12_000

    static func cap(_ text: String) -> String {
        guard text.count > transcriptLimit else { return text }
        let head = text.prefix(transcriptLimit / 3)
        let tail = text.suffix(transcriptLimit * 2 / 3)
        return head + "\n\n[… mittlerer Teil des Verlaufs ausgelassen …]\n\n" + tail
    }
}
