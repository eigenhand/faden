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

                        // Frueher war dieser Abschnitt in Builds mit eingebautem
                        // Anbieter ausgeblendet: es gab nichts zu waehlen, und die
                        // Maschinerie zu zeigen lud nur dazu ein, eine funktionierende
                        // Einrichtung kaputtzumachen. Seit Apples Modell im System
                        // danebensteht, gibt es etwas zu waehlen — und ein Tester, der
                        // genau das ausprobieren soll, kam nicht heran.
                        section("Modell") {
                            if model.settings.llms.isEmpty {
                                emptyRow("Noch kein Modell hinterlegt.")
                            }
                            ForEach(model.settings.llms) { llm in
                                NavigationLink {
                                    ModelEditor(configID: llm.id)
                                } label: {
                                    row(title: llm.name,
                                        subtitle: llm.model.isEmpty ? "unvollständig" : llm.model,
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

                            if !BundledSetup.hasSearch {
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

                            // Der einzige Weg zum Gemerkten. Vorher hing dafür ein
                            // Symbol dauerhaft in der Kopfzeile — für etwas, das man
                            // selten braucht und nie im Gespräch.
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
                            // Stand und Verdichten von Hand — vorher trug das eine
                            // Leiste am unteren Rand. Bei einem Fenster von einer
                            // Million Token stand dort dauerhaft „0 %“, also ein
                            // Streifen, der nie etwas sagte. Hier steht die Zahl,
                            // wenn man sie sucht.
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

                        VStack(alignment: .leading, spacing: 6) {
                            BrandRule(width: 40)
                            Text("Keys liegen im Schlüsselbund dieses Geräts. Der Verlauf bleibt lokal. Faden spricht ausschließlich mit den Endpoints, die du hier einträgst.")
                                .font(.eh(12, .caption))
                                .foregroundStyle(EH.muted)

                            // Die zweite Stelle für die Herkunft: hier sucht man sie,
                            // wenn man sie sucht, und sie steht niemandem im Weg,
                            // der gerade liest.
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
                if model.settings.llms.isEmpty, !BundledSetup.isManaged {
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
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
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
