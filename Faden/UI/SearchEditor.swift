import SwiftUI

struct SearchEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let recipeID: UUID

    @State private var draftKey = ""
    @State private var keyStored = false
    @State private var testState: TestState = .idle
    @State private var offerAutoConfig: AutoConfigOffer?
    @State private var showAdvanced = false

    enum TestState: Equatable {
        case idle, running, ok(Int, String), failed(String)
    }

    struct AutoConfigOffer: Identifiable {
        let id = UUID()
        let reason: String
    }

    private var index: Int? { model.settings.recipes.firstIndex { $0.id == recipeID } }

    var body: some View {
        @Bindable var model = model

        ZStack {
            EH.scene
            if let i = index {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {

                        field("Name", text: $model.settings.recipes[i].name, placeholder: String(localized: "Mein Anbieter"))
                        field("URL", text: $model.settings.recipes[i].url,
                              placeholder: String(localized: "https://api.beispiel.dev/search"), mono: true, url: true)

                        VStack(alignment: .leading, spacing: 8) {
                            EH.label("API-Key")
                            SecureField(keyStored ? "gespeichert — zum Ersetzen tippen" : "Key des Anbieters",
                                        text: $draftKey)
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
                                .onChange(of: draftKey) { _, new in
                                    guard !new.isEmpty else { return }
                                    Keychain.set(new, account: model.settings.recipes[i].keychainAccount)
                                    keyStored = true
                                }
                        }

                        if let by = model.settings.recipes[i].synthesizedBy {
                            HairlineCard(padding: 12, fill: EH.surfaceSunk) {
                                VStack(alignment: .leading, spacing: 4) {
                                    EH.label("Automatisch eingerichtet")
                                    Text("Der Parser wurde von \(by) aus einer echten Antwort dieses Endpoints abgeleitet und läuft seitdem lokal auf diesem Gerät.")
                                        .font(.eh(12, .caption)).foregroundStyle(EH.slate)
                                }
                            }
                        }

                        // Test — the gateway to auto-configuration
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Button {
                                    runTest(model.settings.recipes[i])
                                } label: {
                                    HStack(spacing: 8) {
                                        if testState == .running {
                                            ProgressView().controlSize(.mini).tint(.white)
                                        }
                                        Text("Suche testen")
                                    }
                                }
                                .buttonStyle(EHButtonStyle(prominent: true))
                                .disabled(testState == .running)

                                Button(isActive ? "Aktiv" : "Aktivieren") {
                                    model.settings.activeRecipeID = recipeID
                                    model.persist()
                                }
                                .buttonStyle(EHButtonStyle())
                                .disabled(isActive)
                            }

                            switch testState {
                            case .ok(let n, let first):
                                HairlineCard(padding: 12, fill: EH.surface) {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack(spacing: 7) {
                                            Image(systemName: "checkmark.circle")
                                                .font(.eh(12, .caption)).foregroundStyle(EH.good)
                                            Text("\(n) Treffer").font(EH.bodySmall).foregroundStyle(EH.navy)
                                        }
                                        Text(first).font(.eh(12, .caption))
                                            .foregroundStyle(EH.muted).lineLimit(2)
                                        // A response can parse and still be the wrong part of the
                                        // body — the fallback heuristic guesses, and a guess can
                                        // land on a stray array. Let the user say so.
                                        Button("Sieht falsch aus — automatisch einrichten") {
                                            offerAutoConfig = AutoConfigOffer(
                                                reason: String(localized: "Der Test lieferte zwar Treffer, aber du hältst sie für falsch."))
                                        }
                                        .font(.eh(12, .caption))
                                        .foregroundStyle(EH.slate)
                                        .padding(.top, 1)
                                    }
                                }
                            case .failed(let msg):
                                HairlineCard(padding: 12, fill: EH.surface) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(alignment: .top, spacing: 7) {
                                            Image(systemName: "exclamationmark.circle")
                                                .font(.eh(12, .caption)).foregroundStyle(EH.bad)
                                            Text(msg).font(.eh(12, .caption))
                                                .foregroundStyle(EH.slate).textSelection(.enabled)
                                        }
                                    }
                                }
                            default:
                                EmptyView()
                            }
                        }

                        DisclosureGroup(isExpanded: $showAdvanced) {
                            VStack(alignment: .leading, spacing: 16) {
                                Picker("Methode", selection: $model.settings.recipes[i].method) {
                                    ForEach(HTTPMethodKind.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .pickerStyle(.segmented)

                                AuthStyleEditor(style: $model.settings.recipes[i].authStyle)

                                if model.settings.recipes[i].method == .get {
                                    field("Query-Parameter",
                                          text: Binding(
                                            get: { model.settings.recipes[i].queryParamName ?? "" },
                                            set: { model.settings.recipes[i].queryParamName = $0.isEmpty ? nil : $0 }),
                                          placeholder: "q", mono: true)
                                } else {
                                    field("Body-Vorlage",
                                          text: Binding(
                                            get: { model.settings.recipes[i].bodyTemplate ?? "" },
                                            set: { model.settings.recipes[i].bodyTemplate = $0.isEmpty ? nil : $0 }),
                                          placeholder: #"{"query":"{{query}}"}"#, mono: true)
                                }

                                EH.label("Antwort")
                                field("Pfad zu den Treffern", text: $model.settings.recipes[i].resultsPath,
                                      placeholder: "web.results", mono: true)
                                field("Titel-Feld", text: $model.settings.recipes[i].titleKey,
                                      placeholder: "title", mono: true)
                                field("URL-Feld", text: $model.settings.recipes[i].urlKey,
                                      placeholder: "url", mono: true)
                                field("Auszug-Feld", text: $model.settings.recipes[i].snippetKey,
                                      placeholder: "description", mono: true)

                                Text("Platzhalter: {{query}}, {{key}}, {{count}}")
                                    .font(.eh(11, .caption)).foregroundStyle(EH.muted)
                            }
                            .padding(.top, 12)
                        } label: {
                            EH.label("Details")
                        }
                        .tint(EH.muted)

                        Button(role: .destructive) {
                            Keychain.delete(account: model.settings.recipes[i].keychainAccount)
                            model.settings.recipes.remove(at: i)
                            if model.settings.activeRecipeID == recipeID {
                                model.settings.activeRecipeID = model.settings.recipes.first?.id
                            }
                            model.persist()
                            dismiss()
                        } label: {
                            Text("Anbieter entfernen").font(.eh(14, .footnote)).foregroundStyle(EH.bad)
                        }
                        .padding(.top, 6)
                    }
                    .padding(EH.gutter)
                }
            }
        }
        .navigationTitle("Suchanbieter")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let i = index else { return }
            keyStored = Keychain.has(account: model.settings.recipes[i].keychainAccount)
        }
        .onDisappear { model.persist() }
        // The heart of the auto-configuration flow: a failing test offers a way out.
        .alert("Endpoint automatisch einrichten?", isPresented: Binding(
            get: { offerAutoConfig != nil },
            set: { if !$0 { offerAutoConfig = nil } }
        ), presenting: offerAutoConfig) { _ in
            Button("Einrichten lassen") {
                guard let i = index else { return }
                model.pendingAutoConfig = AppModel.PendingAutoConfig(
                    recipe: model.settings.recipes[i],
                    query: "Berlin",
                    status: 200,
                    rawPreview: "")
                offerAutoConfig = nil
                dismiss()
            }
            Button("Selbst eintragen", role: .cancel) {
                offerAutoConfig = nil
                showAdvanced = true
            }
        } message: { offer in
            Text("\(offer.reason)\n\nFaden kann den Endpoint selbst abklopfen, sich die Antwort ansehen und den Parser von einem deiner Modelle ableiten lassen. Der fertige Parser läuft danach lokal auf diesem Gerät.")
        }
    }

    private var isActive: Bool {
        model.settings.activeRecipeID == recipeID
            || (model.settings.activeRecipeID == nil && model.settings.recipes.first?.id == recipeID)
    }

    private func runTest(_ recipe: SearchRecipe) {
        testState = .running
        let key = Keychain.get(account: recipe.keychainAccount) ?? ""
        Task {
            do {
                let outcome = try await RecipeEngine.search(
                    recipe, query: "Berlin", key: key,
                    count: model.settings.resultsPerSearch)
                let first = outcome.results.first.map { "\($0.title) — \($0.url)" } ?? ""
                testState = .ok(outcome.results.count, first)
            } catch let error as SearchError {
                testState = .failed(error.errorDescription ?? String(localized: "Fehlgeschlagen"))
                switch error {
                case .unparsable, .http:
                    offerAutoConfig = AutoConfigOffer(reason: error.errorDescription ?? "")
                default:
                    break
                }
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, placeholder: String,
                       mono: Bool = false, url: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EH.label(label)
            TextField(placeholder, text: text)
                .font(mono ? EH.mono : EH.body)
                .foregroundStyle(EH.navy)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(url ? .URL : .default)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous).fill(EH.surface))
                .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                    .stroke(EH.hair, lineWidth: EH.hairWidth))
        }
    }
}

