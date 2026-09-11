import SwiftUI
import UIKit

struct MessageView: View {
    let message: Message
    var showThinking: Bool
    /// True for the newest assistant message — only that one can be regenerated.
    var isLastAssistant: Bool = false
    /// Tool calls whose result came back an error. Handed down because the result
    /// blocks live in the next message, not this one.
    var failedToolIDs: Set<String> = []
    /// The pages this answer stands on.
    var sources: [AnswerSource] = []
    /// The whole turn's working, when this message is the one that answered it.
    var preparation: Preparation? = nil
    var onFollowUp: (String) -> Void = { _ in }
    var onEdit: (Message) -> Void = { _ in }
    var onQuote: ((String) -> Void)? = nil

    /// One element per message rather than a scattering of fragments: swiping
    /// through a conversation should move message by message, and each stop should
    /// say who is speaking before it reads the text.
    private var spokenLabel: String {
        let who = message.role == .user ? "Du" : "Assistent"
        var parts = [who]
        let images = message.blocks.filter { if case .image = $0 { return true }; return false }.count
        if images > 0 { parts.append(images == 1 ? "ein Bild" : "\(images) Bilder") }
        let tools = message.blocks.compactMap { block -> String? in
            if case .toolUse(_, let name, _) = block {
                switch name {
                case "web_search": return "hat gesucht"
                case "fetch_page": return "hat eine Seite gelesen"
                case "remember":   return "hat sich etwas gemerkt"
                case "memory":     return "hat im Gedächtnis nachgesehen"
                default:           return nil
                }
            }
            return nil
        }
        parts.append(contentsOf: Set(tools).sorted())
        let text = message.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined(separator: " ")
        if !text.isEmpty { parts.append(text) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(spokenLabel)
    }

    @ViewBuilder
    private var content: some View {
        if message.isCompactionSummary {
            CompactionMarker(message: message)
        } else if message.role == .user {
            QuestionHeading(message: message, onEdit: { onEdit(message) })
        } else {
            AssistantTurn(message: message, showThinking: showThinking,
                          isLast: isLastAssistant, failedToolIDs: failedToolIDs,
                          sources: sources, preparation: preparation,
                          onFollowUp: onFollowUp, onQuote: onQuote)
        }
    }
}

/// Die Frage, gesetzt als Überschrift ihres Zuges.
///
/// Vorher eine rechtsbündige Karte mit Rahmen. Zwei Dinge sprachen dagegen: die
/// Frage stand in derselben Größe wie ihre eigene Antwort, und die Antwort — der
/// Grund für die App — hatte als Einzige keinen Behälter, sah also aus wie das,
/// was übrig blieb. Größe und Gewicht ordnen das ohne Rahmen, und der Zug liest
/// sich als Dokument: Überschrift, dann Text.
private struct QuestionHeading: View {
    let message: Message
    var onEdit: () -> Void = {}

    /// Wie viel von einer Frage oben steht, bevor sie aufgeklappt werden muss.
    ///
    /// Eine Frage ist die Überschrift ihres Zuges — und eine Überschrift, die den
    /// halben Bildschirm füllt, ist keine mehr. Wer etwas Langes einwirft, einen
    /// Textauszug oder eine Liste, bekommt sonst zwanzig Punkt Halbfett über die
    /// ganze Seite und findet die Antwort nicht mehr, die darunter anfängt.
    private static let collapsedLines = 3

    @State private var expanded = false
    @State private var truncated = false

    private var images: [(data: String, mediaType: String)] {
        message.blocks.compactMap {
            if case .image(let d, let m) = $0 { return (d, m) }
            return nil
        }
    }
    private var text: String {
        message.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined(separator: "\n")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                if !images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                            if let data = Data(base64Encoded: img.data),
                               let ui = UIImage(data: data) {
                                Image(uiImage: ui)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 92, height: 92)
                                    .clipShape(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                            .stroke(EH.hair, lineWidth: EH.hairWidth))
                            }
                        }
                    }
                }
                if !text.isEmpty {
                    // Über den Zwischenspeicher, nicht frisch geparst: das Transkript
                    // baut sich bei jedem gestreamten Token neu auf, und Markdown in
                    // `body` zu zerlegen war schon einmal die Stelle, an der die CPU
                    // beim Scrollen festhing.
                    Text(MarkdownCache.shared.inline(text))
                        .font(EH.question)
                        .foregroundStyle(EH.navy)
                        .textSelection(.enabled)
                        .lineLimit(expanded ? nil : Self.collapsedLines)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(measureOverflow)
                        .contentShape(Rectangle())
                        // Editing a misunderstood question beats asking again further
                        // down, where the misunderstanding keeps steering the thread.
                        .contextMenu {
                            Button { onEdit() } label: {
                                Label("Bearbeiten und neu senden", systemImage: "pencil")
                            }
                            Button {
                                UIPasteboard.general.string = text
                            } label: {
                                Label("Kopieren", systemImage: "doc.on.doc")
                            }
                        }

                    if truncated { unfoldButton }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Ob der Text in die drei Zeilen passt — gemessen, nicht geschätzt.
    ///
    /// `ViewThatFits` bekommt hier den Platz angeboten, den die gekürzte Fassung
    /// belegt, und nimmt den vollen Text nur, wenn er hineinpasst. Tut er es nicht,
    /// greift die Ausweichfassung — und genau das ist die Antwort auf die Frage.
    /// Über Zeichenzahl zu raten ginge daneben, sobald jemand die Textgröße ändert
    /// oder das Gerät dreht.
    private var measureOverflow: some View {
        ViewThatFits(in: .vertical) {
            Text(MarkdownCache.shared.inline(text))
                .font(EH.question)
                .hidden()
            Color.clear.onAppear { truncated = true }
        }
        .allowsHitTesting(false)
    }

    private var unfoldButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.eh(8, .caption2, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                Text(expanded ? "Weniger" : "Ganze Nachricht")
                    .font(.eh(11, .caption, weight: .medium))
                    .tracking(0.4)
            }
            .foregroundStyle(EH.muted)
            .padding(.vertical, 6)
            .padding(.trailing, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(EHTap())
        .accessibilityLabel(expanded ? "Nachricht einklappen" : "Ganze Nachricht zeigen")
    }
}

