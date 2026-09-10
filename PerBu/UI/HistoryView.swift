import SwiftUI

struct HistoryView: View {
    /// Filters the list.
    ///
    /// Every AI chat app that shipped a conversation list had to add this afterwards:
    /// a long history is unusable by scrolling, and the answer worth coming back for
    /// is the one you cannot find. Titles and the opening question are both searched,
    /// because people remember what they asked more reliably than what the app named
    /// the conversation.
    @State private var search = ""

    private var shown: [Conversation] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.conversations }
        return model.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.preview.localizedCaseInsensitiveContains(q)
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                EH.scene
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(shown) { conversation in
                            Button {
                                model.switchTo(conversation.id)
                                dismiss()
                            } label: {
                                HairlineCard(padding: 14,
                                             fill: conversation.id == model.currentID ? EH.surfaceSunk : EH.surface) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(conversation.title)
                                            .font(EH.body).foregroundStyle(EH.navy).lineLimit(1)
                                        HStack(spacing: 8) {
                                            Text(conversation.updatedAt, style: .date)
                                            Text("·")
                                            Text("\(conversation.messages.count) Nachrichten")
                                            if conversation.compactionCount > 0 {
                                                Text("·")
                                                Text("\(conversation.compactionCount)× verdichtet")
                                            }
                                        }
                                        .font(.eh(11, .caption))
                                        .foregroundStyle(EH.muted)
                                    }
                                }
                            }
                            .buttonStyle(EHTap())
                            .contextMenu {
                                // A conversation travels as a file: AirDrop, Messages,
                                // Files — whatever the share sheet offers. Nothing
                                // passes through a server on the way.
                                ShareLink(item: conversation,
                                          preview: SharePreview(conversation.title)) {
                                    Label("Weitergeben", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) { model.delete(conversation) } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(EH.gutter)
                }
            }
            .searchable(text: $search, prompt: "Titel oder Frage")
            .navigationTitle("Verlauf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.foregroundStyle(EH.navy)
                }
            }
        }
    }
}
