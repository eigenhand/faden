import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Goes straight to the provider form when nothing is set up yet.
    ///
    /// On a first run the settings list is a list of empty sections, and the only
    /// thing anyone opened it for is the one form that makes the app work at all.
    /// Making them find it costs a step at exactly the point where the research on
    /// activation says steps are most expensive. The back button still leads to the
    /// full list, so nothing is hidden — it is only reordered.
    @State private var goStraightToProvider = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            ZStack {
                EH.scene
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {

                        // This section used to be hidden in builds with a bundled
                        // provider: there was nothing to choose, and showing the
                        // machinery only invited somebody to break a working setup.
                        // Since Apple's model stands beside it in the system there is
                        // something to choose — and a tester meant to try exactly that
                        // could not reach it.
                        section("Anbieter") {
                            if model.settings.llms.isEmpty {
                                emptyRow("Noch kein Anbieter hinterlegt.")
                            }
                            ForEach(model.settings.llms) { llm in
                                NavigationLink {
                                    ModelEditor(configID: llm.id)
                                } label: {
                                    row(title: llm.name,
                                        subtitle: roles(of: llm),
                                        active: model.settings.activeLLMID == llm.id
                                             || (model.settings.activeLLMID == nil && model.settings.llms.first?.id == llm.id))
                                }
                                .buttonStyle(EHTap())
                            }
                            HStack(spacing: 10) {
                                // A push, not a sheet: this screen is itself presented
                                // as a sheet, and stacking overlays breaks the way back
                                // — people lose track of which layer they are on.
                                NavigationLink {
                                    ProviderSetupView()
                                } label: {
                                    Text("Anbieter hinzufügen")
                                        .font(.eh(15, .callout, weight: .medium))
                                        .foregroundStyle(model.settings.llms.isEmpty ? .white : EH.navy)
                                        .padding(.horizontal, 18).padding(.vertical, 11)
                                        .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                            .fill(model.settings.llms.isEmpty ? EH.navy : EH.surface))
                                        .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                            .stroke(model.settings.llms.isEmpty ? .clear : EH.hair,
                                                    lineWidth: EH.hairWidth))
                                }
                                .buttonStyle(EHTap())

                                Button("Von Hand eintragen") {
                                    var c = LLMConfig()
                                    c.path = LLMConfig.defaultPath(for: c.wireFormat)
                                    model.settings.llms.append(c)
                                    model.settings.activeLLMID = c.id
                                    model.persist()
                                }
                                .buttonStyle(EHButtonStyle())
                            }
                        }

                        section("Websuche") {
                            Toggle(isOn: $model.settings.searchEnabled) {
                                Text("Suche erlauben").font(EH.body).foregroundStyle(EH.navy)
                            }
                            .tint(EH.navy)
                            .onChange(of: model.settings.searchEnabled) { _, _ in model.persist() }

                            if model.settings.recipes.isEmpty {
                                emptyRow("Noch kein Anbieter hinterlegt.")
                            }
                            ForEach(model.settings.recipes) { recipe in
                                NavigationLink {
                                    SearchEditor(recipeID: recipe.id)
                                } label: {
                                    row(title: recipe.name,
                                        subtitle: recipe.synthesizedBy.map { "automatisch eingerichtet · \($0)" }
                                            ?? (recipe.url.isEmpty ? "unvollständig" : host(recipe.url)),
                                        active: model.settings.activeRecipeID == recipe.id
                                             || (model.settings.activeRecipeID == nil && model.settings.recipes.first?.id == recipe.id))
                                }
                                .buttonStyle(EHTap())
                            }

                            Menu {
                                ForEach(BuiltinRecipes.all) { preset in
                                    Button(preset.name) {
                                        var r = preset
                                        r.id = UUID()
                                        r.keychainAccount = UUID().uuidString
                                        model.settings.recipes.append(r)
                                        model.settings.activeRecipeID = r.id
                                        model.persist()
                                    }
                                }
                            } label: {
                                Text("Anbieter hinzufügen")
                                    .font(.eh(15, .callout, weight: .medium))
                                    .foregroundStyle(EH.navy)
                                    .padding(.horizontal, 18).padding(.vertical, 11)
                                    .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                        .fill(EH.surface))
                                    .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                        .stroke(EH.hair, lineWidth: EH.hairWidth))
                            }

                            stepperRow(
                                "Treffer pro Suche",
                                value: $model.settings.resultsPerSearch,
                                range: 1...10)
                        }

                        section("Stimme") {
                            NavigationLink {
                                PersonaSettingsView()
                            } label: {
                                row(title: model.settings.persona.displayName,
                                    subtitle: personaSubtitle,
                                    active: true)
                            }
                            .buttonStyle(EHTap())
                        }

                        section("Sprache") {
                            NavigationLink {
                                SpeechSettingsView()
                            } label: {
                                row(title: "Diktat und Vorlesen",
                                    subtitle: speechSubtitle,
                                    active: model.settings.speech.sttSource == .remote
                                         || model.settings.speech.ttsSource != .off)
                            }
                            .buttonStyle(EHTap())
                        }

                        section("Gedächtnis") {
                            NavigationLink {
                                MemorySettingsView()
                            } label: {
                                row(title: "Wissensgraph",
                                    subtitle: model.settings.memory.isReady
                                        ? "aktiv · \(model.settings.memory.embeddingModel)"
                                        : (model.settings.memory.enabled ? "unvollständig" : "aus"),
                                    active: model.settings.memory.isReady)
                            }
                            .buttonStyle(EHTap())

                            // The only route to what has been remembered. A symbol
                            // used to hang permanently in the header for it — for
                            // something needed rarely and never mid-conversation.
                            NavigationLink {
                                MemoryView()
                            } label: {
                                row(title: "Gespeicherte Gedanken",
                                    subtitle: model.settings.memory.isReady
                                        ? "ansehen und einzeln löschen" : "noch nichts gemerkt",
                                    active: false)
                            }
                            .buttonStyle(EHTap())
                        }

                        section("Kontext") {
                            // State and manual compaction — a bar at the bottom edge
                            // used to carry this. With a window of a million tokens it
                            // permanently read “0 %”, so a strip that never said
                            // anything. Here the number stands when you look for it.
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.usage.compacting ? "Verdichtet gerade …"
                                                                : "\(model.usage.percent) % belegt")
                                        .font(EH.body).foregroundStyle(EH.navy).monospacedDigit()
                                    Text("\(model.usage.used) von \(model.usage.window) Token"
                                         + (model.usage.measured ? "" : " (geschätzt)"))
                                        .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                        .monospacedDigit()
                                }
                                Spacer()
                                if model.usage.compacting {
                                    ProgressView().controlSize(.small).tint(EH.muted)
                                } else {
                                    Button("Jetzt verdichten") { model.compactNow() }
                                        .buttonStyle(EHButtonStyle())
                                        .disabled(model.messages.count < 4)
                                }
                            }

                            Toggle(isOn: $model.settings.autoCompactEnabled) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Automatisch verdichten").font(EH.body).foregroundStyle(EH.navy)
                                    Text("Fasst den älteren Verlauf im Hintergrund zusammen, sobald die Schwelle erreicht ist.")
                                        .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                }
                            }
                            .tint(EH.navy)
                            .onChange(of: model.settings.autoCompactEnabled) { _, _ in model.persist() }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Schwelle").font(EH.bodySmall).foregroundStyle(EH.slate)
                                    Spacer()
                                    Text("\(Int(model.settings.compactionThreshold * 100)) %")
                                        .font(EH.bodySmall).monospacedDigit().foregroundStyle(EH.navy)
                                }
                                Slider(value: $model.settings.compactionThreshold, in: 0.5...0.95, step: 0.05)
                                    .tint(EH.navy)
                                    .onChange(of: model.settings.compactionThreshold) { _, _ in model.persist() }
                            }

                            Toggle(isOn: $model.settings.showThinking) {
                                Text("Gedankengang anzeigen").font(EH.body).foregroundStyle(EH.navy)
                            }
                            .tint(EH.navy)
                            .onChange(of: model.settings.showThinking) { _, _ in model.persist() }
                        }

                        // At the bottom, not the top: whoever opens the app for the
                        // first time has to set up a provider or it does nothing. The
                        // language is something you look for when you look for it.
                        section("Oberfläche") {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Sprache").font(EH.body).foregroundStyle(EH.navy)
                                    Spacer()
                                    Picker("Sprache", selection: $model.settings.language) {
                                        ForEach(AppLanguage.allCases) { language in
                                            Text(language.label).tag(language)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(EH.navy)
                                    // An identifier and not text: this picker's label
                                    // carries its own selection, and a test looking for
                                    // it would be looking for something different after
                                    // the switch.
                                    .accessibilityIdentifier("language-picker")
                                    .onChange(of: model.settings.language) { _, _ in model.persist() }
                                }
                                Text("Gilt für die Oberfläche. Systemdialoge — etwa die Frage nach Kamera oder Mikrofon — folgen weiterhin der Spracheinstellung des Geräts.")
                                    .font(.eh(12, .caption)).foregroundStyle(EH.muted)

                                HStack {
                                    Text("Erscheinungsbild").font(EH.body).foregroundStyle(EH.navy)
                                    Spacer()
                                    Picker("Erscheinungsbild", selection: $model.settings.appearance) {
                                        ForEach(AppAppearance.allCases) { appearance in
                                            Text(appearance.label).tag(appearance)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(EH.navy)
                                    .accessibilityIdentifier("appearance-picker")
                                    .onChange(of: model.settings.appearance) { _, _ in model.persist() }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            BrandRule(width: 40)
                            Text("Keys liegen im Schlüsselbund dieses Geräts. Der Verlauf bleibt lokal. Faden spricht ausschließlich mit den Endpoints, die du hier einträgst.")
                                .font(.eh(12, .caption))
                                .foregroundStyle(EH.muted)

                            // The second place for the attribution: here is where you
                            // look for it when you look for it, and it is in nobody's
                            // way who is reading.
                            Link(destination: URL(string: "https://eigenhand.dev")!) {
                                HStack(spacing: 7) {
                                    Image("BrandMark")
                                        .resizable().renderingMode(.template)
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 16, height: 16)
                                    Text("eigenhand.dev")
                                        .font(.eh(12, .caption))
                                        .underline()
                                }
                                .foregroundStyle(EH.slate)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(EHTap())
                        }
                        .padding(.top, 4)
                    }
                    .padding(EH.gutter)
                }
            }
            .navigationDestination(isPresented: $goStraightToProvider) { ProviderSetupView() }
            .onAppear {
                if model.settings.llms.isEmpty {
                    goStraightToProvider = true
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { model.persist(); model.recomputeUsage(); dismiss() }
                        .foregroundStyle(EH.navy)
                }
            }
        }
    }

    private var personaSubtitle: String {
        let p = model.settings.persona
        return [p.address.label, p.length.label, p.tone.label].joined(separator: " · ")
    }

    private var speechSubtitle: String {
        let stt = model.settings.speech.sttSource == .apple ? "Apple-Diktat" : "eigener STT-Endpoint"
        let tts: String
        switch model.settings.speech.ttsSource {
        case .off:    tts = "kein Vorlesen"
        case .apple:  tts = "Apple-Stimme"
        case .remote: tts = "eigene Stimme"
        }
        return "\(stt) · \(tts)"
    }

    private func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    @ViewBuilder
    /// Which model holds which role in this provider, in one line.
    ///
    /// The main model always, the image model only when there is one — it is the role
    /// whose absence you otherwise notice only when an image is refused. The fallback
    /// stays out: it is the case that hopefully never occurs, and one line does not hold
    /// everything.
    private func roles(of c: LLMConfig) -> String {
        guard !c.model.isEmpty else { return "unvollständig" }
        let vision = c.visionModel.trimmingCharacters(in: .whitespaces)
        return vision.isEmpty ? c.model : "\(c.model) · Bilder: \(vision)"
    }

    private func section<C: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            EH.label(title)
            content()
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(EH.bodySmall).foregroundStyle(EH.muted)
    }

    private func row(title: String, subtitle: String, active: Bool) -> some View {
        HairlineCard(padding: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(active ? EH.good : EH.hairStrong)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(EH.body).foregroundStyle(EH.navy)
                    Text(subtitle).font(.eh(12, .caption)).foregroundStyle(EH.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.eh(11, .caption, weight: .medium))
                    .foregroundStyle(EH.muted)
            }
        }
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title).font(EH.bodySmall).foregroundStyle(EH.slate)
            Spacer()
            Stepper("\(value.wrappedValue)", value: value, in: range)
                .labelsHidden()
            Text("\(value.wrappedValue)")
                .font(EH.bodySmall).monospacedDigit().foregroundStyle(EH.navy)
                .frame(width: 22, alignment: .trailing)
        }
    }
}
