import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                EH.scene
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.conversations) { conversation in
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
                            .buttonStyle(.plain)
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
