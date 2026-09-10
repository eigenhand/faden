import SwiftUI

/// The hands-free overlay: what the app is doing right now, and one way out.
///
/// Deliberately sparse. During a spoken conversation nobody reads the screen — the
/// display only has to answer "is it listening to me, or talking to me?" at a glance.
struct VoiceModeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var caption: String {
        switch model.voiceStage {
        case .off:          return ""
        case .listening:    return model.silence.heardSpeech ? "hört zu" : "sprich einfach"
        case .transcribing: return "verstehe"
        case .thinking:     return "denkt nach"
        case .speaking:     return "antwortet"
        }
    }

    var body: some View {
        ZStack {
            EH.scene
            BrandWatermark()

            VStack(spacing: 30) {
                Spacer()

                ZStack {
                    // The ring follows the voice while listening, and breathes calmly
                    // the rest of the time.
                    Circle()
                        .stroke(EH.hair, lineWidth: EH.hairWidth)
                        .frame(width: 168, height: 168)

                    Circle()
                        .stroke(EH.navy.opacity(0.16), lineWidth: 2)
                        .frame(width: 168, height: 168)
                        // The ring follows the voice by size, or — when movement is
                        // unwelcome — by weight. Either way it still answers "does it
                        // hear me?", and the caption underneath says it in words.
                        .scaleEffect(model.voiceStage == .listening && !reduceMotion
                                     ? 1 + CGFloat(model.silence.level) * 0.35 : 1)
                        .opacity(reduceMotion && model.voiceStage == .listening
                                 ? 0.35 + Double(model.silence.level) * 0.65 : 1)
                        .animation(.easeOut(duration: 0.1), value: model.silence.level)

                    // While the pause runs out, the ring closes — so the two seconds
                    // are visible instead of a surprise.
                    if model.voiceStage == .listening, model.silence.heardSpeech {
                        Circle()
                            .trim(from: 0, to: model.silence.progress)
                            .stroke(EH.navy, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 168, height: 168)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.12), value: model.silence.progress)
                    }

                    Image("BrandMark")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56)
                        .foregroundStyle(EH.navy.opacity(model.voiceStage == .speaking ? 0.9 : 0.7))
                        .scaleEffect(model.voiceStage == .speaking && !reduceMotion ? 1.06 : 1)
                        .animation(reduceMotion ? nil
                                   : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                                   value: model.voiceStage == .speaking)
                }

                VStack(spacing: 12) {
                    EH.label(caption)
                    BrandRule(width: 40)
                    if let text = lastSpokenLine {
                        Text(text)
                            .font(EH.bodySmall)
                            .foregroundStyle(EH.slate)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 32)
                            .transition(.opacity)
                    }
                }

                Spacer()

                Button {
                    model.stopVoiceConversation()
                } label: {
                    Text("Beenden")
                        .font(.eh(15, .callout, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 34)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(EH.navy))
                }
                .buttonStyle(EHTap())
                .padding(.bottom, 44)
            }
        }
    }

    /// A little context: what was understood, or what is being said.
    private var lastSpokenLine: String? {
        switch model.voiceStage {
        case .listening:
            let t = model.dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case .thinking, .speaking:
            guard let last = model.current?.messages.last(where: { $0.role == .assistant }) else { return nil }
            let text = last.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
                .joined(separator: " ")
            return text.isEmpty ? nil : String(text.prefix(160))
        default:
            return nil
        }
    }
}
