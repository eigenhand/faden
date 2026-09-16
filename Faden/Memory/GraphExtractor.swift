import Foundation

/// Turns text into a knowledge graph, using cognee's extraction prompt.
///
/// The prompt is taken from cognee (`generate_graph_prompt.txt`, Apache-2.0) and
/// translated, because its rules are the substance: consistent basic types rather
/// than `Mathematician`, readable ids rather than integers, coreference resolved to
/// one name, and an edge description phrased as a concrete fact. Those rules are
/// what make separately extracted graphs line up into one.
struct GraphExtractor {
    let config: LLMConfig
    let apiKey: String

    static let systemPrompt = """
    Du bist ein Werkzeug, das aus Text strukturierte Information für einen Wissensgraphen \
    gewinnt.
    **Knoten** sind Entitäten und Begriffe — wie Wikipedia-Artikel.
    **Kanten** sind Beziehungen zwischen ihnen — wie Wikipedia-Verweise.
    Jede Kante bekommt eine Beschreibung, wenn der Text etwas über die Verbindung hergibt. \
    Die Beschreibung nennt die beiden Endpunkte beim Namen, bleibt knapp und sachlich und \
    darf Angaben aus dem Text übernehmen. Füge kein Wissen von außen hinzu.
      - Gut: Christoph arbeitet an Faden, einer Chat-App für das iPhone.
      - Schlecht: Diese Kante beschreibt eine Arbeitsbeziehung.

    Ziel ist ein einfacher, klarer Graph.

    # 1. Knoten benennen
    **Einheitlichkeit**: Nutze grundlegende Typen als Bezeichnung.
      - Eine Person ist immer **"Person"**, nicht "Mathematiker" oder "Entwickler" — das \
    gehört als Eigenschaft in die Beschreibung.
      - Ebenso wenig zu allgemein: nicht "Entität".
    **Knoten-IDs**: Niemals Zahlen als ID.
      - IDs sind Namen oder lesbare Bezeichner, die im Text vorkommen.
    **Namen**: Jeder Knoten braucht ein Feld "name" mit dem vollständigsten lesbaren Namen \
    (etwa "Christoph Lindl-Guk", "Faden").

    # 2. Zahlen und Daten
      - Ein Datum bekommt den Typ **"Datum"**.
      - Format "JJJJ-MM-TT"; ist nur Monat oder Jahr bekannt, dann nur das.
      - Keine Anführungszeichen innerhalb von Werten.
      - Beziehungsnamen in snake_case, etwa `arbeitet_an`.

    # 3. Referenzen auflösen
      - Wird dieselbe Entität im Text unterschiedlich genannt oder durch ein Pronomen \
    ersetzt, nutzt du überall denselben vollständigen Namen. Ohne diese Einheitlichkeit \
    zerfällt der Graph.

    # 4. Nur Fakten
      - Halte dich streng an den Text. Erfinde nichts.

    Antworte ausschließlich mit einem JSON-Objekt:
    {"summary": "…", "description": "…",
     "nodes": [{"id": "…", "name": "…", "type": "…", "description": "…"}],
     "edges": [{"source_node_id": "…", "target_node_id": "…",
                "relationship_name": "…", "description": "…"}]}
    """

    /// The user-facing framing for a personal memory: only what is worth keeping.
    static let personalFraming = """
    Der folgende Ausschnitt stammt aus einem Gespräch zwischen einem Nutzer und seinem \
    Assistenten. Gewinne daraus nur, was über das Gespräch hinaus Bestand hat: Personen, \
    Orte, Vorhaben, Vorlieben, Entscheidungen, Termine, Zugehörigkeiten. Übergehe \
    Höflichkeiten, Rückfragen, und alles, was nur für diesen einen Moment galt. Der Nutzer \
    selbst heißt im Graphen „Nutzer“, sofern sein Name nicht genannt wird.
    """

    func extract(from text: String, framing: String = GraphExtractor.personalFraming) async throws -> ExtractedGraph {
        let provider = ProviderFactory.make(for: config.wireFormat)
        let prompt = "\(framing)\n\nText:\n\"\"\"\n\(text)\n\"\"\""

        let reply = try await withTimeout(seconds: 120) {
            try await provider.complete(
                messages: [Message(role: .user, text: prompt)],
                system: Self.systemPrompt,
                config: config, apiKey: apiKey,
                maxTokens: max(4000, min(8000, config.maxOutputTokens)))
        }

        guard let object = RecipeSynthesizer.extractJSONObject(reply) else {
            throw MemoryError.extraction("Die Antwort war kein JSON-Objekt.")
        }
        let value = JSONValue.object(object)
        guard let data = try? JSONEncoder().encode(value),
              let graph = try? JSONDecoder().decode(ExtractedGraph.self, from: data)
        else {
            throw MemoryError.extraction("Die Struktur passte nicht zum erwarteten Graphen.")
        }
        return graph
    }
}

enum MemoryError: LocalizedError {
    case notConfigured(String)
    case extraction(String)
    case embedding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return "\(what) ist nicht eingerichtet."
        case .extraction(let m):       return "Wissensgraph nicht ableitbar: \(m)"
        case .embedding(let m):        return "Einbettung fehlgeschlagen: \(m)"
        }
    }
}
