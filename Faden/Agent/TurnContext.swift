import Foundation

/// Everything that differs from one request to the next — the clock, and whatever the
/// memory graph recalled for this particular question.
///
/// Both belong at the *end*, not in the system prompt. Prompt caching matches on an
/// exact prefix, and the render order is tools → system → messages: anything volatile
/// in the system prompt changes the first bytes of every request, so nothing after it
/// can ever be reused and every turn is billed in full. Measured on this app's own
/// prompt, wechselnde Erinnerungen brachen den gemeinsamen Präfix schon nach 1965 von
/// 2521 Zeichen.
///
/// Appended to the last user message, both sit past any cache breakpoint, on content
/// that is new anyway.
enum TurnContext {

    static func stamp(_ date: Date = Date(), locale: Locale = Locale(identifier: "de_DE")) -> String {
        let df = DateFormatter()
        df.locale = locale
        df.timeZone = .current
        df.dateFormat = "EEEE, d. MMMM yyyy, HH:mm"
        return "[Jetzt: \(df.string(from: date)) Uhr, \(TimeZone.current.identifier)]"
    }

    /// Renders recalled triplets as the block that precedes the timestamp.
    static func memoryBlock(_ triplets: [Triplet]) -> String {
        guard !triplets.isEmpty else { return "" }
        return """
        [Was du aus früheren Gesprächen über den Nutzer weißt:
        \(TripletSearch.context(from: triplets))
        Nutze es beiläufig, ohne es zu erwähnen. Widerspricht es dem, was gerade gesagt \
        wird, gilt das Neue.]
        """
    }

    /// Appends memories and the timestamp to the last message the user actually wrote.
    ///
    /// Only the last one: an older turn carrying an old timestamp would read as a
    /// contradiction, and stamping tool results would move the volatile part into the
    /// middle of the conversation, where it would again spoil the prefix on the next
    /// request.
    static func applied(to messages: [Message],
                        memories: [Triplet] = [],
                        at date: Date = Date()) -> [Message] {
        guard let index = messages.lastIndex(where: { message in
            message.role == .user && message.blocks.contains { block in
                if case .text = block { return true }
                return false
            }
        }) else { return messages }

        var out = messages
        var message = out[index]
        // Attach to the final text block so the stamp trails the question itself.
        guard let blockIndex = message.blocks.lastIndex(where: { block in
            if case .text = block { return true }
            return false
        }), case .text(let existing) = message.blocks[blockIndex] else { return messages }

        var suffix = ""
        let memory = memoryBlock(memories)
        if !memory.isEmpty { suffix += "\n\n" + memory }
        suffix += "\n\n" + stamp(date)
        message.blocks[blockIndex] = .text(existing + suffix)
        out[index] = message
        return out
    }
}
