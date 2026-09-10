import SwiftUI

/// The model's reasoning while it is still arriving.
///
/// It grows downwards inside a bounded, self-scrolling frame rather than replacing a
/// two-line snippet on every delta — the earlier version swapped `suffix(90)` in and
/// out, which read as flicker and lost everything that had come before. Once the
/// answer itself starts, this folds away on its own, and the reader can fold it back
/// open at any point; a manual choice then wins over the automatic one.
struct LiveThinkingView: View {
    let text: String
    /// True once visible answer text has begun to stream.
    let isAnswering: Bool

    /// nil means "follow the automatic behaviour"; a value means the reader decided.
    @State private var manual: Bool?

    private var isOpen: Bool { manual ?? !isAnswering }

    /// Rendering the entire reasoning on every delta gets expensive on long turns,
    /// and only the tail is ever on screen.
    private var visible: String {
        let cap = 4000
        guard text.count > cap else { return text }
        return "…" + text.suffix(cap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.22)) { manual = !isOpen }
            } label: {
                HStack(spacing: 7) {
                    if isAnswering {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.eh(8, .caption2, weight: .semibold))
                            .foregroundStyle(EH.muted)
                    } else {
                        PulsingDot()
                    }
                    EH.label(isAnswering ? "Gedankengang" : "Denkt nach")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(EHTap())

            if isOpen {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(visible)
                            .font(.eh(12.5, .caption))
                            .foregroundStyle(EH.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 2)
                            .id("thinkingBody")
                        Color.clear.frame(height: 1).id("thinkingEnd")
                    }
                    .frame(maxHeight: 132)
                    .onChange(of: text) { _, _ in
                        // Follow the writing without animating each delta, which
                        // would fight the incoming text.
                        proxy.scrollTo("thinkingEnd", anchor: .bottom)
                    }
                    .onAppear { proxy.scrollTo("thinkingEnd", anchor: .bottom) }
                }
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    Rectangle().fill(EH.hair).frame(width: EH.hairWidth)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: isAnswering)
    }
}
