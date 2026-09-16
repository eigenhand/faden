import SwiftUI

/// Reworks a question and asks it again.
///
/// Everything after the edited message is dropped, which is the point: a
/// misunderstanding left in the transcript keeps influencing later answers, so
/// correcting it in place is more effective than asking again below.
struct EditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let message: Message
    var onSubmit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                EH.scene
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Frage", text: $text, axis: .vertical)
                        .font(EH.body)
                        .foregroundStyle(EH.navy)
                        .lineLimit(3...12)
                        .focused($focused)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: EH.radius, style: .continuous)
                            .fill(EH.surface))
                        .overlay(RoundedRectangle(cornerRadius: EH.radius, style: .continuous)
                            .stroke(EH.hair, lineWidth: EH.hairWidth))

                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "info.circle")
                            .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        Text("Die Antwort darauf und alles danach wird verworfen und neu beantwortet.")
                            .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                    }
                    Spacer()
                }
                .padding(EH.gutter)
            }
            .navigationTitle("Frage bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .foregroundStyle(EH.slate)
                        .keyboardShortcut(.escape, modifiers: [])
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Neu senden") {
                        onSubmit(text)
                        dismiss()
                    }
                    .foregroundStyle(EH.navy)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .onAppear {
            text = message.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
                .joined(separator: "\n")
            focused = true
        }
    }
}
