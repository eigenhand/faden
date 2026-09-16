import SwiftUI

/// Where the assistant's voice is set.
///
/// In an app that brings its own keys, there is no vendor persona to inherit — the
/// person using it is the one whose voice this should be. Research on conversational
/// agents finds engagement rises with the fit between user and agent personality, and
/// that a voice which contradicts the task backfires, so this is offered as a few
/// legible choices rather than a free-text prompt nobody wants to write.
struct PersonaSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var preview: String?
    @State private var testing = false

    var body: some View {
        @Bindable var model = model

        ZStack {
            EH.scene
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    VStack(alignment: .leading, spacing: 8) {
                        EH.label("Name")
                        TextField("Faden", text: $model.settings.persona.name)
                            .font(EH.body).foregroundStyle(EH.navy)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                .fill(EH.surface))
                            .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                .stroke(EH.hair, lineWidth: EH.hairWidth))
                        Text("Wie sich der Assistent nennt, wenn er von sich spricht.")
                            .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        EH.label("Anrede")
                        Picker("", selection: $model.settings.persona.address) {
                            ForEach(Persona.Address.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        EH.label("Ausführlichkeit")
                        Picker("", selection: $model.settings.persona.length) {
                            ForEach(Persona.Length.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        EH.label("Ton")
                        Picker("", selection: $model.settings.persona.tone) {
                            ForEach(Persona.Tone.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        EH.label("Eigene Anweisungen")
                        TextField("z. B. „Nenne bei Code immer die Sprache.“",
                                  text: $model.settings.persona.custom, axis: .vertical)
                            .font(EH.bodySmall).foregroundStyle(EH.navy)
                            .lineLimit(2...6)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                .fill(EH.surface))
                            .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                .stroke(EH.hair, lineWidth: EH.hairWidth))
                    }

                    // Showing the actual sentences beats describing them: this is what
                    // the model is told, verbatim.
                    VStack(alignment: .leading, spacing: 8) {
                        EH.label("So wird es dem Modell gesagt")
                        Text(model.settings.persona.instructions)
                            .font(.eh(12.5, .caption))
                            .foregroundStyle(EH.slate)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                .fill(EH.surfaceSunk))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            runPreview()
                        } label: {
                            HStack(spacing: 8) {
                                if testing { ProgressView().controlSize(.mini).tint(.white) }
                                Text("Probe hören")
                            }
                        }
                        .buttonStyle(EHButtonStyle(prominent: true))
                        .disabled(testing || model.settings.activeLLM?.isComplete != true)

                        if let preview {
                            HairlineCard(padding: 13) {
                                Text(preview).font(EH.bodySmall).foregroundStyle(EH.navy)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        BrandRule(width: 40)
                        Text("Die Stimme gehört zum festen Teil der Anweisungen und ändert sich nur, wenn du sie änderst — sie kostet daher keine zusätzlichen Token pro Frage.")
                            .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                    }
                }
                .padding(EH.gutter)
            }
        }
        .navigationTitle("Stimme")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.persist() }
    }

    /// Asks the model a throwaway question so the chosen voice can be heard before
    /// it is used in a real conversation.
    private func runPreview() {
        guard let config = model.settings.activeLLM, config.isComplete else { return }
        testing = true
        preview = nil
        let persona = model.settings.persona
        let key = model.apiKey(for: config)
        Task {
            let provider = ProviderFactory.make(for: config.wireFormat)
            let system = "Du bist \(persona.displayName). \(persona.instructions)"
            do {
                preview = try await withTimeout(seconds: 90) {
                    try await provider.complete(
                        messages: [Message(role: .user, text: "Sag in zwei Sätzen, wofür du da bist.")],
                        system: system, config: config, apiKey: key,
                        maxTokens: max(2000, min(4000, config.maxOutputTokens)))
                }
            } catch {
                preview = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            testing = false
        }
    }
}
