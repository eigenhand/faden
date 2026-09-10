import SwiftUI

/// A page that fed into an answer.
struct AnswerSource: Identifiable, Equatable, Hashable {
    let title: String
    let url: String

    var id: String { url }

    /// What a reader actually recognises. A bare URL is what the citation research
    /// calls "low-scent": it rarely says what the source contains, so it gets
    /// skipped. The host is the part that carries the judgement.
    var host: String {
        guard let h = URL(string: url)?.host else { return url }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

extension AnswerSource {

    /// The sources behind the answer at `index`.
    ///
    /// Tool results land in the message *after* the calls, and an answer is usually
    /// several messages past the question that triggered the search, so this walks
    /// back over the tool round trips to the last thing the reader actually typed.
    static func forAnswer(at index: Int, in messages: [Message]) -> [AnswerSource] {
        guard messages.indices.contains(index) else { return [] }
        var found: [AnswerSource] = []
        var seen = Set<String>()
        var fetched: [String: String] = [:]        // tool-use id → requested URL

        // Find where this turn began, then read it forwards.
        //
        // Walking backwards and collecting in the same pass looked simpler and was
        // wrong: a tool result sits one message *after* the call it answers, so
        // going backwards meets the result first and the `fetch_page` url that
        // belongs to it is still unknown. Every page the model read was silently
        // dropped from the source list.
        var start = index
        while start > 0 {
            let previous = messages[start - 1]
            let isToolRound = previous.blocks.allSatisfy { block in
                if case .toolResult = block { return true }
                if case .toolUse = block { return true }
                if case .thinking = block { return true }
                if case .text(let t) = block { return previous.role == .assistant || t.isEmpty }
                return false
            }
            if previous.role == .user, !isToolRound { break }
            start -= 1
        }

        for message in messages[start..<index] {
            for block in message.blocks {
                switch block {
                case .toolUse(let id, let name, let input):
                    if name == "fetch_page", let url = input["url"]?.stringValue {
                        fetched[id] = url
                    }
                case .toolResult(let id, let content, let isError):
                    guard !isError else { continue }
                    if let url = fetched[id] {
                        add(AnswerSource(title: "", url: url), to: &found, seen: &seen)
                    }
                    for source in parse(content) { add(source, to: &found, seen: &seen) }
                default:
                    break
                }
            }
        }
        return found
    }

    private static func add(_ s: AnswerSource, to list: inout [AnswerSource],
                            seen: inout Set<String>) {
        guard !s.url.isEmpty, seen.insert(s.url).inserted else { return }
        list.append(s)
    }

    /// Reads back the shape `AgentRunner.render` writes: a numbered heading, then the
    /// URL on the line below it.
    private static func parse(_ text: String) -> [AnswerSource] {
        var out: [AnswerSource] = []
        let lines = text.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            guard let head = line.range(of: "^\\[\\d+\\] ", options: .regularExpression),
                  i + 1 < lines.count else { continue }
            let url = lines[i + 1].trimmingCharacters(in: .whitespaces)
            guard url.hasPrefix("http") else { continue }
            var title = String(line[head.upperBound...])
            if let dash = title.range(of: " — ", options: .backwards) {
                title = String(title[..<dash.lowerBound])
            }
            out.append(AnswerSource(title: title.trimmingCharacters(in: .whitespaces), url: url))
        }
        return out
    }
}

/// The pages an answer stands on.
///
/// The app showed none of these: search results went to the model and the URLs stayed
/// buried in the transcript, so an answer drawn from the web was indistinguishable
/// from one the model invented. That matters more than it sounds — audits of answer
/// engines keep finding sizeable shares of citations that do not support the claim
/// they hang on, which is only checkable if the reader can reach the source at all.
///
/// Folded by default and opened on request, following the same finding as the tool
/// trace: citations revealed step by step get examined more carefully than a block of
/// them dumped under the answer, where they are reliably skipped.
struct SourcesRow: View {
    let sources: [AnswerSource]

    /// Three states, not two.
    ///
    /// Untouched, a handful of sources stands under the answer: enough to see where
    /// it came from without reaching for anything, which is the whole point of
    /// showing them. Opening it shows the rest. Closing it after that means "not
    /// now" — so it closes completely, rather than springing back to the few it
    /// started with, which would read as the control having failed.
    private enum Reveal { case initial, all, none }

    /// How many stand there before anyone asks.
    private static let initialCount = 3

    @State private var reveal: Reveal = .initial
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: [AnswerSource] {
        switch reveal {
        case .initial: return Array(sources.prefix(Self.initialCount))
        case .all:     return sources
        case .none:    return []
        }
    }

    /// From the opening state a tap opens — unless everything is already on show,
    /// where the only honest next step is to close.
    private var nextReveal: Reveal {
        switch reveal {
        case .initial: return sources.count > Self.initialCount ? .all : .none
        case .all:     return .none
        case .none:    return .all
        }
    }

    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    let next = nextReveal
                    if reduceMotion { reveal = next }
                    else { withAnimation(.easeOut(duration: 0.18)) { reveal = next } }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "link")
                            .font(.eh(10, .caption2))
                        Text(sources.count == 1 ? "1 Quelle" : "\(sources.count) Quellen")
                            .font(.eh(11, .caption, weight: .medium))
                            .tracking(0.6)
                        Image(systemName: "chevron.right")
                            .font(.eh(8, .caption2, weight: .semibold))
                            .rotationEffect(.degrees(reveal == .all ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(EH.muted)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(EHTap())
                .accessibilityLabel(sources.count == 1 ? "Eine Quelle" : "\(sources.count) Quellen")
                .accessibilityHint(nextReveal == .all ? "Alle Quellen anzeigen"
                                                      : "Quellen ausblenden")

                if !shown.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(shown) { source in
                            Button {
                                if let url = URL(string: source.url) { openURL(url) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    if !source.title.isEmpty {
                                        Text(source.title)
                                            .font(.eh(13, .footnote))
                                            .foregroundStyle(EH.slate)
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(2)
                                    }
                                    Text(source.host)
                                        .font(.eh(11, .caption))
                                        .foregroundStyle(EH.muted)
                                }
                                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(EHTap())
                            .accessibilityLabel("\(source.title.isEmpty ? source.host : source.title), \(source.host)")
                            .accessibilityHint("Öffnet die Seite")
                            .accessibilityIdentifier("answerSource")
                        }
                    }
                    .padding(.leading, 2)
                    .transition(.opacity)
                }
            }
        }
    }
}

/// Remembers what an answer's sources were.
///
/// Working them out means walking back over the turn and running a regex across
/// every tool result, and tool results run to thousands of characters. Doing that
/// inside `body` would repeat it on every redraw — the same mistake the Markdown
/// renderer used to make, which pinned the CPU during scrolling. A message's sources
/// cannot change once it is written, so they are worked out once.
@MainActor
final class SourceCache {
    static let shared = SourceCache()

    private var byMessage: [UUID: [AnswerSource]] = [:]
    private var order: [UUID] = []
    private let limit = 500

    func sources(for id: UUID, at index: Int, in messages: [Message]) -> [AnswerSource] {
        if let hit = byMessage[id] { return hit }
        let made = AnswerSource.forAnswer(at: index, in: messages)
        byMessage[id] = made
        order.append(id)
        if order.count > limit {
            let drop = order.count - limit / 2
            for key in order.prefix(drop) { byMessage[key] = nil }
            order.removeFirst(drop)
        }
        return made
    }
}
