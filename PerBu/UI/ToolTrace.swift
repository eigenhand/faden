import SwiftUI

/// One step the model took to answer.
struct ToolStep: Identifiable, Equatable {
    let id: String
    var name: String
    var detail: String
    var finished: Bool = true
    var ok: Bool = true

    /// What to show beside a step's name — the query, the address, the note.
    static func detail(for name: String, input: JSONValue) -> String {
        switch name {
        case "web_search": return input["query"]?.stringValue ?? ""
        case "fetch_page": return input["url"]?.stringValue ?? ""
        case "remember":   return input["note"]?.stringValue ?? ""
        case "memory":     return input["query"]?.stringValue
                               ?? input["fact"]?.stringValue
                               ?? input["id"]?.stringValue
                               ?? input["action"]?.stringValue ?? ""
        default:           return input.compactDescription
        }
    }
}

/// What the model did, in two layers.
///
/// The app used to render one chip per tool call and keep them all, so a turn with
/// three searches and two page fetches left five lines stacked above the answer for
/// the life of the conversation. The research is fairly consistent that this is the
/// wrong trade:
///
/// * Transparency helps, but through its *kind* rather than its volume. Chen et al.'s
///   SAT model separates what an agent is doing, why, and what it expects; operator
///   performance and trust calibration were best with all three. Adding a further
///   layer of numeric uncertainty on top produced no further benefit.
/// * Vered et al. compared stepping people through an agent's reasoning in a fixed
///   order against letting them ask for the parts they wanted. Being able to ask was
///   faster, with no loss of performance — availability matters, forced reading does
///   not.
/// * Nielsen's guidance for agentic interfaces is the same shape: the outcome and
///   anything awaiting a decision belong on the bench; the full step-by-step trace
///   belongs in a drawer, one click away. Sixty visible tool calls are as useless as
///   sixty visible toggles.
///
/// What stays visible regardless is *that* work happened, because hiding it entirely
/// costs something real: Buell and Norton's labor illusion found people can value a
/// slower service that shows its work over an instant one returning the same result,
/// and a run with nothing on screen past a few seconds reads as a hang.
///
/// So: one line while it works, one quiet summary afterwards, the whole trace on tap
/// — and a failure promoted to the surface, because that one *is* decision-relevant.
struct ToolTrace: View {
    let steps: [ToolStep]
    /// The turn's reasoning, folded in behind the same control. Separating the two
    /// meant one question rendered as four stacked blocks — think, call, think,
    /// answer — when the reader only ever wanted the question, the work, the answer.
    var thinking: String = ""
    var showThinking: Bool = true
    /// True while the turn is still running.
    var running: Bool = false

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var failures: [ToolStep] { steps.filter { $0.finished && !$0.ok } }
    private var active: ToolStep? { steps.first(where: { !$0.finished }) }
    private var showsThinking: Bool { showThinking && !thinking.isEmpty }

    var body: some View {
        if !steps.isEmpty || showsThinking {
            VStack(alignment: .leading, spacing: 6) {
                summaryButton

                // A failed step is never folded away: it is the one piece of the
                // trace that changes how the answer above it should be read.
                if !expanded {
                    ForEach(failures) { step in
                        ToolChip(name: step.name, detail: step.detail,
                                 finished: true, ok: false)
                    }
                }

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if showsThinking {
                            Text(thinking)
                                .font(EH.bodySmall)
                                .foregroundStyle(EH.slate)
                                .textSelection(.enabled)
                                .padding(.leading, 12)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(EH.hair).frame(width: EH.hairWidth)
                                }
                        }
                        ForEach(steps) { step in
                            ToolChip(name: step.name, detail: step.detail,
                                     finished: step.finished, ok: step.ok)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private var summaryButton: some View {
        Button {
            if reduceMotion { expanded.toggle() }
            else { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } }
        } label: {
            HStack(spacing: 7) {
                if running, active != nil {
                    ProgressView().controlSize(.mini).tint(EH.muted)
                } else {
                    Image(systemName: failures.isEmpty ? "checkmark" : "exclamationmark.triangle")
                        .font(.eh(10, .caption2))
                        .foregroundStyle(failures.isEmpty ? EH.muted : EH.bad)
                }

                // Only the failure is coloured. Painting the whole line red makes
                // three successful searches look like part of the problem.
                (Text(summary.done).foregroundStyle(EH.muted)
                 + Text(summary.failed).foregroundStyle(EH.bad))
                    .font(.eh(11, .caption, weight: .medium))
                    .tracking(0.6)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Image(systemName: "chevron.right")
                    .font(.eh(8, .caption2, weight: .semibold))
                    .foregroundStyle(EH.muted)
                    .rotationEffect(.degrees(expanded ? 90 : 0))

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenSummary)
        .accessibilityHint(expanded ? "Schritte ausblenden" : "Einzelne Schritte anzeigen")
    }

    /// The one line that stands for the whole trace, split so the failure — and
    /// only the failure — can carry the warning colour.
    private var summary: (done: String, failed: String) {
        if running, let active {
            let others = steps.filter { !$0.finished }.count - 1
            let verb = Self.runningVerb(active.name)
            return (others > 0 ? "\(verb) · \(others + 1) gleichzeitig" : verb, "")
        }
        var parts = Self.counts(of: steps)
        // "Nachgedacht" earns its place only when it is all that happened. Beside a
        // list of tool calls it is the least informative part of the line, and on a
        // phone it pushed the one part that matters — a failure — off the end.
        if showsThinking, parts.isEmpty { parts.append("Nachgedacht") }
        let done = parts.isEmpty ? "Ein Schritt" : parts.joined(separator: " · ")
        guard !failures.isEmpty else { return (done, "") }
        return (parts.isEmpty ? "" : done + " · ", "\(failures.count) fehlgeschlagen")
    }

    /// What a screen reader hears, and what the button is called.
    private var spokenSummary: String { summary.done + summary.failed }

    private static func runningVerb(_ name: String) -> String {
        switch name {
        case "web_search": return "Sucht im Web"
        case "fetch_page": return "Liest eine Seite"
        case "remember":   return "Merkt sich etwas"
        case "memory":     return "Sieht im Gedächtnis nach"
        default:           return "Arbeitet"
        }
    }

    /// "3 Suchen · 1 Seite gelesen" — the shape of the work, not a log of it.
    private static func counts(of steps: [ToolStep]) -> [String] {
        var order: [String] = []
        var tally: [String: Int] = [:]
        for step in steps where step.ok {
            if tally[step.name] == nil { order.append(step.name) }
            tally[step.name, default: 0] += 1
        }
        return order.compactMap { name in
            guard let n = tally[name] else { return nil }
            switch name {
            case "web_search": return n == 1 ? "1 Suche" : "\(n) Suchen"
            case "fetch_page": return n == 1 ? "1 Seite gelesen" : "\(n) Seiten gelesen"
            case "remember":   return n == 1 ? "1 Notiz" : "\(n) Notizen"
            case "memory":     return n == 1 ? "Im Gedächtnis nachgesehen"
                                             : "\(n)× im Gedächtnis nachgesehen"
            default:           return n == 1 ? name : "\(n)× \(name)"
            }
        }
    }
}