struct AuthStyleEditor: View {
    @Binding var style: AuthStyle
    @State private var kind = 0
    @State private var name = ""
    @State private var template = "{{key}}"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EH.label("Authentifizierung")
            Picker("", selection: $kind) {
                Text("Header").tag(0)
                Text("Query").tag(1)
                Text("Ohne").tag(2)
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, _ in push() }

            if kind != 2 {
                HStack(spacing: 8) {
                    TextField(kind == 0 ? "Authorization" : "api_key", text: $name)
                        .font(EH.mono).autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: name) { _, _ in push() }
                    if kind == 0 {
                        TextField("Bearer {{key}}", text: $template)
                            .font(EH.mono).autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: template) { _, _ in push() }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous).fill(EH.surface))
                .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                    .stroke(EH.hair, lineWidth: EH.hairWidth))
            }
        }
        .onAppear {
            switch style {
            case .header(let n, let t): kind = 0; name = n; template = t
            case .queryParam(let n):    kind = 1; name = n
            case .none:                 kind = 2
            }
        }
    }

    private func push() {
        switch kind {
        case 0: style = .header(name: name.isEmpty ? "Authorization" : name,
                                valueTemplate: template.isEmpty ? "{{key}}" : template)
        case 1: style = .queryParam(name: name.isEmpty ? "api_key" : name)
        default: style = .none
        }
    }
}
