import SwiftUI

/// The thin strip along the bottom edge: how much of the window is in use, and what
/// the app is doing about it. Deliberately quiet — a hairline, a number, nothing else
/// until something needs attention.
///
/// **Currently unused.** It was removed from the chat once the bundled model moved to
/// a window of a million tokens: at that size it read "0 %" permanently, so it was a
/// strip that never said anything. Its two working parts — the figure and compacting
/// by hand — now live in Settings › Kontext.
///
/// Kept rather than deleted because this project has no version control, so a
/// deletion here is final, and because bringing it back only above the compaction
/// threshold would be a one-line change.
struct ContextBar: View {
    let usage: ContextUsage
    var compactAction: () -> Void

    private var tint: Color {
        if usage.compacting { return EH.slate }
        switch usage.fraction {
        case ..<0.6:  return EH.slate
        case ..<0.75: return EH.warn
        default:      return EH.bad
        }
    }

    private var caption: String {
        if usage.compacting { return "verdichte" }
        if usage.fraction >= 0.75 { return "\(usage.percent) % · verdichtet gleich" }
        return "\(usage.percent) %"
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(EH.hair).frame(height: EH.hairWidth)

            HStack(spacing: 10) {
                // The gauge
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(EH.hair.opacity(0.55))
                        Capsule()
                            .fill(tint)
                            .frame(width: max(2, geo.size.width * usage.fraction))
                            .animation(.easeOut(duration: 0.45), value: usage.fraction)
                    }
                }
                .frame(height: 2.5)

                Text(caption)
                    .font(.eh(10, .caption2, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                if usage.compacting {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(EH.muted)
                } else {
                    Button(action: compactAction) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.eh(10, .caption2, weight: .medium))
                            .foregroundStyle(EH.muted)
                    }
                    .buttonStyle(EHTap())
                    .accessibilityLabel(Text("Kontext jetzt verdichten"))
                }
            }
            .padding(.horizontal, EH.gutter)
            .padding(.top, 7)
            .padding(.bottom, 3)
        }
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Kontext zu \(usage.percent) Prozent genutzt, \(usage.remaining) Token frei"))
    }
}
