import SwiftUI

struct MemorySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var stored = false
    @State private var testState: String?
    @State private var testing = false
    @State private var counts: (nodes: Int, edges: Int) = (0, 0)

    var body: some View {
        @Bindable var model = model

        ZStack {
            EH.scene
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    Toggle(isOn: $model.settings.memory.enabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Gedächtnis führen").font(EH.body).foregroundStyle(EH.navy)
                            Text("PerBu baut aus euren Gesprächen einen Wissensgraphen: Dinge und ihre Beziehungen, statt loser Notizen.")
                                .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        }
                    }
                    .tint(EH.navy)

                    if model.settings.memory.enabled {
                        VStack(alignment: .leading, spacing: 12) {
                            if !BundledSetup.isManaged {
                            EH.label("Einbettungen")
                            Text("Für das Wiederfinden braucht es Vektoren. Der Endpoint spricht dasselbe Format wie dein Modell — oft derselbe Anbieter.")
                                .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                            field("Endpoint", text: $model.settings.memory.embeddingBaseURL,
                                  placeholder: "https://api.beispiel.dev")
                            field("Pfad", text: $model.settings.memory.embeddingPath,
                                  placeholder: "/v1/embeddings")
                            field("Modell", text: $model.settings.memory.embeddingModel,
                                  placeholder: "z. B. qwen/qwen3-embedding-8b")
                            VStack(alignment: .leading, spacing: 6) {
                                EH.label("API-Key")
                                SecureField(stored ? "gespeichert — zum Ersetzen tippen" : "sk-…", text: $key)
                                    .textContentType(.oneTimeCode)
                                    .font(EH.mono).textFieldStyle(.plain)
                                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous).fill(EH.surface))
                                    .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                        .stroke(EH.hair, lineWidth: EH.hairWidth))
                                    .onChange(of: key) { _, new in
                                        guard !new.isEmpty else { return }
                                        Keychain.set(new, account: model.settings.memory.embeddingKeychainAccount)
                                        stored = true
                                    }
                            }

                            Button {
                                runTest()
                            } label: {
                                HStack(spacing: 8) {
                                    if testing { ProgressView().controlSize(.mini).tint(.white) }
                                    Text("Einbettung testen")
                                }
                            }
                            .buttonStyle(EHButtonStyle(prominent: true))
                            .disabled(testing)

                            if let testState {
                                Text(testState).font(.eh(12, .caption)).foregroundStyle(EH.slate)
                            }
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            EH.label("Verhalten")
                            Toggle(isOn: $model.settings.memory.automatic) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Von selbst merken").font(EH.body).foregroundStyle(EH.navy)
                                    Text("Nach jedem Austausch wird still im Hintergrund abgeleitet, was Bestand hat.")
                                        .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                }
                            }
                            .tint(EH.navy)

                            stepper("Erinnerungen pro Antwort", value: $model.settings.memory.topK, range: 2...15)
                            stepper("Wie weit im Graph gesucht wird", value: $model.settings.memory.neighborhoodDepth, range: 0...3)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Mindestähnlichkeit").font(EH.bodySmall).foregroundStyle(EH.slate)
                                    Spacer()
                                    Text(String(format: "%.2f", model.settings.memory.minimumSimilarity))
                                        .font(EH.mono).monospacedDigit().foregroundStyle(EH.navy)
                                }
                                Slider(value: $model.settings.memory.minimumSimilarity, in: 0.05...0.6, step: 0.05)
                                    .tint(EH.navy)
                                Text("Niedriger heißt: mehr wird erinnert, auch Entfernteres.")
                                    .font(.eh(11, .caption)).foregroundStyle(EH.muted)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            EH.label("Stand")
                            Text(counts.nodes == 0
                                 ? "Noch nichts gemerkt."
                                 : "\(counts.nodes) Dinge, \(counts.edges) Verbindungen.")
                                .font(EH.bodySmall).foregroundStyle(EH.slate)

                            if model.memoryProgress.pending > 0 {
                                HStack(alignment: .top, spacing: 7) {
                                    Image(systemName: "clock")
                                        .font(.eh(12, .caption)).foregroundStyle(EH.warn)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(model.memoryProgress.pending) warten auf Einbettung")
                                            .font(EH.bodySmall).foregroundStyle(EH.navy)
                                        Text("Die Fakten sind gespeichert, nur noch nicht durchsuchbar. PerBu versucht es im Minutentakt weiter.")
                                            .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                    }
                                }
                                Button("Jetzt nachholen") { model.runBackfill() }
                                    .font(.eh(13, .footnote)).foregroundStyle(EH.slate)
                            }

                            if let status = model.memoryProgress.status {
                                HStack(spacing: 7) {
                                    ProgressView().controlSize(.mini).tint(EH.muted)
                                    Text(status).font(.eh(12, .caption)).foregroundStyle(EH.slate)
                                }
                            }
                            Text("Alles Gemerkte steht eine Ebene zurück unter „Gespeicherte Gedanken“ — dort einzeln nachlesen und löschen. Der Graph liegt als Datei auf diesem Gerät.")
                                .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        }
                    }
                }
                .padding(EH.gutter)
            }
        }
        .navigationTitle("Gedächtnis")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            stored = Keychain.has(account: model.settings.memory.embeddingKeychainAccount)
            await MemoryStore.shared.load()
            counts = await MemoryStore.shared.counts
            model.memoryProgress.pending = await MemoryStore.shared.pendingEmbeddingCount
        }
        .onDisappear { model.persist() }
    }

    private func runTest() {
        testing = true; testState = nil
        let config = model.settings.memory
        let apiKey = Keychain.get(account: config.embeddingKeychainAccount) ?? ""
        Task {
            do {
                let v = try await Embedder(config: config, apiKey: apiKey)
                    .embed("Ein Satz zum Ausprobieren.")
                testState = "Funktioniert — \(v.count) Dimensionen."
            } catch {
                testState = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            testing = false
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            EH.label(label)
            TextField(placeholder, text: text)
                .font(EH.mono).foregroundStyle(EH.navy).textFieldStyle(.plain)
                .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous).fill(EH.surface))
                .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                    .stroke(EH.hair, lineWidth: EH.hairWidth))
        }
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title).font(EH.bodySmall).foregroundStyle(EH.slate)
            Spacer()
            Stepper("", value: value, in: range).labelsHidden()
            Text("\(value.wrappedValue)").font(EH.mono).monospacedDigit()
                .foregroundStyle(EH.navy).frame(width: 20, alignment: .trailing)
        }
    }
}
