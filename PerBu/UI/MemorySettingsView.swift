import SwiftUI

struct MemorySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var stored = false
    @State private var testState: String?
    @State private var testing = false
    @State private var counts: (nodes: Int, edges: Int) = (0, 0)
    @State private var index = MemoryStore.IndexStatus()
    @State private var working = false
    @State private var confirmRebuild = false
    @State private var confirmDrop = false
    @State private var assetsReady = LocalEmbedder.hasAssets
    @State private var loadingAssets = false
    @State private var assetProblem: String?

    var body: some View {
        @Bindable var model = model

        ZStack {
            EH.scene
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    Toggle(isOn: $model.settings.memory.enabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Gedächtnis führen").font(EH.body).foregroundStyle(EH.navy)
                            Text("Faden baut aus euren Gesprächen einen Wissensgraphen: Dinge und ihre Beziehungen, statt loser Notizen.")
                                .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        }
                    }
                    .tint(EH.navy)

                    if model.settings.memory.enabled {
                        VStack(alignment: .leading, spacing: 12) {
                            sourceSection

                            if !BundledSetup.isManaged, model.settings.memory.source == .endpoint {
                            EH.label("Endpoint")
                            Text("Der Endpoint spricht dasselbe Format wie dein Modell — oft derselbe Anbieter.")
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
                                        Text("Die Fakten sind gespeichert, nur noch nicht durchsuchbar. Faden versucht es im Minutentakt weiter.")
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

                        indexSection
                    }
                }
                .padding(EH.gutter)
            }
        }
        .navigationTitle("Gedächtnis")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            stored = Keychain.has(account: model.settings.memory.embeddingKeychainAccount)
            // Die Wahrheit über das Modell steht im Dateisystem, nicht in einer
            // Zustandsvariablen von vorhin: ein Download kann angekommen sein,
            // während dieser Bildschirm zu war.
            assetsReady = LocalEmbedder.hasAssets
            await MemoryStore.shared.load()
            counts = await MemoryStore.shared.counts
            await refreshIndex()
            model.memoryProgress.pending = index.needsWork
        }
        .onDisappear { model.persist() }
    }

    // MARK: Woher die Vektoren kommen

    /// Die Wahl zwischen Endpoint und Gerät — mit den gemessenen Zahlen daneben.
    ///
    /// Beide Wege haben einen klaren Preis, und keiner davon ist eine Meinung: das
    /// Netzmodell trifft öfter, das Gerät gibt nichts heraus und kostet 108 MB. Wer
    /// das entscheiden soll, soll beides sehen.
    @ViewBuilder
    private var sourceSection: some View {
        @Bindable var model = model

        EH.label("Einbettungen")

        Picker("Woher", selection: $model.settings.memory.source) {
            Text("Dein Endpoint").tag(MemoryConfig.Source.endpoint)
            Text("Auf dem Gerät").tag(MemoryConfig.Source.onDevice)
        }
        .pickerStyle(.segmented)
        .disabled(!LocalEmbedder.isSupported)
        .onChange(of: model.settings.memory.source) { _, _ in
            Task { await refreshIndex() }
        }

        if model.settings.memory.source == .onDevice {
            VStack(alignment: .leading, spacing: 8) {
                if !LocalEmbedder.isSupported {
                    Text("Dieses Gerät bringt das Modell nicht mit.")
                        .font(.eh(12, .caption)).foregroundStyle(EH.bad)
                } else if assetsReady {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle")
                            .font(.eh(12, .caption)).foregroundStyle(EH.good)
                        Text("Modell liegt auf diesem Gerät.")
                            .font(EH.bodySmall).foregroundStyle(EH.slate)
                    }
                } else {
                    Button { loadAssets() } label: {
                        HStack(spacing: 8) {
                            if loadingAssets {
                                ProgressView().controlSize(.mini).tint(.white)
                            } else {
                                Image(systemName: "arrow.down.circle").font(.eh(12, .caption))
                            }
                            Text(loadingAssets ? "Lädt … das dauert" : "Modell laden · 108 MB")
                                .font(.eh(13, .footnote))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: EH.radius, style: .continuous)
                            .fill(EH.navy))
                    }
                    .buttonStyle(EHTap())
                    .disabled(loadingAssets)
                }

                if loadingAssets {
                    // Apples `requestAssets()` meldet keinen Fortschritt, nur fertig
                    // oder nicht. Einen Balken zu zeigen, der nichts misst, wäre
                    // gelogen; also steht hier, woran man ist.
                    Text("Apple lädt das Modell im Hintergrund. Einen Fortschritt meldet das System dabei nicht — du kannst die App in der Zwischenzeit benutzen.")
                        .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                }

                if let assetProblem {
                    Text(assetProblem).font(.eh(12, .caption)).foregroundStyle(EH.bad)
                }

                Text("Kein Satz verlässt das Telefon, und es braucht keinen Endpoint. "
                     + "Dafür trifft es gröber: auf neun Fragen gegen vierzehn Erinnerungen "
                     + "fünfmal richtig gegen siebenmal beim Netzmodell. Eingebettet wird in "
                     + "8 ms je Satz statt gut acht Sekunden für eine ganze Aufnahme.")
                    .font(.eh(12, .caption)).foregroundStyle(EH.muted)
            }
        } else {
            Text("Für das Wiederfinden braucht es Vektoren. Sie entstehen bei deinem Anbieter.")
                .font(.eh(12, .caption)).foregroundStyle(EH.muted)
        }

        if index.foreign > 0 {
            Text("Ein Wechsel macht den vorhandenen Index unbrauchbar — die Vektoren der "
                 + "anderen Quelle liegen in einem anderen Raum. Sie werden ersetzt, unten steht wie viele.")
                .font(.eh(12, .caption)).foregroundStyle(EH.warn)
        }
    }

    private func loadAssets() {
        loadingAssets = true
        assetProblem = nil
        Task {
            do {
                try await LocalEmbedder.requestAssets()
                assetsReady = LocalEmbedder.hasAssets
                if !assetsReady { assetProblem = "Das Modell wurde nicht geladen." }
            } catch {
                assetProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loadingAssets = false
        }
    }

    // MARK: Index

    /// Was im Index liegt, und was man damit tun kann.
    ///
    /// Vektoren aus zwei Modellen im selben Raum zu vergleichen ergibt keinen
    /// Fehler, sondern eine Zahl ohne Bedeutung — und damit stille Falschtreffer.
    /// Deshalb steht hier nicht „so viele Einbettungen", sondern wie viele davon
    /// zum eingestellten Modell überhaupt passen.
    @ViewBuilder
    private var indexSection: some View {
        let modelName = model.settings.memory.effectiveModel.trimmingCharacters(in: .whitespaces)

        VStack(alignment: .leading, spacing: 10) {
            EH.label("Index")

            if index.total == 0 {
                Text("Noch nichts eingebettet.")
                    .font(EH.bodySmall).foregroundStyle(EH.slate)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    zahl(index.usable, "nutzbar", EH.good)
                    if index.foreign > 0 { zahl(index.foreign, "fremd", EH.warn) }
                    if index.missing > 0 { zahl(index.missing, "offen", EH.muted) }
                }
                // Drei große Zahlen mit winzigen Kleinversalien darunter liest eine
                // Sprachausgabe als Zahlenfolge vor. Zusammengefasst ist es ein Satz.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(index.usable) nutzbar, \(index.foreign) fremd, \(index.missing) offen")
                .accessibilityIdentifier("indexStatus")

                if let dimension = index.dimension {
                    Text("\(modelName.isEmpty ? "Kein Modell eingetragen" : modelName) · \(dimension) Dimensionen")
                        .font(.eh(11, .caption)).foregroundStyle(EH.muted)
                }

                if index.foreign > 0 {
                    let fremde = index.byModel
                        .filter { EmbeddingStamp.normalise($0.key) != EmbeddingStamp.normalise(modelName) }
                        .sorted { $0.value > $1.value }
                        .map { "\($0.key) (\($0.value))" }
                        .joined(separator: ", ")
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.eh(12, .caption)).foregroundStyle(EH.warn)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Aus anderer Herkunft: \(fremde)")
                                .font(EH.bodySmall).foregroundStyle(EH.navy)
                            Text("Diese Vektoren zählen nicht mit — sie stammen aus einem anderen Raum. Beim nächsten Nachholen werden sie ersetzt.")
                                .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        }
                    }
                }
            }

            if index.total > 0 {
                HStack(spacing: 10) {
                    Button { confirmRebuild = true } label: {
                        knopf("arrow.clockwise", "Neu aufbauen")
                    }
                    .buttonStyle(EHTap())
                    .disabled(working || modelName.isEmpty)

                    Button { confirmDrop = true } label: {
                        knopf("trash", "Index löschen")
                    }
                    .buttonStyle(EHTap())
                    .disabled(working)
                }
                .opacity(working ? 0.5 : 1)

                Text("Gelöscht wird nur der Index, nicht das Gemerkte. Die Fakten bleiben; bis ein neuer Index steht, findet die Ähnlichkeitssuche sie nicht. Solange das Gedächtnis an ist und ein Endpoint steht, baut Faden ihn von selbst wieder auf.")
                    .font(.eh(12, .caption)).foregroundStyle(EH.muted)
            }
        }
        .confirmationDialog("Index neu aufbauen?", isPresented: $confirmRebuild, titleVisibility: .visible) {
            Button("\(index.total) neu einbetten", role: .destructive) { rebuild() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Vektoren werden verworfen und über deinen Endpoint neu geholt. Das kostet \(index.total) Einbettungen.")
        }
        .confirmationDialog("Index löschen?", isPresented: $confirmDrop, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { drop() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Vektoren werden entfernt, die Fakten bleiben.")
        }
    }

    private func zahl(_ n: Int, _ wort: String, _ farbe: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(.eh(20, .title3, weight: .semibold)).foregroundStyle(farbe)
            EH.label(wort)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func knopf(_ symbol: String, _ titel: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.eh(11, .caption))
            Text(titel).font(.eh(13, .footnote))
        }
        .foregroundStyle(EH.slate)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: EH.radius, style: .continuous).fill(EH.surface))
        .overlay(RoundedRectangle(cornerRadius: EH.radius, style: .continuous)
            .stroke(EH.hairStrong, lineWidth: EH.hairWidth))
        .contentShape(Rectangle())
    }

    private func refreshIndex() async {
        index = await MemoryStore.shared.indexStatus(model: model.settings.memory.effectiveModel)
    }

    private func rebuild() {
        working = true
        Task {
            await MemoryStore.shared.dropEmbeddings(keeping: nil)
            await refreshIndex()
            model.memoryProgress.pending = index.needsWork
            working = false
            model.runBackfill()
        }
    }

    private func drop() {
        working = true
        Task {
            await MemoryStore.shared.dropEmbeddings(keeping: nil)
            await refreshIndex()
            model.memoryProgress.pending = index.needsWork
            working = false
        }
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
