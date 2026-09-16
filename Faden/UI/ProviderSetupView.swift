import SwiftUI

/// Sets up a provider: address, key, and which model answers first.
///
/// **One** entry arises here and not one per model. That is the difference from the
/// earlier version, and it has a reason: a provider is an address with a key, and the
/// models inside it are roles — which one answers, which one steps in, which one looks
/// at the images. As a flat list side by side they could only be edited one at a time,
/// and whoever wanted a second model from the same provider typed the address and the
/// key out again.
///
/// The loaded list travels into the entry with it. The roles are filled afterwards in
/// the provider, without the endpoint having to be asked again.
struct ProviderSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var wireFormat: LLMWireFormat = .openai
    @State private var baseURL = ""
    @State private var path = LLMConfig.defaultPath(for: .openai)
    @State private var key = ""

    @State private var models: [RemoteModel] = []
    /// Which model answers first. The remaining roles come afterwards in the provider.
    @State private var picked: String?
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    /// Typed manually when the endpoint publishes no list.
    @State private var manualModel = ""
    /// The sentence for the chosen preset, as long as one comes with it.
    @State private var presetNote = ""
    /// Holds the reset on a format change while a preset is taking effect.
    ///
    /// Changing the format otherwise resets the path to the default — which is right
    /// when the user flips the switch, and wrong when the preset has just set both
    /// together. Today the path happens to match the default for every preset; the next
    /// entry in the list must not rely on that coincidence.
    @State private var applyingPreset = false

    private var shown: [RemoteModel] {
        guard !search.isEmpty else { return models }
        return models.filter { $0.id.localizedCaseInsensitiveContains(search) }
    }

    /// Writes a preset into the fields.
    ///
    /// “Your own endpoint” deliberately enters nothing: the preset's name would be a lie
    /// as a provider name there, and an empty field says more clearly that it is now the
    /// user's turn.
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

    /// The first setup without a setup.
    ///
    /// For somebody without an endpoint this is the only way to use the app at all — and
    /// at the same time the most honest moment to tell them what they are missing by it.
    /// Both therefore stand on the same page.
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
        // Apple's model needs nothing filled in — only that the system hands it out.
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
        // The whole list moves in, not only the chosen model: the remaining roles are
        // filled from it in a moment, and nobody should have to wait on the network
        // again for that.
        c.knownModels = models
        // What the list says about the main model moves in with it. It is only checked
        // in the connection test — there the measurement wins.
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
        // The first provider set up becomes the active one.
        if model.settings.activeLLMID == nil { model.settings.activeLLMID = c.id }
        model.persist()
        model.recomputeUsage()
        dismiss()
    }

    /// Enters Apple's model: no key, no address, no model name.
    ///
    /// The context window set small and not to the usual default: the system model has a
    /// few thousand tokens, and a bar promising 200,000 would lie rather than warn on
    /// the first longer conversation.
    private func applyApple() {
        var c = LLMConfig()
        c.name = "Apple · auf dem Gerät"
        c.wireFormat = .appleOnDevice
        c.model = "apple-system"
        c.contextWindow = 4_000
        c.maxOutputTokens = 1_500
        // Fixed and not growing: Apple's on-device model has a small window that does
        // not get any larger by asking for more.
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
