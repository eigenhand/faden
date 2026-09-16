import SwiftUI

/// The waiting state, with a reason once waiting becomes noticeable.
///
/// A bare spinner tells the reader nothing about whether anything is happening, and
/// studies on chatbot response delays find that explaining the wait raises both trust
/// and perceived transparency — more than shaving the wait itself would. So the dot
/// stays silent while a normal answer is forming, and starts explaining only once the
/// delay is long enough that someone would begin to doubt.
struct WaitingIndicator: View {
    /// What the assistant is doing, if it is already known.
    var activity: String?

    @State private var elapsed: TimeInterval = 0
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var caption: String? {
        if let activity { return activity }
        switch elapsed {
        case ..<2.5:  return nil                        // normal, no need to say anything
        case ..<10:   return "wartet auf das Modell"
        case ..<25:   return "das Modell denkt noch"
        default:      return "das dauert länger als sonst — Stopp bricht ab"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            PulsingDot()
            if let caption {
                Text(caption)
                    .font(.eh(11, .caption, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(EH.muted)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: caption)
        .onReceive(clock) { _ in elapsed += 1 }
        .accessibilityLabel(caption ?? "Antwort wird erstellt")
    }
}

/// Openers for an empty conversation.
///
/// A blank field is the hardest place to start, and the research on prompt
/// suggestions is specific about what helps. NN/g's finding: a suggestion should be
/// the question itself, concrete enough to judge at a glance — Instacart's "easy
/// family dinners" beat category labels, and vague or broad suggestions are "rarely
/// effective". These used to show an umbrella term with the actual prompt hidden
/// behind it: you tapped "Etwas erklären" and got a sentence you had never seen.
///
/// The one that cannot be a sendable sentence is the image, because it needs a
/// picture first. That one opens the picker instead of pretending to be a prompt —
/// the old version inserted "Ich hänge gleich ein Bild an …" and then left the
/// person to remember the attachment themselves.
struct PromptSuggestions: View {
    let searchAvailable: Bool
    let visionAvailable: Bool
    let memoryEnabled: Bool
    /// True where a camera exists, which changes what the image opener promises.
    let cameraAvailable: Bool
    let voiceAvailable: Bool
    var onPick: (String) -> Void
    var onAddImage: () -> Void
    var onStartVoice: () -> Void

    private enum Opener {
        case ask(icon: String, question: String)
        case image(icon: String, label: String)
        case voice(icon: String, label: String)

        var icon: String {
            switch self {
            case .ask(let i, _), .image(let i, _), .voice(let i, _): return i
            }
        }
        var text: String {
            switch self {
            case .ask(_, let q): return q
            case .image(_, let l), .voice(_, let l): return l
            }
        }
    }

    private var openers: [Opener] {
        var out: [Opener] = []
        if searchAvailable {
            out.append(.ask(icon: "magnifyingglass",
                            question: "Was ist heute in den Nachrichten wichtig?"))
        }
        if visionAvailable {
            out.append(.image(icon: cameraAvailable ? "camera" : "photo",
                              label: cameraAvailable
                                  ? "Ein Foto aufnehmen und erklären lassen"
                                  : "Ein Bild aus der Mediathek erklären lassen"))
        }
        if memoryEnabled {
            out.append(.ask(icon: "brain", question: "Was weißt du bislang über mich?"))
        }
        // Der eine beschriftete Weg zum Sprachmodus. In der Eingabezeile steht dafür
        // ein nacktes `waveform` direkt neben einem `mic` — zwei Audio-Symbole
        // nebeneinander, eines für „halten und diktieren“, eines für „freihändig
        // reden“. Hier ist Platz für die Worte, und hier wird das Symbol gelernt.
        if voiceAvailable {
            out.append(.voice(icon: "waveform", label: "Freihändig sprechen"))
        }
        out.append(.ask(icon: "text.alignleft",
                        question: "Formulier mir eine kurze, freundliche Absage."))
        return Array(out.prefix(4))
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(openers, id: \.text) { opener in
                Button {
                    switch opener {
                    case .ask(_, let question): onPick(question)
                    case .image:                onAddImage()
                    case .voice:                onStartVoice()
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: opener.icon)
                            .font(.eh(11, .caption))
                            .foregroundStyle(EH.muted)
                            .frame(width: 14)
                        Text(opener.text)
                            .font(EH.bodySmall)
                            .foregroundStyle(EH.slate)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                        .fill(EH.surface))
                    .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                        .stroke(EH.hair, lineWidth: EH.hairWidth))
                }
                .buttonStyle(EHTap())
            }
        }
        .padding(.horizontal, 28)
    }
}
