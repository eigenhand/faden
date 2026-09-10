import Foundation

/// Everything that happened between a question and its answer.
struct Preparation: Equatable {
    var thinking: String = ""
    var steps: [ToolStep] = []

    var isEmpty: Bool { thinking.isEmpty && steps.isEmpty }
}

/// Folds a turn's working into a single item.
///
/// One question can produce several assistant messages — think, call a tool, think
/// again, then answer — and rendering each one separately left a single exchange
/// looking like four. The reader does not care where the message boundaries fell;
/// they care what was asked, what was done, and what came back.
///
/// So the messages that carry no answer are absorbed into the one that does, and the
/// whole turn's thinking and tool calls end up behind one control above the answer.
/// A turn that never reached an answer — stopped, or failed — keeps its messages
/// visible, because there is nothing to fold them into and hiding them would erase
/// what the app was doing when it stopped.
enum TurnFolding {

    static func plan(for messages: [Message], failedToolIDs: Set<String>)
    -> (preparations: [UUID: Preparation], absorbed: Set<UUID>) {

        var preparations: [UUID: Preparation] = [:]
        var absorbed: Set<UUID> = []
        var pending = Preparation()
        var pendingIDs: [UUID] = []

        func reset() { pending = Preparation(); pendingIDs = [] }

        for message in messages {
            if message.isCompactionSummary { reset(); continue }

            if message.role == .user {
                // A user message carrying real text starts a new turn. One carrying
                // only tool results is plumbing — it belongs to the turn already
                // running, and drawing it leaves an empty bubble and a gap.
                if text(of: message).isEmpty {
                    absorbed.insert(message.id)
                } else {
                    reset()
                }
                continue
            }

            let own = Preparation(thinking: thinking(of: message),
                                  steps: steps(of: message, failedToolIDs: failedToolIDs))
            if text(of: message).isEmpty {
                pending.thinking = join(pending.thinking, own.thinking)
                pending.steps += own.steps
                pendingIDs.append(message.id)
            } else {
                var merged = pending
                merged.thinking = join(merged.thinking, own.thinking)
                merged.steps += own.steps
                if !merged.isEmpty { preparations[message.id] = merged }
                absorbed.formUnion(pendingIDs)
                reset()
            }
        }
        return (preparations, absorbed)
    }

    /// A message's own working, for one that was never absorbed into an answer.
    static func own(of message: Message, failedToolIDs: Set<String>) -> Preparation {
        Preparation(thinking: thinking(of: message),
                    steps: steps(of: message, failedToolIDs: failedToolIDs))
    }

    // MARK: Pieces

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + "\n\n" + b
    }

    private static func text(of message: Message) -> String {
        message.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func thinking(of message: Message) -> String {
        message.blocks.compactMap { if case .thinking(let t) = $0 { return t } else { return nil } }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func steps(of message: Message, failedToolIDs: Set<String>) -> [ToolStep] {
        message.blocks.compactMap { block in
            guard case .toolUse(let id, let name, let input) = block else { return nil }
            return ToolStep(id: id, name: name,
                            detail: ToolStep.detail(for: name, input: input),
                            finished: true, ok: !failedToolIDs.contains(id))
        }
    }
}

/// What the transcript needs to know about a whole message list.
struct TurnPlan {
    var preparations: [UUID: Preparation] = [:]
    var absorbed: Set<UUID> = []
    /// Tool calls whose result came back an error. Gathered here because the result
    /// blocks live one message on from the calls.
    var failedToolIDs: Set<String> = []
}

/// Works the plan out once per change instead of once per redraw.
///
/// The transcript view rebuilds on every streamed token, and folding walks every
/// message and joins every reasoning block. Recomputing that sixty times a second is
/// the same mistake that used to pin the CPU in the Markdown renderer.
@MainActor
final class FoldingCache {
    static let shared = FoldingCache()

    private var key: (Int, UUID?)?
    private var cached = TurnPlan()

    func plan(for messages: [Message]) -> TurnPlan {
        // Messages are appended, replaced wholesale on an edit, or swapped on a
        // regenerate — all of which change either the count or the last id.
        let next = (messages.count, messages.last?.id)
        if let key, key == next { return cached }

        var failed: Set<String> = []
        for message in messages {
            for block in message.blocks {
                if case .toolResult(let id, _, let isError) = block, isError { failed.insert(id) }
            }
        }
        let folded = TurnFolding.plan(for: messages, failedToolIDs: failed)
        cached = TurnPlan(preparations: folded.preparations,
                          absorbed: folded.absorbed,
                          failedToolIDs: failed)
        key = next
        return cached
    }
}
