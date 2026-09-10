import SwiftUI

/// The small row of actions under a message.
///
/// Research on how people actually use generative AI (NN/g's "accordion editing" and
/// "apple picking") finds that a first answer is rarely the final one: people shorten
/// it, lengthen it, or pick a piece out and build on it. Without affordances for that,
/// the only route is retyping the question, so the transcript fills with near-duplicate
/// prompts and the thread becomes hard to follow.
///
/// Kept deliberately quiet — hairline icons that step back until wanted, in keeping
/// with the rest of the app.
struct MessageActions: View {
    @Environment(AppModel.self) private var model
    let message: Message
    /// True for the newest assistant message, which alone can be regenerated.
    let isLast: Bool
    var onFollowUp: (String) -> Void

    @State private var copied = false

    /// Only worth naming when more than one model is set up — otherwise it is noise
    /// on every single answer.
    private var attribution: String? {
        guard model.settings.llms.count > 1, let name = message.producedBy else { return nil }
        return name.split(separator: "/").last.map(String.init) ?? name
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Beyond the accessibility sizes four labelled actions cannot share a line:
        // they wrap into each other and become unreadable. There the labels go and
        // the icons stand alone, which stays usable at any size.
        Group {
            if typeSize >= .accessibility2 {
                iconsOnly
            } else {
                labelled
            }
        }
        .padding(.top, 2)
    }

    private var iconsOnly: some View {
        HStack(spacing: 20) {
            iconAction(copied ? "checkmark" : "doc.on.doc", label: "Kopieren") { copy() }
            if isLast, !model.isStreaming {
                iconAction("arrow.clockwise", label: "Neu holen") { model.regenerateLastAnswer() }
                iconAction("arrow.down.right.and.arrow.up.left", label: "Kürzer") {
                    onFollowUp("Fasse das kürzer — die Hälfte, gleiche Substanz.")
                }
                iconAction("arrow.up.left.and.arrow.down.right", label: "Ausführlicher") {
                    onFollowUp("Geh darauf genauer ein.")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func iconAction(_ icon: String, label: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon)
                .font(.eh(15, .callout))
                .foregroundStyle(EH.muted)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func copy() {
        UIPasteboard.general.string = message.text
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
    }

    private var labelled: some View {
        HStack(spacing: 14) {
            action(copied ? "checkmark" : "doc.on.doc", label: copied ? "kopiert" : "Kopieren") {
                copy()
            }

            if isLast, !model.isStreaming {
                action("arrow.clockwise", label: "Neu") {
                    model.regenerateLastAnswer()
                }
                // Accordion editing, made one tap instead of a retyped prompt.
                action("arrow.down.right.and.arrow.up.left", label: "Kürzer") {
                    onFollowUp("Fasse das kürzer — die Hälfte, gleiche Substanz.")
                }
                action("arrow.up.left.and.arrow.down.right", label: "Mehr") {
                    onFollowUp("Geh darauf genauer ein.")
                }
            }
            Spacer(minLength: 0)

            if let attribution {
                Text(attribution)
                    .font(.eh(10, .caption2))
                    .foregroundStyle(EH.muted)
                    .lineLimit(1)
                    .accessibilityLabel("beantwortet von \(attribution)")
            }
        }
    }

    private func action(_ icon: String, label: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.eh(10, .caption2, weight: .medium))
                Text(label).font(.eh(10, .caption2, weight: .medium)).tracking(0.4)
            }
            .foregroundStyle(EH.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Lets a reader take a passage from an answer into the next question.
///
/// This is NN/g's "apple picking": people refer back to a specific part of what the
/// assistant wrote, and today that means scrolling up, selecting, copying and pasting.
/// Quoting it directly keeps the reference exact — and visible to the model, which
/// otherwise has to guess which part was meant.
struct QuoteButton: View {
    let text: String
    var onQuote: (String) -> Void

    var body: some View {
        Button {
            let condensed = text.count > 220 ? String(text.prefix(220)) + " …" : text
            onQuote("> " + condensed.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "text.quote").font(.eh(10, .caption2, weight: .medium))
                Text("Darauf beziehen").font(.eh(10, .caption2, weight: .medium)).tracking(0.4)
            }
            .foregroundStyle(EH.muted)
        }
        .buttonStyle(.plain)
    }
}
