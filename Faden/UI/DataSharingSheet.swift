import SwiftUI

/// Says where data is about to go and asks before it goes.
///
/// One component for every place that sends something off the device — the chat
/// provider, search, embeddings, speech — so the wording cannot drift between them.
/// "Agree" records the consent and continues; "Cancel" leaves everything as it was and
/// sends nothing.
struct DataSharingSheet: View {
    let request: DataSharingRequest
    var onAgree: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                EH.scene
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Faden hat keinen eigenen Server. Damit du eine Antwort bekommst, geht Folgendes direkt an den Anbieter, den du eingerichtet hast:")
                            .font(EH.bodySmall).foregroundStyle(EH.slate)

                        ForEach(request.byHost, id: \.host) { entry in
                            HairlineCard(padding: 14) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(verbatim: entry.host)
                                        .font(EH.mono).foregroundStyle(EH.navy)
                                        .lineLimit(1).truncationMode(.middle)
                                    ForEach(entry.purposes, id: \.self) { purpose in
                                        VStack(alignment: .leading, spacing: 6) {
                                            EH.label(purpose.title)
                                            ForEach(Array(purpose.contents.enumerated()), id: \.offset) { _, line in
                                                HStack(alignment: .top, spacing: 7) {
                                                    Text(verbatim: "—").font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                                    Text(line).font(.eh(13, .footnote)).foregroundStyle(EH.slate)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Text("Der Anbieter verarbeitet diese Daten nach seinen eigenen Bedingungen und seiner Datenschutzerklärung. Faden fragt pro Anbieter einmal; ohne dein Einverständnis wird nichts gesendet.")
                            .font(.eh(12, .caption)).foregroundStyle(EH.muted)

                        HStack(spacing: 12) {
                            Button("Abbrechen", action: onCancel)
                                .buttonStyle(EHButtonStyle())
                            Button("Einverstanden", action: onAgree)
                                .buttonStyle(EHButtonStyle(prominent: true))
                                .accessibilityIdentifier("dataSharing.agree")
                        }
                    }
                    .padding(EH.gutter)
                }
            }
            .navigationTitle("Bevor etwas gesendet wird")
            .navigationBarTitleDisplayMode(.inline)
        }
        // A decision, not a notice: swiping it away would leave the question open
        // without an answer. Cancel is one tap away.
        .interactiveDismissDisabled()
    }
}

extension SharingPurpose {
    var title: LocalizedStringKey {
        switch self {
        case .chat:          return "Für die Antworten"
        case .search:        return "Für die Websuche"
        case .embedding:     return "Für das Gedächtnis"
        case .transcription: return "Für die Spracherkennung"
        case .speech:        return "Für die Sprachausgabe"
        }
    }

    /// What is sent, stated concretely. Kept in step with what the request builders
    /// actually put on the wire — `AgentRunner`, `TurnContext`, `Tools`.
    var contents: [LocalizedStringKey] {
        switch self {
        case .chat:
            return ["Deine Nachrichten, den bisherigen Verlauf der Unterhaltung und deine Anweisungen an Faden",
                    "Angehängte Bilder sowie Dokumente und Einträge aus Ordner oder Fundus, die du freigibst",
                    "Was Faden sich über dich gemerkt hat, wenn das Gedächtnis an ist",
                    "Datum, Uhrzeit und Zeitzone deines Geräts",
                    "Suchergebnisse und Webseiten, die Faden für eine Antwort abruft"]
        case .search:
            return ["Suchanfragen, die das Modell aus deinen Fragen formuliert"]
        case .embedding:
            return ["Auszüge aus deinen Gesprächen und die daraus gemerkten Fakten, damit sie sich wiederfinden lassen"]
        case .transcription:
            return ["Deine Sprachaufnahmen, um sie in Text umzuwandeln"]
        case .speech:
            return ["Die Antworten, die vorgelesen werden sollen"]
        }
    }
}

extension View {
    /// Presents the disclosure for a pending request. "Agree" records the consent and,
    /// once the sheet is gone, runs the request's continuation; "Cancel" only closes.
    func dataSharingConsent(_ request: Binding<DataSharingRequest?>, model: AppModel) -> some View {
        modifier(DataSharingConsentModifier(request: request, model: model))
    }
}

private struct DataSharingConsentModifier: ViewModifier {
    @Binding var request: DataSharingRequest?
    let model: AppModel
    /// Held until the sheet has closed: the continuation may dismiss the view that
    /// presented it, and doing that while the sheet is still on its way out drops one
    /// of the two dismissals.
    @State private var afterDismiss: (() -> Void)?

    func body(content: Content) -> some View {
        content.sheet(item: $request, onDismiss: {
            let next = afterDismiss
            afterDismiss = nil
            next?()
        }) { pending in
            DataSharingSheet(request: pending, onAgree: {
                model.grant(pending.needs)
                afterDismiss = pending.onAgree
                request = nil
            }, onCancel: {
                afterDismiss = nil
                request = nil
            })
        }
    }
}
