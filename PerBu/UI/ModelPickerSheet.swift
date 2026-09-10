import SwiftUI

/// Lists the models an endpoint offers, with whatever it says about each one.
struct ModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let config: LLMConfig
    let apiKey: String
    /// Called with the chosen model and the limits the endpoint reported for it.
    var onPick: (RemoteModel) -> Void

    @State private var models: [RemoteModel] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""

    private var shown: [RemoteModel] {
        guard !search.isEmpty else { return models }
        return models.filter { $0.id.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            ZStack {
                EH.scene
                Group {
                    if loading {
                        VStack(spacing: 12) {
                            ProgressView().tint(EH.muted)
                            EH.label("Frage den Endpoint")
                        }
                    } else if let error {
                        VStack(alignment: .leading, spacing: 12) {
                            HairlineCard(padding: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    EH.label("Liste nicht abrufbar")
                                    Text(error).font(.eh(12, .caption)).foregroundStyle(EH.slate)
                                    Text("Der Modellname lässt sich weiterhin von Hand eintragen.")
                                        .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                }
                            }
                            Spacer()
                        }
                        .padding(EH.gutter)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(shown) { m in
                                    Button {
                                        onPick(m)
                                        dismiss()
                                    } label: {
                                        HairlineCard(padding: 13,
                                                     fill: m.id == config.model ? EH.surfaceSunk : EH.surface) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(m.title)
                                                    .font(EH.mono)
                                                    .foregroundStyle(EH.navy)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                if !m.stats.isEmpty {
                                                    Text(m.stats)
                                                        .font(.eh(11, .caption))
                                                        .foregroundStyle(EH.muted)
                                                }
                                            }
                                        }
                                    }
                                    .buttonStyle(EHTap())
                                }
                                if shown.isEmpty {
                                    Text("Nichts gefunden.")
                                        .font(EH.bodySmall).foregroundStyle(EH.muted)
                                        .padding(.top, 20)
                                }
                            }
                            .padding(EH.gutter)
                        }
                        .searchable(text: $search, prompt: "Modell suchen")
                    }
                }
            }
            .navigationTitle(models.isEmpty ? "Modelle" : "\(models.count) Modelle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
            }
        }
        .task {
            do {
                models = try await ModelCatalog.fetch(config: config, apiKey: apiKey)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
    }
}
