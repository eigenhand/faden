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

    /// Wonach der Verlauf gegliedert ist.
    ///
    /// „10.09.2026" in jeder Zeile ist ein Datum, aber niemand liest es als „vorige
    /// Woche". Abschnitte tun das — und sie sind die zweite Stelle, an der das weit
    /// gesperrte Kleinversal der Vorlage Struktur tragen kann statt nur Formulare
    /// zu beschriften.
    private enum Bucket: Int, CaseIterable {
        case today, yesterday, week, month, older

        var title: String {
            switch self {
            case .today:     return "Heute"
            case .yesterday: return "Gestern"
            case .week:      return "Letzte 7 Tage"
            case .month:     return "Letzte 30 Tage"
            case .older:     return "Älter"
            }
        }

        /// Ob in der Zeile die Uhrzeit oder das Datum mehr sagt.
        var showsTime: Bool { self == .today || self == .yesterday }

        static func of(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bucket {
            if calendar.isDateInToday(date) { return .today }
            if calendar.isDateInYesterday(date) { return .yesterday }
            let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
            if days < 7 { return .week }
            if days < 30 { return .month }
            return .older
        }
    }

    private var grouped: [(Bucket, [Conversation])] {
        let by = Dictionary(grouping: shown) { Bucket.of($0.updatedAt) }
        return Bucket.allCases.compactMap { bucket in
            guard let list = by[bucket], !list.isEmpty else { return nil }
            return (bucket, list)
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
                      ForEach(Array(grouped.enumerated()), id: \.element.0) { index, pair in
                        let (bucket, list) = pair
                        EH.label(bucket.title)
                            .padding(.top, index == 0 ? 0 : 18)
                            .padding(.bottom, 2)

                        ForEach(list) { conversation in
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
                                            Text(conversation.updatedAt,
                                                 style: bucket.showsTime ? .time : .date)
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