/// The assistant writes onto the page itself — no bubble, which keeps the long
/// answers readable and matches the site's open, quiet layout.
private struct AssistantTurn: View {
    let message: Message
    var showThinking: Bool
    var isLast: Bool = false
    var failedToolIDs: Set<String> = []
    var sources: [AnswerSource] = []
    var preparation: Preparation? = nil
    var onFollowUp: (String) -> Void = { _ in }
    var onQuote: ((String) -> Void)? = nil

    private var thinking: String {
        message.blocks.compactMap { if case .thinking(let t) = $0 { return t } else { return nil } }
            .joined()
    }
    private var text: String {
        message.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined()
    }
    /// The steps behind this answer, each paired with whether it actually worked.
    ///
    /// Results arrive in the *following* message — the wire format puts them there —
    /// so without the ids handed down from the transcript every call in the history
    /// rendered as a success, and a search that had failed read afterwards as a
    /// search that had found nothing.
    private var toolSteps: [ToolStep] {
        message.blocks.compactMap { block in
            guard case .toolUse(let id, let name, let input) = block else { return nil }
            return ToolStep(id: id, name: name,
                            detail: ToolStep.detail(for: name, input: input),
                            finished: true, ok: !failedToolIDs.contains(id))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The turn's working, if this message is the one that answered — otherwise
            // just this message's own, for a turn that never got that far.
            let work = preparation ?? TurnFolding.own(of: message, failedToolIDs: failedToolIDs)
            ToolTrace(steps: work.steps, thinking: work.thinking, showThinking: showThinking)
            if !text.isEmpty {
                MarkdownText(raw: text, onQuote: onQuote)
                    .font(EH.answer)
                    // Die Palette weist Navy den Überschriften und Slate dem
                    // Fließtext zu — die Antwort stand trotzdem in Navy, also in der
                    // Überschriftenfarbe. Slate misst 5,88:1 auf dem Grund, trägt AA
                    // mit Abstand und lässt der Frage die dunklere Stufe.
                    .foregroundStyle(EH.slate)
                    .lineSpacing(EH.prose)
                    .textSelection(.enabled)

                SourcesRow(sources: sources)
                MessageActions(message: message, isLast: isLast, onFollowUp: onFollowUp)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

struct ThinkingDisclosure: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.eh(8, .caption2, weight: .semibold))
                    EH.label("Gedankengang")
                }
                .foregroundStyle(EH.muted)
            }
            .buttonStyle(EHTap())

            if expanded {
                Text(text)
                    .font(EH.bodySmall)
                    .foregroundStyle(EH.slate)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(EH.hair).frame(width: EH.hairWidth)
                    }
            }
        }
    }
}

struct ToolChip: View {
    let name: String
    let detail: String
    var finished: Bool
    var ok: Bool

    private var icon: String {
        switch name {
        case "web_search": return "magnifyingglass"
        case "fetch_page": return "doc.text"
        case "remember":   return "bookmark"
        case "memory":     return "brain"
        default:           return "wrench.adjustable"
        }
    }
    private var label: String {
        switch name {
        case "web_search": return "Gesucht"
        case "fetch_page": return "Gelesen"
        case "remember":   return "Notiert"
        case "memory":     return "Gedächtnis"
        default:           return name
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            if finished {
                Image(systemName: ok ? icon : "exclamationmark.triangle")
                    .font(.eh(10, .caption2))
                    .foregroundStyle(ok ? EH.muted : EH.bad)
            } else {
                ProgressView().controlSize(.mini).tint(EH.muted)
            }
            Text(label)
                .font(.eh(11, .caption, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(EH.muted)
            if !detail.isEmpty {
                Text(detail)
                    .font(.eh(11, .caption))
                    .foregroundStyle(EH.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(EH.surfaceSunk))
        .overlay(
            Capsule().stroke(EH.hair, lineWidth: EH.hairWidth))
        // One stop per step for VoiceOver rather than three fragments, and a handle
        // the UI tests can count.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toolStep")
    }
}

/// Marks the point where earlier turns were folded into a summary.
struct CompactionMarker: View {
    let message: Message
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Rectangle().fill(EH.hair).frame(height: EH.hairWidth)
                    EH.label("\(message.replacedMessageCount) Nachrichten verdichtet")
                        .fixedSize()
                    Rectangle().fill(EH.hair).frame(height: EH.hairWidth)
                }
            }
            .buttonStyle(EHTap())

            if expanded {
                HairlineCard(padding: 14, fill: EH.surfaceSunk) {
                    MarkdownText(raw: message.text)
                        .font(EH.bodySmall)
                        .foregroundStyle(EH.slate)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
