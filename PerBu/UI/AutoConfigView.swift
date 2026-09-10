import SwiftUI

/// Walks the user through teaching PerBu an unknown search endpoint.
///
/// Step one asks which model should do the reading. Step two probes the endpoint
/// until it answers 200, hands the shape of that answer to the chosen model, and
/// validates the parser it writes before saving it.
struct AutoConfigView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let pending: AppModel.PendingAutoConfig

    @State private var chosenModelID: UUID?
    @State private var steps: [String] = []
    @State private var running = false
    @State private var finished: SearchRecipe?
    @State private var failure: String?
    @State private var probeQuery = "Berlin"

    private var chosenModel: LLMConfig? {
        model.settings.llms.first { $0.id == chosenModelID } ?? model.settings.activeLLM
    }

    var body: some View {
        NavigationStack {
            ZStack {
                EH.scene
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {

                        HairlineCard(padding: 14, fill: EH.surfaceSunk) {
                            VStack(alignment: .leading, spacing: 6) {
                                EH.label("Endpoint")
                                Text(pending.recipe.url.isEmpty ? "— keine URL eingetragen —" : pending.recipe.url)
                                    .font(EH.mono)
                                    .foregroundStyle(EH.navy)
                                    .lineLimit(3)
                            }
                        }

                        if finished == nil && !running {
                            VStack(alignment: .leading, spacing: 12) {
                                EH.label("Welches Modell soll das übernehmen?")
                                if model.settings.llms.isEmpty {
                                    Text("Dafür wird ein eingerichtetes Modell gebraucht. Trage zuerst unter Einstellungen › Modell einen Endpoint ein.")
                                        .font(EH.bodySmall).foregroundStyle(EH.slate)
                                } else {
                                    ForEach(model.settings.llms) { llm in
                                        Button {
                                            chosenModelID = llm.id
                                        } label: {
                                            HairlineCard(padding: 13) {
                                                HStack(spacing: 10) {
                                                    Circle()
                                                        .fill((chosenModelID ?? model.settings.activeLLM?.id) == llm.id
                                                              ? EH.navy : EH.hairStrong)
                                                        .frame(width: 7, height: 7)
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(llm.name).font(EH.body).foregroundStyle(EH.navy)
                                                        Text(llm.model).font(.eh(12, .caption))
                                                            .foregroundStyle(EH.muted).lineLimit(1)
                                                    }
                                                    Spacer(minLength: 0)
                                                }
                                            }
                                        }
                                        .buttonStyle(EHTap())
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                EH.label("Testanfrage")
                                TextField("Suchbegriff zum Ausprobieren", text: $probeQuery)
                                    .font(EH.body).foregroundStyle(EH.navy)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                        .fill(EH.surface))
                                    .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                        .stroke(EH.hair, lineWidth: EH.hairWidth))
                                Text("Mit dieser Anfrage klopft PerBu den Endpoint ab, bis eine gültige Antwort zurückkommt.")
                                    .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                            }

                            Button("Loslegen") { start() }
                                .buttonStyle(EHButtonStyle(prominent: true))
                                .disabled(model.settings.llms.isEmpty)
                        }

                        if !steps.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                EH.label("Ablauf")
                                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                                    HStack(alignment: .top, spacing: 8) {
                                        Circle().fill(EH.hair).frame(width: 4, height: 4)
                                            .padding(.top, 6)
                                        Text(step)
                                            .font(.eh(12.5, .caption))
                                            .foregroundStyle(EH.slate)
                                    }
                                }
                                if running {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.mini).tint(EH.muted)
                                        Text("läuft …").font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                    }
                                    .padding(.top, 2)
                                }
                            }
                        }

                        if let recipe = finished {
                            HairlineCard(padding: 14) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 7) {
                                        Image(systemName: "checkmark.circle")
                                            .font(.eh(13, .footnote)).foregroundStyle(EH.good)
                                        Text("Parser steht").font(EH.body).foregroundStyle(EH.navy)
                                    }
                                    detailRow("Treffer unter", recipe.resultsPath)
                                    detailRow("Titel", recipe.titleKey)
                                    detailRow("URL", recipe.urlKey)
                                    detailRow("Auszug", recipe.snippetKey)
                                    detailRow("Anfrage", "\(recipe.method.rawValue) · \(recipe.authStyle.describe)")
                                    Text("Der Parser ist reine Konfiguration und läuft ab jetzt lokal auf diesem iPhone — für Suchen wird kein Modell mehr gebraucht.")
                                        .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                        .padding(.top, 2)
                                }
                            }

                            Button("Übernehmen") { save(recipe) }
                                .buttonStyle(EHButtonStyle(prominent: true))
                        }

                        if let failure {
                            HairlineCard(padding: 14) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top, spacing: 7) {
                                        Image(systemName: "exclamationmark.circle")
                                            .font(.eh(12, .caption)).foregroundStyle(EH.bad)
                                        Text(failure).font(EH.bodySmall).foregroundStyle(EH.slate)
                                    }
                                    Text("Die Felder lassen sich unter „Details“ im Anbieter auch von Hand eintragen.")
                                        .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                }
                            }
                            Button("Nochmal versuchen") { start() }
                                .buttonStyle(EHButtonStyle())
                        }
                    }
                    .padding(EH.gutter)
                }
            }
            .navigationTitle("Automatisch einrichten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }.foregroundStyle(EH.slate)
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.eh(11, .caption, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(EH.muted)
                .frame(width: 92, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(EH.mono)
                .foregroundStyle(EH.navy)
                .textSelection(.enabled)
        }
    }

    // MARK: Flow

    private func start() {
        guard let llm = chosenModel, llm.isComplete else {
            failure = "Das gewählte Modell ist nicht vollständig eingerichtet."
            return
        }
        steps = []; failure = nil; finished = nil; running = true

        let base = pending.recipe
        let searchKey = Keychain.get(account: base.keychainAccount) ?? ""
        let llmKey = Keychain.get(account: llm.keychainAccount) ?? ""
        let count = model.settings.resultsPerSearch
        let query = probeQuery

        Task {
            let synth = RecipeSynthesizer(config: llm, apiKey: llmKey)

            guard let probed = await RecipeSynthesizer.probe(
                base: base, key: searchKey, probe: query, count: count,
                onStep: { step in append(step) })
            else {
                running = false
                failure = "Keine der ausprobierten Anfragevarianten kam mit HTTP 200 und einer JSON-Antwort zurück. Prüfe URL und Key."
                return
            }

            switch await synth.synthesize(base: probed.recipe, json: probed.json,
                                          onStep: { step in append(step) }) {
            case .success(let recipe):
                finished = recipe
                running = false
            case .failure(let problem):
                failure = problem.message
                running = false
            }
        }
    }

    @MainActor
    private func append(_ step: SynthesisStep) {
        // Probing is chatty; keep only the last attempt line so the list stays readable.
        if case .probing = step, case .some(let last) = steps.last, last.hasPrefix("Probiere") {
            steps[steps.count - 1] = step.text
        } else {
            steps.append(step.text)
        }
    }

    private func save(_ recipe: SearchRecipe) {
        if let i = model.settings.recipes.firstIndex(where: { $0.id == recipe.id }) {
            model.settings.recipes[i] = recipe
        } else {
            model.settings.recipes.append(recipe)
        }
        model.settings.activeRecipeID = recipe.id
        model.persist()
        model.pendingAutoConfig = nil
        dismiss()
    }
}
