import SwiftUI
import UniformTypeIdentifiers

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
    /// `nil` until it has been counted once — the file lies in another app's folder and
    /// is read from disk, so the figure arrives after the screen does.
    @State private var inventoryCount: Int?
    @State private var choosingFolder = false
    /// What went wrong while adopting a folder, if anything did. Shown in place of the
    /// state line: a picker that closes and leaves everything as it was is the one
    /// outcome the user cannot tell from a successful one.
    @State private var folderError: String?

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

                        // Nothing to set up here, and that is the whole point of the
                        // section: whether it works depends on whether Fundus is on
                        // this device, not on anything typed here. So the line below
                        // the switch says which of the two cases holds — otherwise the
                        // only way to find out would be to ask the assistant and see.
                        // One section, because the rule is one rule: a tool reaches
                        // the model only when the service behind it is connected here.
                        // Two sections in two shapes — a switch over there, a picker
                        // over here — implemented the same rule and showed none.
                        section("Dienste") {
                            Text("Ein Werkzeug bekommt der Assistent erst, wenn der Dienst hier verbunden ist. Nicht verbunden heißt: es wird ihm gar nicht erst angeboten.")
                                .font(.eh(12, .caption)).foregroundStyle(EH.muted)

                            serviceRow(title: "Fundus",
                                       state: inventoryState,
                                       connected: model.settings.inventoryEnabled && FundusInventory.isPresent) {
                                Toggle(isOn: $model.settings.inventoryEnabled) {
                                    Text("Bestand lesen").font(EH.bodySmall).foregroundStyle(EH.navy)
                                }
                                .tint(EH.navy)
                                .onChange(of: model.settings.inventoryEnabled) { _, _ in
                                    model.persist()
                                    model.recomputeUsage()
                                }
                            }

                            serviceRow(title: model.settings.folder.isSet
                                              ? model.settings.folder.name : "Ordner",
                                       state: folderState,
                                       connected: model.settings.folder.isSet && folderReachable) {
                                HStack(spacing: 10) {
                                    Button(model.settings.folder.isSet ? "Anderen wählen"
                                                                       : "Ordner wählen") {
                                        choosingFolder = true
                                    }
                                    .buttonStyle(EHButtonStyle())

                                    if model.settings.folder.isSet {
                                        Button("Trennen") {
                                            model.settings.folder = FolderConfig()
                                            folderError = nil
                                            model.persist()
                                            model.recomputeUsage()
                                        }
                                        .buttonStyle(EHButtonStyle())
                                    }
                                }
                            }
                        }
                        .fileImporter(isPresented: $choosingFolder,
                                      allowedContentTypes: [.folder]) { result in
                            adoptFolder(result)
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
            // Deliberately past the cache: whoever opens this screen has usually just
            // been in Fundus, and a figure from before that visit would be the one
            // thing here that is wrong.
            .task {
                // A moved folder still resolves, for a while. Renewing it here is the
                // one moment where the screen is open and the write is natural —
                // otherwise the bookmark expires quietly and the failure surfaces weeks
                // later, mid-turn, for a folder the user can plainly see in Files.
                if let old = model.settings.folder.bookmark,
                   let fresh = SharedFolder.renewedBookmark(for: old) {
                    model.settings.folder.bookmark = fresh
                    model.persist()
                }
                guard FundusInventory.isPresent else { return }
                await FundusReader.shared.forget()
                inventoryCount = await FundusReader.shared.inventory().items.count
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

    /// Which of the three cases holds, in one sentence.
    ///
    /// The distinction between "no App Group" and "no inventory" matters: the first is
    /// a property of the build and nothing the user can do anything about, the second
    /// goes away by itself as soon as something stands in Fundus. One sentence for both
    /// would have to be vague enough to cover them, and would then help with neither.
    /// Which of the four cases holds, in one sentence.
    ///
    /// Four and not one, because they call for different things from the reader: two
    /// are theirs to change, one goes away by itself once Fundus has an entry, and one
    /// is a property of the build that nothing on this screen can touch. A sentence
    /// vague enough to cover all four would help with none.
    private var inventoryState: String {
        guard SharedContainer.isAvailable else {
            return String(localized: "Der gemeinsame Ordner der eigenhand-Apps ist in diesem Build nicht freigeschaltet.")
        }
        guard FundusInventory.isPresent else {
            return String(localized: "Kein Bestand gefunden. Es gibt ihn, sobald in Fundus auf diesem Gerät der erste Eintrag steht.")
        }
        guard model.settings.inventoryEnabled else {
            return String(localized: "Nicht verbunden. Der Bestand liegt bereit, der Assistent sieht ihn nicht.")
        }
        guard let inventoryCount else { return String(localized: "Verbunden.") }
        return String(localized: "Verbunden · \(inventoryCount) Dinge im Bestand.")
    }

    /// Whether the stored bookmark still leads anywhere.
    ///
    /// Asked of the bookmark rather than remembered from the day it was made: the folder
    /// can be deleted, renamed out from under it, or its app uninstalled, and none of
    /// those events reach this app. A green dot that meant "worked once" would be the
    /// most misleading thing on this screen.
    private var folderReachable: Bool {
        guard let bookmark = model.settings.folder.bookmark else { return false }
        return SharedFolder.resolve(bookmark) != nil
    }

    private var folderState: String {
        if let folderError { return folderError }
        guard model.settings.folder.isSet else {
            return String(localized: "Nicht verbunden. Gib einen Ordner frei — etwa einen aus Spind —, und der Assistent kann darin lesen.")
        }
        guard folderReachable else {
            return String(localized: "Nicht mehr erreichbar — umbenannt, gelöscht, oder die App dahinter ist weg. Wähl ihn neu.")
        }
        return String(localized: "Verbunden · nur lesen. Schreiben, umbenennen und löschen kann der Assistent nicht.")
    }

    /// Turns the picked folder into something that survives a restart.
    ///
    /// The bookmark has to be made while the scope is open, and that is the whole of
    /// the ceremony below: a URL from the picker is readable now and meaningless after
    /// the next launch, and a bookmark taken without the scope open is taken of
    /// something the app is not allowed to see.
    private func adoptFolder(_ result: Result<URL, Error>) {
        folderError = nil
        switch result {
        case .failure(let error):
            folderError = error.localizedDescription
        case .success(let url):
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            do {
                var config = FolderConfig()
                config.bookmark = try url.bookmarkData()
                // The name the Files app shows, not the directory on disk. The two come
                // apart exactly where it matters: the root of a File Provider is called
                // something like "File Provider Storage" underneath, and putting that
                // on the screen would name a folder the user has never seen.
                config.name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?
                    .localizedName ?? url.lastPathComponent
                config.chosenAt = Date()
                model.settings.folder = config
                model.persist()
                model.recomputeUsage()
            } catch {
                folderError = String(localized: "Der Ordner ließ sich nicht dauerhaft merken: \(error.localizedDescription)")
            }
        }
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

    /// One connected service: the dot says whether a tool is actually released, the
    /// line below says why when it is not, and the control is whatever connecting
    /// happens to look like for this one.
    ///
    /// Not `row(…)`: that one carries a chevron and belongs to a `NavigationLink`. A
    /// chevron that leads nowhere is the kind of small lie that costs somebody a tap
    /// every time they look at this screen.
    private func serviceRow<C: View>(title: String, state: String, connected: Bool,
                                     @ViewBuilder control: () -> C) -> some View {
        HairlineCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(connected ? EH.good : EH.hairStrong)
                        .frame(width: 6, height: 6)
                    Text(title).font(EH.body).foregroundStyle(EH.navy)
                    Spacer(minLength: 0)
                }
                Text(state).font(.eh(12, .caption)).foregroundStyle(EH.muted)
                control()
            }
        }
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
