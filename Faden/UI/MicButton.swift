import SwiftUI

/// Push-to-talk: hold to speak, release to send the text into the composer.
///
/// Holding rather than toggling makes the end of the utterance unambiguous — no
/// stray recording left running because a second tap was missed.
struct MicButton: View {
    let capturing: Bool
    let transcribing: Bool
    /// Input level 0…1, drawn as a ring while a remote recording is running.
    let level: Float
    var onDown: () -> Void
    var onUp: () -> Void

    @State private var held = false

    var body: some View {
        ZStack {
            Circle()
                .fill(capturing ? EH.navy : EH.surface)
            Circle()
                .stroke(capturing ? .clear : EH.hairStrong, lineWidth: EH.hairWidth)

            if capturing {
                Circle()
                    .stroke(EH.navy.opacity(0.28), lineWidth: 3)
                    .scaleEffect(1 + CGFloat(level) * 0.5)
                    .animation(.easeOut(duration: 0.08), value: level)
            }

            if transcribing {
                ProgressView().controlSize(.mini).tint(EH.slate)
            } else {
                Image(systemName: capturing ? "waveform" : "mic")
                    .font(.eh(15, .callout, weight: .regular))
                    .foregroundStyle(capturing ? .white : EH.slate)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 38, height: 38)
        .padding(3)                 // 44 pt target, same 38 pt circle
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !held else { return }
                    held = true
                    onDown()
                }
                .onEnded { _ in
                    held = false
                    onUp()
                }
        )
        .disabled(transcribing)
        .accessibilityLabel("Zum Sprechen gedrückt halten")
    }
}
