import Foundation

/// What may pass from a foreign file into your own history.
///
/// A shared conversation is convenient and harmless as long as you read it. It becomes
/// something else the moment you write on in it: from then on it travels with every
/// request as prehistory, and what stands in it as an *assistant turn* is read by the
/// model as its own earlier output. No language model weighs the two equally — its own
/// prehistory weighs more than any request from the user.
///
/// Three things are therefore removed on import, and each has a concrete occasion:
///
///  - **Reasoning.** It is collapsed in the interface and is sent back by no provider —
///    so it is invisible *and* ineffective when genuine. A forged one would be the
///    opposite: the most persuasive voice in the whole history, because it sounds like
///    the model talking to itself. Something that can only do harm is left outside.
///  - **The “summary” flag.** The system instruction says it verbatim: if a summary
///    appears in the history, it is authoritative. That very flag is something a file
///    can set. A foreign file must not declare its own content authoritative.
///  - **Tool calls without results and results without calls.** That is less an attack
///    than a defect, and an expensive one: providers refuse a history with an
///    unanswered call — *every* further request in this conversation, because the
///    history travels along every time. A file could therefore produce a conversation
///    in which nothing can ever be sent again.
///
/// Plus two upper bounds. A file from someone else's hand would otherwise decide how
/// much storage the app takes and how large the context is on the next turn — and
/// context is paid for.
enum ImportGuard {

    /// How large the file may be. One image already turns six messages into 340,000
    /// characters; eight megabytes therefore hold every conversation somebody really
    /// passes on, and none meant as a weapon.
    static let maxBytes = 8 * 1024 * 1024
    /// This many messages. What is kept is the **end**: that is where the thing
    /// somebody wants to write on stands.
    static let maxMessages = 2_000
    static let maxBlocksPerMessage = 200

    struct Outcome {
        var conversation: Conversation
        /// What was removed, in one sentence for the user — or empty.
        var note: String?
    }

    static func sanitised(_ incoming: Conversation) -> Outcome {
        var c = incoming
        var droppedThinking = 0
        var droppedSummaries = 0
        var droppedToolBlocks = 0
        var droppedMessages = 0

        if c.messages.count > maxMessages {
            droppedMessages = c.messages.count - maxMessages
            c.messages = Array(c.messages.suffix(maxMessages))
        }

        // Which tool calls in the history are answered, and the other way round.
        var answeredCalls: Set<String> = []
        var presentCalls: Set<String> = []
        for m in c.messages {
            for b in m.blocks {
                if case .toolUse(let id, _, _) = b { presentCalls.insert(id) }
                if case .toolResult(let id, _, _) = b { answeredCalls.insert(id) }
            }
        }

        c.messages = c.messages.compactMap { message in
            var m = message
            if m.isCompactionSummary { droppedSummaries += 1 }
            m.isCompactionSummary = false
            m.replacedMessageCount = 0

            var kept: [ContentBlock] = []
            for block in m.blocks.prefix(maxBlocksPerMessage) {
                switch block {
                case .thinking:
                    droppedThinking += 1
                case .toolUse(let id, _, _):
                    if answeredCalls.contains(id) { kept.append(block) } else { droppedToolBlocks += 1 }
                case .toolResult(let id, _, _):
                    if presentCalls.contains(id) { kept.append(block) } else { droppedToolBlocks += 1 }
                case .text, .image:
                    kept.append(block)
                }
            }
            if m.blocks.count > maxBlocksPerMessage {
                droppedToolBlocks += m.blocks.count - maxBlocksPerMessage
            }
            m.blocks = kept
            // A message without content is none. Leaving it in place would mean
            // sending the provider an empty role, and some refuse that.
            return kept.isEmpty ? nil : m
        }

        var parts: [String] = []
        if droppedMessages > 0 { parts.append(String(localized: "\(droppedMessages) ältere Nachrichten")) }
        if droppedThinking > 0 { parts.append(String(localized: "\(droppedThinking) Gedankengänge")) }
        if droppedSummaries > 0 { parts.append(String(localized: "\(droppedSummaries) als „Zusammenfassung“ markierte Züge")) }
        if droppedToolBlocks > 0 { parts.append(String(localized: "\(droppedToolBlocks) unvollständige Werkzeugschritte")) }

        let removed = parts.joined(separator: ", ")
        return Outcome(conversation: c,
                       note: parts.isEmpty ? nil
                           : String(localized: "Beim Übernehmen entfernt: \(removed)."))
    }
}
