import Foundation

/// Everything that belongs to one conversation while it is being worked on.
///
/// This used to live on `AppModel` as a single set of fields, which meant every
/// conversation shared it: switching chats mid-answer showed the other chat's
/// streaming text, carried its attachments along, and — worst — let the finishing
/// turn write its message list into whichever conversation happened to be open,
/// overwriting the one you had just switched to.
@MainActor
@Observable
final class TurnState {
    var isStreaming = false
    var liveText = ""
    var liveThinking = ""
    var liveTools: [ToolActivity] = []
    var errorMessage: String?
    /// Images staged for the next message in *this* conversation.
    var attachments: [ImageAttachment] = []
    /// Context usage of this conversation, so the bar does not show another's.
    var usage = ContextUsage()
    /// How many memories were recalled for the turn in flight.
    var recalledCount = 0

    /// The running turn, held here so switching away can leave it running and
    /// switching back can still stop it.
    var task: Task<Void, Never>?

    /// Message count at which compaction last failed *in this conversation*. Held
    /// per conversation because a failure in one says nothing about another.
    var lastFailedCompactionAt: Int?

    func clearLive() {
        liveText = ""
        liveThinking = ""
        liveTools = []
    }
}
