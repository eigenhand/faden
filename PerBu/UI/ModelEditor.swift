import SwiftUI

struct ModelEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let configID: UUID

    @State private var draftKey = ""
    @State private var keyStored = false
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle
        case running(String)
        case ok(String)
        case failed(String)

        var isRunning: Bool { if case .running = self { return true }; return false }
    }

    /// Result of the image check, shown next to the vision switch.
    @State private var visionNote: (text: String, good: Bool)?
    /// Dasselbe für Werkzeuge und Gedankengang.
    @State private var toolNote: (text: String, good: Bool)?
    @State private var limitNote: String?

    private var index: Int? { model.settings.llms.firstIndex { $0.id == configID } }

    var body: some View {
        @Bindable var model = model

        ZStack {
            EH.scene
            if let i = index {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {

                        field("Name", text: $model.settings.llms[i].name, placeholder: "Mein Modell")

                        VStack(alignment: .leading, spacing: 8) {
                            EH.label("Format")
                            Picker("", selection: $model.settings.llms[i].wireFormat) {
                                ForEach(LLMWireFormat.allCases) { f in
                                    Text(f.shortLabel).tag(f)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: model.settings.llms[i].wireFormat) { _, new in
                                model.settings.llms[i].path = LLMConfig.defaultPath(for: new)
                            }
                            Text(model.settings.llms[i].wireFormat.hint)
                                .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        }

                        if model.settings.llms[i].wireFormat.needsEndpoint {
                            field("Endpoint", text: $model.settings.llms[i].baseURL,
                                  placeholder: "https://api.beispiel.dev", mono: true, url: true)
                            field("Pfad", text: $model.settings.llms[i].path,
                                  placeholder: "/v1/chat/completions", mono: true)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    EH.label("Modell")
                                    Spacer()
                                    NavigationLink {
                                        ModelPickerSheet(
                                            config: model.settings.llms[i],
                                            apiKey: Keychain.get(account: model.settings.llms[i].keychainAccount) ?? "") { picked in
                                                apply(picked, at: i)
                                            }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "list.bullet")
                                                .font(.eh(9, .caption2, weight: .medium))
                                            Text("vom Endpoint laden")
                                                .font(.eh(11, .caption, weight: .medium))
                                        }
                                        .foregroundStyle(EH.slate)
                                    }
                                    .buttonStyle(EHTap())
                                    .disabled(model.settings.llms[i].endpointURL == nil)
                                }
                                TextField("z. B. anbieter/modell-name", text: $model.settings.llms[i].model)
                                    .font(EH.mono)
                                    .foregroundStyle(EH.navy)
                                    .textFieldStyle(.plain)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                        .fill(EH.surface))
                                    .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                        .stroke(EH.hair, lineWidth: EH.hairWidth))
                                CapabilityBadges(capabilities: model.settings.llms[i].capabilities)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                EH.label("API-Key")
                                SecureField(keyStored ? "gespeichert — zum Ersetzen tippen" : "sk-…", text: $draftKey)
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
                                        Keychain.set(new, account: model.settings.llms[i].keychainAccount)
                                        keyStored = true
                                    }
                                Text("Wird im Schlüsselbund abgelegt, nicht in den Einstellungen.")
                                    .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                EH.label("Bilder")
                                Toggle(isOn: $model.settings.llms[i].supportsVision) {
                                    Text("Bilder anhängen erlauben").font(EH.body).foregroundStyle(EH.navy)
                                }
                                .tint(EH.navy)
                                if let note = visionNote {
                                    HStack(alignment: .top, spacing: 7) {
                                        Image(systemName: note.good ? "checkmark.circle" : "minus.circle")
                                            .font(.eh(12, .caption))
                                            .foregroundStyle(note.good ? EH.good : EH.muted)
                                        Text(note.text).font(.eh(12, .caption)).foregroundStyle(EH.slate)
                                    }
                                } else {
                                    Text("Der Verbindungstest probiert es selbst aus und setzt den Schalter entsprechend.")
                                        .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                EH.label("Werkzeuge und Gedankengang")
                                if let note = toolNote {
                                    HStack(alignment: .top, spacing: 7) {
                                        Image(systemName: note.good ? "checkmark.circle" : "minus.circle")
                                            .font(.eh(12, .caption))
                                            .foregroundStyle(note.good ? EH.good : EH.muted)
                                        Text(note.text).font(.eh(12, .caption)).foregroundStyle(EH.slate)
                                    }
                                } else {
                                    Text("Der Verbindungstest ruft ein Werkzeug auf, das nichts tut. "
                                         + "Kommt dabei ein Gedankengang mit, steht auch das fest.")
                                        .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                }
                            }
                        } else {
                            appleBlock
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            EH.label("Grenzen")

                            TokenSlider(
                                title: "Kontextfenster",
                                value: $model.settings.llms[i].contextWindow,
                                range: 4_000...contextCeiling(model.settings.llms[i]),
                                footnote: contextFootnote(model.settings.llms[i]))

                            TokenSlider(
                                title: "Maximale Antwortlänge",
                                value: $model.settings.llms[i].maxOutputTokens,
                                range: 256...outputCeiling(model.settings.llms[i]),
                                footnote: model.settings.llms[i].reportedOutputLimit
                                    .map { "vom Anbieter: \(RemoteModel.compact($0))" })

                            if let limitNote {
                                Text(limitNote).font(.eh(12, .caption)).foregroundStyle(EH.muted)
                            }
                        }

                        if model.settings.llms[i].wireFormat == .anthropic {
                            VStack(alignment: .leading, spacing: 10) {
                                EH.label("Anthropic")
                                Toggle(isOn: $model.settings.llms[i].requestThinking) {
                                    Text("Erweitertes Denken anfordern").font(EH.bodySmall).foregroundStyle(EH.navy)
                                }.tint(EH.navy)
                                Toggle(isOn: $model.settings.llms[i].useCacheControl) {
                                    Text("Prompt-Caching nutzen").font(EH.bodySmall).foregroundStyle(EH.navy)
                                }.tint(EH.navy)
                            }
                        }

                        // Test
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Button {
                                    runTest(model.settings.llms[i])
                                } label: {
                                    HStack(spacing: 8) {
                                        if case .running(let what) = testState {
                                            ProgressView().controlSize(.mini).tint(.white)
                                            Text(what)
                                        } else {
                                            Text(model.settings.llms[i].wireFormat.needsEndpoint ? "Verbindung testen" : "Modell testen")
                                        }
                                    }
                                }
                                .buttonStyle(EHButtonStyle(prominent: true))
                                .disabled(testState.isRunning)

                                Button {
                                    model.settings.activeLLMID = configID
                                    model.persist()
                                } label: {
                                    Text(isActive ? "Aktiv" : "Aktivieren")
                                }
                                .buttonStyle(EHButtonStyle())
                                .disabled(isActive)
                            }

                            switch testState {
                            case .ok(let msg):
                                note(msg, color: EH.good, icon: "checkmark.circle")
                            case .failed(let msg):
                                note(msg, color: EH.bad, icon: "exclamationmark.circle")
                            default:
                                EmptyView()
                            }
                        }

                        Button(role: .destructive) {
                            Keychain.delete(account: model.settings.llms[i].keychainAccount)
                            model.settings.llms.remove(at: i)
                            if model.settings.activeLLMID == configID {
                                model.settings.activeLLMID = model.settings.llms.first?.id
                            }
                            model.persist()
                            dismiss()
                        } label: {
                            Text("Modell entfernen")
                                .font(.eh(14, .footnote))
                                .foregroundStyle(EH.bad)
                        }
                        .padding(.top, 6)
                    }
                    .padding(EH.gutter)
                }
            }
        }
        .navigationTitle("Modell")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let i = index else { return }
            keyStored = Keychain.has(account: model.settings.llms[i].keychainAccount)
        }
        .onDisappear { model.persist(); model.recomputeUsage() }
    }

    /// Takes a model from the list, along with whatever limits came with it.
    private func apply(_ picked: RemoteModel, at i: Int) {
        model.settings.llms[i].model = picked.id
        var learned: [String] = []
        if let c = picked.contextLength {
            model.settings.llms[i].reportedContextLimit = c
            model.settings.llms[i].contextWindow = c
            learned.append("Kontext \(RemoteModel.compact(c))")
        }
        if let o = picked.maxOutput {
            model.settings.llms[i].reportedOutputLimit = o
            model.settings.llms[i].maxOutputTokens = min(model.settings.llms[i].maxOutputTokens, o)
            learned.append("Ausgabe \(RemoteModel.compact(o))")
        }
        limitNote = learned.isEmpty
            ? "Der Anbieter nennt für dieses Modell keine Grenzen — die Regler bleiben deine Schätzung."
            : "Vom Anbieter übernommen: " + learned.joined(separator: ", ") + "."
        visionNote = nil
        model.persist()
    }

    /// The top of the context slider: what the endpoint said, else what has provably
    /// worked, else a generous default.
    private func contextCeiling(_ c: LLMConfig) -> Int {
        if let r = c.reportedContextLimit { return max(r, 8_000) }
        return max(c.observedMaxPromptTokens * 2, 1_000_000)
    }

    private func outputCeiling(_ c: LLMConfig) -> Int {
        if let r = c.reportedOutputLimit { return max(r, 1_024) }
        return min(max(c.contextWindow, 4_096), 128_000)
    }

    private func contextFootnote(_ c: LLMConfig) -> String? {
        if let r = c.reportedContextLimit { return "vom Anbieter: \(RemoteModel.compact(r))" }
        if c.observedMaxPromptTokens > 0 {
            return "mindestens \(RemoteModel.compact(c.observedMaxPromptTokens)) belegt"
        }
        return "Anbieter nennt keine Grenze"
    }

    /// Was statt Adresse, Schlüssel und Modellname dasteht.
    ///
    /// Zwei Dinge, und das zweite ist das wichtigere: ob das System das Modell
    /// gerade hergibt, und was es nicht kann. Ein Modell ohne Werkzeuge als
    /// gleichwertige Wahl neben einem großen Endpoint anzubieten, ohne das
    /// dazuzusagen, würde bei der ersten Frage enttäuschen, die eine Websuche
    /// gebraucht hätte.
    private var appleBlock: some View {
        let status = AppleModel.status
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                EH.label("Im System")
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: status.isUsable ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.eh(13, .caption))
                        .foregroundStyle(status.isUsable ? EH.good : EH.warn)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.headline)
                            .font(EH.bodySmall.weight(.medium))
                            .foregroundStyle(EH.navy)
                        Text(status.detail)
                            .font(.eh(12, .caption))
                            .foregroundStyle(EH.slate)
                    }
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
                Text("Dafür verlässt kein Wort dieser Unterhaltung das Telefon.")
                    .font(.eh(12, .caption))
                    .foregroundStyle(EH.muted)
                    .padding(.top, 2)
            }
        }
    }

    private var isActive: Bool {
        model.settings.activeLLMID == configID
            || (model.settings.activeLLMID == nil && model.settings.llms.first?.id == configID)
    }

    /// Two checks in sequence: can we talk to the model at all, and does it take
    /// images. The second one decides the vision switch, so nobody has to guess.
    private func runTest(_ config: LLMConfig) {
        testState = .running("Verbindung …")
        visionNote = nil
        let key = Keychain.get(account: config.keychainAccount) ?? ""

        Task {
            guard config.isComplete else {
                testState = .failed("Endpoint oder Modellname fehlt.")
                return
            }
            if !config.wireFormat.needsEndpoint, !AppleModel.status.isUsable {
                testState = .failed(AppleModel.status.detail)
                return
            }
            let provider = ProviderFactory.make(for: config.wireFormat)
            let connectionLine: String
            do {
                let reply = try await provider.complete(
                    messages: [Message(role: .user, text: "Antworte mit genau einem Wort: bereit")],
                    system: "Du antwortest knapp.",
                    config: config, apiKey: key, maxTokens: 3000)
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                // „Verbindung“ waere bei Apples Modell gelogen — es gibt keine. Der
                // Test ist derselbe und pruefte dort, ob das System das Modell
                // hergibt und ob es antwortet.
                connectionLine = config.wireFormat.needsEndpoint
                    ? "Verbindung steht. Antwort: „\(trimmed.prefix(60))“"
                    : "Das Modell antwortet: „\(trimmed.prefix(60))“"
                testState = .ok(connectionLine)
            } catch {
                testState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return
            }

            // Was der Anbieter selbst nennt, steht schon in der Konfiguration — es
            // kam mit der Modellliste. Hier wird nur gesagt, woran man ist.
            //
            // Frueher stand an dieser Stelle ein Test, der eine absurde Obergrenze
            // schickte und die echte aus der Absage las. Der ist weg: die App
            // erfindet keine Zahlen, um Grenzen auszuloten. Was fehlt, lernt sie aus
            // einer Absage, die wirklich jemand kassiert hat.
            if let i = index {
                var known: [String] = []
                if let c = model.settings.llms[i].reportedContextLimit {
                    known.append("Kontext \(RemoteModel.compact(c))")
                }
                if let o = model.settings.llms[i].reportedOutputLimit {
                    known.append("Ausgabe \(RemoteModel.compact(o))")
                }
                limitNote = known.isEmpty
                    ? "Der Anbieter nennt keine Token-Grenzen. Die Regler bleiben deine "
                    + "Schätzung — stösst eine Antwort wirklich an eine Grenze, trägt die "
                    + "App sie hier ein."
                    : "Vom Anbieter genannt: " + known.joined(separator: ", ") + "."
            }

            // Only worth asking once the endpoint answers at all.
            testState = .running("Bilder …")
            let outcome = await VisionProbe.run(config: config, apiKey: key)
            guard let i = index else { return }

            switch outcome {
            case .supported:
                model.settings.llms[i].supportsVision = true
                visionNote = ("Bilder werden unterstützt — das Modell hat das Testbild richtig beschrieben.", true)
            case .acceptedButUnconfirmed(let reply):
                model.settings.llms[i].supportsVision = true
                visionNote = ("Bilder wurden angenommen, die Beschreibung war aber unklar („\(reply)“). "
                              + "Anhängen ist freigeschaltet.", true)
            case .notSupported(let why):
                model.settings.llms[i].supportsVision = false
                visionNote = ("Keine Bilder: \(why)", false)
            case .inconclusive(let why):
                visionNote = ("Nicht feststellbar: \(why) Der Schalter bleibt, wie er ist.", false)
            }

            // Werkzeuge und Gedankengang in einem Aufruf — beides steht in derselben
            // Antwort, und eine zweite Anfrage würde nur ein zweites Mal kosten.
            testState = .running("Werkzeuge …")
            let reading = await CapabilityProbe.toolsAndReasoning(config: config, apiKey: key)
            guard let i = index else { return }

            switch reading.tools {
            case .used:
                model.settings.llms[i].supportsTools = true
                toolNote = ("Werkzeuge laufen — das Modell hat das Prüfwerkzeug aufgerufen.", true)
            case .acceptedButUnused:
                model.settings.llms[i].supportsTools = true
                toolNote = ("Werkzeuge wurden angenommen, das Modell hat aber lieber geantwortet. "
                            + "Kein Fehler, nur kein Beweis.", true)
            case .refused(let why):
                model.settings.llms[i].supportsTools = false
                toolNote = ("Keine Werkzeuge: \(why)", false)
            case .inconclusive(let why):
                toolNote = ("Werkzeuge nicht feststellbar: \(why)", false)
            }
            // Ein gesehener Gedankengang ist ein Ja. Keiner gesehen ist kein Nein —
            // die meisten Anbieter halten ihn zurück, solange man nicht darum bittet.
            if reading.reasoning == true { model.settings.llms[i].supportsReasoning = true }

            model.persist()
            testState = .ok(connectionLine)
        }
    }


    // MARK: Field helpers

    private func field(_ label: String, text: Binding<String>, placeholder: String,
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

    private func note(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.eh(12, .caption)).foregroundStyle(color)
            Text(text).font(.eh(12, .caption)).foregroundStyle(EH.slate).textSelection(.enabled)
        }
    }
}
