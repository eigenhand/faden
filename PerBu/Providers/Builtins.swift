import Foundation

/// Was die App an Anbietern mitbringt — Adressen, keine Schlüssel.
///
/// Der Unterschied zu dem, was hier bis eben stand, ist der ganze Punkt. Ein
/// *mitgelieferter Anbieter* trug einen Schlüssel im Binary und richtete sich beim
/// ersten Start selbst ein; wer die App hatte, hatte den Schlüssel. Eine *Vorlage*
/// trägt nur, was ohnehin öffentlich ist: die Adresse, den Pfad und das Format, das
/// dort gesprochen wird. Den Schlüssel bringt der Nutzer mit, und er landet im
/// Schlüsselbund des Geräts.
///
/// Warum es das überhaupt braucht: „https://api.groq.com/openai" tippt niemand
/// richtig aus dem Gedächtnis, und wer sich beim Pfad vertut, bekommt einen 404 und
/// hält den Schlüssel für falsch. Für die Suche gibt es diese Liste seit jeher
/// (`BuiltinRecipes`); dass die Modellseite sie nicht hatte, war eine Lücke und
/// keine Entscheidung.
///
/// Jede Adresse ist angeklopft worden, bevor sie hier steht: ein POST ohne Schlüssel
/// muss mit 401 oder 400 antworten. Das beweist nicht, dass der Anbieter gut ist —
/// nur dass Adresse und Pfad existieren, und genau das ist der Fehler, den eine
/// Vorlage verhindern soll.
struct ModelProvider: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let baseURL: String
    let path: String
    let wireFormat: LLMWireFormat
    /// Ein Satz über den Anbieter, dort wo er die Wahl erleichtert. Leer, wo es
    /// nichts zu sagen gibt — eine Zeile Füllung unter jedem Eintrag macht die Liste
    /// länger und nicht klarer.
    let note: String

    init(_ name: String, _ baseURL: String, path: String = "/v1/chat/completions",
         format: LLMWireFormat = .openai, note: String = "") {
        self.name = name
        self.baseURL = baseURL
        self.path = path
        self.wireFormat = format
        self.note = note
    }

    /// Eine frische Konfiguration aus dieser Vorlage. Ohne Modell und ohne Schlüssel —
    /// beides kommt aus dem nächsten Schritt.
    func config() -> LLMConfig {
        var c = LLMConfig()
        c.name = name
        c.baseURL = baseURL
        c.path = path
        c.wireFormat = wireFormat
        return c
    }
}

/// Das gemeinsame Vorlagen-Verzeichnis für beide Seiten der App.
///
/// Eine Stelle und nicht zwei: Anbieter für Modelle und Anbieter für die Suche sind
/// dasselbe Versprechen an den Nutzer — „die Adresse kennen wir schon, den Schlüssel
/// bringst du mit" —, und wer eine der beiden Listen pflegt, soll die andere daneben
/// sehen.
enum Builtins {

    static var models: [ModelProvider] {
        [
            ModelProvider("OpenAI", "https://api.openai.com"),
            ModelProvider("Anthropic", "https://api.anthropic.com",
                          path: "/v1/messages", format: .anthropic,
                          note: "Eigenes Format. Erweitertes Denken und Prompt-Caching "
                              + "gibt es nur hier."),
            ModelProvider("OpenRouter", "https://openrouter.ai/api",
                          note: "Viele Anbieter unter einer Adresse und einem Schlüssel."),
            ModelProvider("Groq", "https://api.groq.com/openai",
                          note: "Schnell. Der Pfad hat das „/openai“ mittendrin — "
                              + "eine der Adressen, die man nicht errät."),
            ModelProvider("Cerebras", "https://api.cerebras.ai"),
            ModelProvider("Mistral", "https://api.mistral.ai"),
            ModelProvider("DeepSeek", "https://api.deepseek.com"),
            ModelProvider("xAI", "https://api.x.ai"),
            ModelProvider("Together", "https://api.together.xyz"),
            ModelProvider("Fireworks", "https://api.fireworks.ai/inference"),
            ModelProvider("TensorX", "https://api.tensorx.ai"),
            ModelProvider("Eigener Endpoint", "",
                          note: "Alles selbst eintragen — für alles, was OpenAI- oder "
                              + "Anthropic-Format spricht."),
        ]
    }

    /// Die Suchseite. Liegt weiterhin in `BuiltinRecipes`, weil ein Suchrezept mehr
    /// beschreibt als eine Adresse — Parameter, Auth-Form, wo die Treffer im JSON
    /// stehen. Hier steht der Verweis, damit das Verzeichnis vollständig ist.
    static var search: [SearchRecipe] { BuiltinRecipes.all }
}
