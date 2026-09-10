import Foundation

/// Names a conversation after what it turned out to be about.
///
/// The opening message is a poor title — a thread that starts with "kurze Frage"
/// may end up being about deployment pipelines. So once a few turns exist, the model
/// reads them and writes a short label, and it does so again whenever the thread has
/// roughly doubled in length, because by then the subject has usually moved on.
struct Titler {
    let config: LLMConfig
    let apiKey: String

    private static let systemPrompt = """
    Du benennst eine Unterhaltung. Antworte mit einem kurzen Titel und sonst nichts: \
    zwei bis fünf Wörter, keine Anführungszeichen, kein Punkt am Ende, keine Einleitung. \
    Der Titel benennt das Thema, nicht die Form — also „Umzug nach Lissabon" statt \
    „Frage zum Umzug". Nutze die Sprache der Unterhaltung.
    """

    /// True when it is worth spending a call on a new title.
    static func shouldTitle(_ conversation: Conversation) -> Bool {
        let count = conversation.messages.count
        guard count >= 4 else { return false }
        if conversation.titledAtMessageCount == 0 { return true }
        return count >= conversation.titledAtMessageCount * 2
    }

    func title(for conversation: Conversation) async -> String? {
        // Only the substance, and only the beginning of it: the first exchanges say
        // what a thread is about, and a short prompt keeps this cheap.
        let lines: [String] = conversation.messages.prefix(12).compactMap { m in
            let text = m.blocks.compactMap { block -> String? in
                if case .text(let t) = block, !t.isEmpty { return t }
                if case .image = block { return "[Bild]" }
                return nil
            }.joined(separator: " ")
            guard !text.isEmpty else { return nil }
            return "\(m.role == .user ? "Nutzer" : "Assistent"): \(text.prefix(400))"
        }
        guard lines.count >= 2 else { return nil }

        let provider = ProviderFactory.make(for: config.wireFormat)
        guard let raw = try? await withTimeout(seconds: 60, {
            try await provider.complete(
                messages: [Message(role: .user, text: lines.joined(separator: "\n"))],
                system: Self.systemPrompt,
                config: config, apiKey: apiKey,
                maxTokens: max(2000, min(4000, config.maxOutputTokens)))
        }) else { return nil }

        return Self.clean(raw)
    }

    /// Models like to wrap titles in quotes or add a trailing period.
    static func clean(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // If it answered in several lines, the title is the last non-empty one.
        if let last = t.components(separatedBy: .newlines).last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) { t = last.trimmingCharacters(in: .whitespaces) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»„“”*#-–—. "))
        guard !t.isEmpty, t.count <= 60 else { return nil }
        return t
    }
}
