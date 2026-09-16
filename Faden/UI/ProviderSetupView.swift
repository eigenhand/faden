import SwiftUI

/// Richtet einen Anbieter ein: Adresse, Schlüssel, und welches Modell zuerst
/// antwortet.
///
/// Hier entsteht **ein** Eintrag und nicht einer je Modell. Das ist der Unterschied
/// zur früheren Fassung, und er hat einen Grund: ein Anbieter ist eine Adresse mit
/// einem Schlüssel, und die Modelle darin sind Rollen — welches antwortet, welches
/// einspringt, welches die Bilder ansieht. Als flache Liste nebeneinander liessen
/// sie sich nur einzeln bearbeiten, und wer ein zweites Modell desselben Anbieters
/// wollte, tippte Adresse und Schlüssel noch einmal ab.
///
/// Die geladene Liste wandert mit in den Eintrag. Die Rollen werden danach im
/// Anbieter besetzt, ohne dass der Endpoint dafür noch einmal gefragt werden muss.
struct ProviderSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var wireFormat: LLMWireFormat = .openai
    @State private var baseURL = ""
    @State private var path = LLMConfig.defaultPath(for: .openai)
    @State private var key = ""

    @State private var models: [RemoteModel] = []
    /// Welches Modell zuerst antwortet. Die übrigen Rollen kommen danach im Anbieter.
    @State private var picked: String?
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    /// Typed manually when the endpoint publishes no list.
    @State private var manualModel = ""
    /// Der Satz zur gewählten Vorlage, solange einer dabeisteht.
    @State private var presetNote = ""
    /// Hält den Zurücksetzer am Formatwechsel an, während eine Vorlage greift.
    ///
    /// Der Wechsel des Formats setzt sonst den Pfad auf den Standard zurück — was
    /// richtig ist, wenn der Nutzer den Schalter umlegt, und falsch, wenn die
    /// Vorlage gerade beides zusammen gesetzt hat. Heute stimmt bei jeder Vorlage
    /// der Pfad zufällig mit dem Standard überein; auf dieses Zufall darf sich der
    /// nächste Eintrag in der Liste nicht verlassen.
    @State private var applyingPreset = false

    private var shown: [RemoteModel] {
        guard !search.isEmpty else { return models }
        return models.filter { $0.id.localizedCaseInsensitiveContains(search) }
    }

    /// Eine Vorlage in die Felder schreiben.
    ///
    /// „Eigener Endpoint" trägt bewusst nichts ein: der Name der Vorlage wäre dort
    /// als Anbietername gelogen, und ein leeres Feld sagt deutlicher, dass jetzt der
    /// Nutzer dran ist.
    private func apply(_ provider: ModelProvider) {
        applyingPreset = provider.wireFormat != wireFormat
        wireFormat = provider.wireFormat
        name = provider.baseURL.isEmpty ? "" : provider.name
        baseURL = provider.baseURL
        path = provider.path
        presetNote = provider.note
        models = []
        picked = nil
        error = nil
    }

    private var canLoad: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Group {
            ZStack {
                EH.scene
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {

                        VStack(alignment: .leading, spacing: 8) {
                            EH.label("Anbieter")
                            Menu {
                                ForEach(Builtins.models) { provider in
                                    Button(provider.name) { apply(provider) }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(name.isEmpty ? "Vorlage wählen" : name)
                                        .font(EH.body)
                                        .foregroundStyle(name.isEmpty ? EH.muted : EH.navy)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.down")
                                        .font(.eh(11, .caption, weight: .semibold))
                                        .foregroundStyle(EH.muted)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                    .fill(EH.surface))
                                .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                    .stroke(EH.hair, lineWidth: EH.hairWidth))
                            }
                            Text(presetNote.isEmpty
                                 ? "Adresse und Format kommen aus der Vorlage. Den Schlüssel trägst du selbst ein — er liegt im Schlüsselbund des Geräts."
                                 : presetNote)
                                .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            EH.label("Format")
                            Picker("", selection: $wireFormat) {
                                ForEach(LLMWireFormat.allCases) { Text($0.shortLabel).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: wireFormat) { _, new in
                                guard !applyingPreset else { applyingPreset = false; return }
                                path = LLMConfig.defaultPath(for: new)
                                models = []; picked = nil
                            }
                            Text(wireFormat.hint).font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        }

                        if wireFormat.needsEndpoint {
                            field("Name des Anbieters", text: $name, placeholder: "z. B. TensorX")
                            field("Endpoint", text: $baseURL, placeholder: "https://api.beispiel.dev", mono: true)
                            field("Pfad", text: $path, placeholder: LLMConfig.defaultPath(for: wireFormat), mono: true)

                            VStack(alignment: .leading, spacing: 8) {
                                EH.label("API-Key")
                                SecureField("sk-…", text: $key)
                                    .textContentType(.oneTimeCode)
                                    .font(EH.mono)
                                    .textFieldStyle(.plain)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                        .fill(EH.surface))
                                    .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                        .stroke(EH.hair, lineWidth: EH.hairWidth))
                                Text("Wird einmal im Schlüsselbund abgelegt und von allen Modellen dieses Anbieters genutzt.")
                                    .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                            }

                            Button {
                                loadModels()
                            } label: {
                                HStack(spacing: 8) {
                                    if loading { ProgressView().controlSize(.mini).tint(.white) }
                                    Text(models.isEmpty ? "Modelle laden" : "Liste neu laden")
                                }
                            }
                            .buttonStyle(EHButtonStyle(prominent: true))
                            .disabled(!canLoad || loading)

                            if let error {
                                HairlineCard(padding: 13) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(alignment: .top, spacing: 7) {
                                            Image(systemName: "exclamationmark.circle")
                                                .font(.eh(12, .caption)).foregroundStyle(EH.bad)
                                            Text(error).font(.eh(12, .caption)).foregroundStyle(EH.slate)
                                        }
                                        Text("Der Modellname lässt sich auch von Hand eintragen:")
                                            .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                        TextField("anbieter/modell-name", text: $manualModel)
                                            .font(EH.mono)
                                            .textFieldStyle(.plain)
                                            .autocorrectionDisabled()
                                            .textInputAutocapitalization(.never)
                                            .padding(.horizontal, 10).padding(.vertical, 8)
                                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EH.surface))
                                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(EH.hair, lineWidth: EH.hairWidth))
                                    }
                                }
                            }

                            if !models.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        EH.label("\(models.count) Modelle · Hauptmodell wählen")
                                        Spacer()
                                        if picked != nil {
                                            Button("Auswahl leeren") { picked = nil }
                                                .font(.eh(11, .caption)).foregroundStyle(EH.muted)
                                        }
                                    }
                                    TextField("Suchen", text: $search)
                                        .font(EH.bodySmall)
                                        .textFieldStyle(.plain)
                                        .autocorrectionDisabled()
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                            .fill(EH.surface))
                                        .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                            .stroke(EH.hair, lineWidth: EH.hairWidth))

                                    ForEach(shown) { m in
                                        Button {
                                            picked = picked == m.id ? nil : m.id
                                        } label: {
                                            HairlineCard(padding: 12,
                                                         fill: picked == m.id ? EH.surfaceSunk : EH.surface) {
                                                HStack(spacing: 10) {
                                                    Image(systemName: picked == m.id
                                                          ? "checkmark.circle.fill" : "circle")
                                                        .font(.eh(14, .footnote))
                                                        .foregroundStyle(picked == m.id ? EH.navy : EH.hairStrong)
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text(m.title).font(EH.mono).foregroundStyle(EH.navy)
                                                            .lineLimit(1).truncationMode(.middle)
                                                        if !m.stats.isEmpty {
                                                            Text(m.stats).font(.eh(11, .caption))
                                                                .foregroundStyle(EH.muted)
                                                        }
                                                        CapabilityBadges(capabilities: m.capabilities)
                                                    }
                                                    Spacer(minLength: 0)
                                                }
                                            }
                                        }
                                        .buttonStyle(EHTap())
                                    }
                                }
                            }
                        } else {
                            appleSetup
                        }
                    }
                    .padding(EH.gutter)
                }
            }
            .navigationTitle("Anbieter hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") { apply() }
                        .foregroundStyle(EH.navy)
                        .disabled(!canApply)
                }
            }
        }
    }

    /// Die Ersteinrichtung ohne Einrichtung.
    ///
    /// Für jemanden, der keinen Endpoint hat, ist das hier der einzige Weg, die App
    /// überhaupt zu benutzen — und gleichzeitig der ehrlichste Moment, ihm zu sagen,
    /// was ihm damit fehlt. Beides steht deshalb auf derselben Seite.
    private var appleSetup: some View {
        let status = AppleModel.status
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.isUsable ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.eh(13, .caption))
                    .foregroundStyle(status.isUsable ? EH.good : EH.warn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.headline).font(EH.bodySmall.weight(.medium)).foregroundStyle(EH.navy)
                    Text(status.detail).font(.eh(12, .caption)).foregroundStyle(EH.slate)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                EH.label("Was es nicht kann")
                ForEach(AppleModel.limitations, id: \.self) { line in
                    HStack(alignment: .top, spacing: 7) {
                        Text("—").font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        Text(line).font(.eh(12, .caption)).foregroundStyle(EH.slate)
                    }
                }
            }

            Text("Ein Endpoint lässt sich jederzeit daneben einrichten. Dann steht "
                 + "beides zur Wahl, und diese Unterhaltung hier bleibt auf dem Gerät.")
                .font(.eh(12, .caption)).foregroundStyle(EH.muted)
        }
    }

    private var canApply: Bool {
        // Apples Modell braucht nichts ausgefuellt — nur, dass das System es hergibt.
        guard wireFormat.needsEndpoint else { return AppleModel.status.isUsable }
        guard canLoad else { return false }
        return picked != nil || !manualModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadModels() {
        loading = true; error = nil
        var probe = LLMConfig()
        probe.wireFormat = wireFormat
        probe.baseURL = baseURL
        probe.path = path
        let apiKey = key
        Task {
            do {
                models = try await ModelCatalog.fetch(config: probe, apiKey: apiKey)
                error = nil
            } catch {
                models = []
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
    }

    private func apply() {
        guard wireFormat.needsEndpoint else { return applyApple() }

        // One keychain item for the whole provider — every model added here points at it.
        let account = "provider.\(UUID().uuidString)"
        if !key.isEmpty { Keychain.set(key, account: account) }

        let providerName = name.trimmingCharacters(in: .whitespaces)
        let manual = manualModel.trimmingCharacters(in: .whitespaces)
        let main = models.first { $0.id == picked }
            ?? (manual.isEmpty ? nil : RemoteModel(id: manual))
        guard let main else { return }

        var c = LLMConfig()
        c.name = providerName.isEmpty ? main.id : providerName
        c.wireFormat = wireFormat
        c.baseURL = baseURL
        c.path = path
        c.model = main.id
        c.keychainAccount = account
        // Die ganze Liste zieht mit ein, nicht nur das gewählte Modell: aus ihr
        // werden gleich die übrigen Rollen besetzt, und dafür soll niemand noch
        // einmal auf das Netz warten müssen.
        c.knownModels = models
        // Was die Liste über das Hauptmodell sagt, zieht mit ein. Geprüft wird es
        // erst beim Verbindungstest — dort gewinnt die Messung.
        c.supportsVision = main.capabilities.vision == true
        c.supportsTools = main.capabilities.tools
        c.supportsReasoning = main.capabilities.reasoning
        if let ctx = main.contextLength {
            c.reportedContextLimit = ctx
            c.contextWindow = ctx
        }
        if let out = main.maxOutput {
            c.reportedOutputLimit = out
            c.maxOutputTokens = min(c.maxOutputTokens, out)
        }
        model.settings.llms.append(c)
        // Der erste eingerichtete Anbieter wird der aktive.
        if model.settings.activeLLMID == nil { model.settings.activeLLMID = c.id }
        model.persist()
        model.recomputeUsage()
        dismiss()
    }

    /// Apples Modell eintragen: kein Schluessel, keine Adresse, kein Modellname.
    ///
    /// Das Kontextfenster klein gesetzt und nicht auf den ueblichen Vorgabewert: das
    /// Systemmodell hat wenige tausend Token, und ein Balken, der 200 000 verspricht,
    /// wuerde beim ersten laengeren Gespraech luegen statt zu warnen.
    private func applyApple() {
        var c = LLMConfig()
        c.name = "Apple · auf dem Gerät"
        c.wireFormat = .appleOnDevice
        c.model = "apple-system"
        c.contextWindow = 4_000
        c.maxOutputTokens = 1_500
        // Fest und nicht wachsend: Apples Modell auf dem Gerät hat ein kleines
        // Fenster, das sich nicht dadurch vergrößert, dass man mehr verlangt.
        c.maxOutputTokensIsCustom = true
        c.supportsVision = false
        model.settings.llms.append(c)
        if model.settings.activeLLMID == nil { model.settings.activeLLMID = c.id }
        model.persist()
        model.recomputeUsage()
        dismiss()
    }

    /// "z-ai/glm-5v-turbo" reads better as "glm-5v-turbo" once the provider is named.
    private func shortName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, placeholder: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EH.label(label)
            TextField(placeholder, text: text)
                .font(mono ? EH.mono : EH.body)
                .foregroundStyle(EH.navy)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(mono ? .URL : .default)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous).fill(EH.surface))
                .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                    .stroke(EH.hair, lineWidth: EH.hairWidth))
        }
    }
}
