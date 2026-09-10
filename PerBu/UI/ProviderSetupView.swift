import SwiftUI

/// Sets up a provider once and takes several of its models in one go.
///
/// Adding models one at a time meant retyping the same endpoint and key for every
/// one. Here the endpoint is entered once, its catalogue is fetched, and every model
/// you pick becomes an entry sharing that endpoint — and the same keychain item, so
/// the key is stored once and stays in step everywhere.
struct ProviderSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var wireFormat: LLMWireFormat = .openai
    @State private var baseURL = ""
    @State private var path = LLMConfig.defaultPath(for: .openai)
    @State private var key = ""

    @State private var models: [RemoteModel] = []
    @State private var picked: Set<String> = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    /// Typed manually when the endpoint publishes no list.
    @State private var manualModel = ""

    private var shown: [RemoteModel] {
        guard !search.isEmpty else { return models }
        return models.filter { $0.id.localizedCaseInsensitiveContains(search) }
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
                            EH.label("Format")
                            Picker("", selection: $wireFormat) {
                                ForEach(LLMWireFormat.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: wireFormat) { _, new in
                                path = LLMConfig.defaultPath(for: new)
                                models = []; picked = []
                            }
                            Text(wireFormat.hint).font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        }

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
                                    EH.label("\(models.count) Modelle · \(picked.count) gewählt")
                                    Spacer()
                                    if !picked.isEmpty {
                                        Button("Auswahl leeren") { picked = [] }
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
                                        if picked.contains(m.id) { picked.remove(m.id) } else { picked.insert(m.id) }
                                    } label: {
                                        HairlineCard(padding: 12,
                                                     fill: picked.contains(m.id) ? EH.surfaceSunk : EH.surface) {
                                            HStack(spacing: 10) {
                                                Image(systemName: picked.contains(m.id)
                                                      ? "checkmark.circle.fill" : "circle")
                                                    .font(.eh(14, .footnote))
                                                    .foregroundStyle(picked.contains(m.id) ? EH.navy : EH.hairStrong)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(m.title).font(EH.mono).foregroundStyle(EH.navy)
                                                        .lineLimit(1).truncationMode(.middle)
                                                    if !m.stats.isEmpty {
                                                        Text(m.stats).font(.eh(11, .caption))
                                                            .foregroundStyle(EH.muted)
                                                    }
                                                }
                                                Spacer(minLength: 0)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
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

    private var canApply: Bool {
        guard canLoad else { return false }
        return !picked.isEmpty || !manualModel.trimmingCharacters(in: .whitespaces).isEmpty
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
        // One keychain item for the whole provider — every model added here points at it.
        let account = "provider.\(UUID().uuidString)"
        if !key.isEmpty { Keychain.set(key, account: account) }

        let providerName = name.trimmingCharacters(in: .whitespaces)
        var chosen = models.filter { picked.contains($0.id) }
        let manual = manualModel.trimmingCharacters(in: .whitespaces)
        if chosen.isEmpty, !manual.isEmpty { chosen = [RemoteModel(id: manual)] }

        var firstID: UUID?
        for m in chosen {
            var c = LLMConfig()
            c.name = providerName.isEmpty ? m.id : "\(providerName) · \(shortName(m.id))"
            c.wireFormat = wireFormat
            c.baseURL = baseURL
            c.path = path
            c.model = m.id
            c.keychainAccount = account
            if let ctx = m.contextLength {
                c.reportedContextLimit = ctx
                c.contextWindow = ctx
            }
            if let out = m.maxOutput {
                c.reportedOutputLimit = out
                c.maxOutputTokens = min(c.maxOutputTokens, out)
            }
            model.settings.llms.append(c)
            if firstID == nil { firstID = c.id }
        }
        // Make the first addition active when nothing was set up before.
        if model.settings.activeLLMID == nil { model.settings.activeLLMID = firstID }
        model.persist()
        model.recomputeUsage()
        dismiss()
    }

    /// "z-ai/glm-5v-turbo" reads better as "glm-5v-turbo" once the provider is named.
    private func shortName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, mono: Bool = false) -> some View {
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
