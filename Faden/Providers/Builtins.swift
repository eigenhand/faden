import Foundation

/// What the app brings in the way of providers — addresses, not keys.
///
/// The difference from what stood here until just now is the whole point. A *bundled
/// provider* carried a key in the binary and set itself up on first launch; whoever had
/// the app had the key. A *preset* carries only what is public anyway: the address, the
/// path and the format spoken there. The key is brought by the user, and it lands in the
/// device's keychain.
///
/// Why this is needed at all: nobody types “https://api.groq.com/openai” correctly from
/// memory, and whoever gets the path wrong receives a 404 and thinks the key is wrong.
/// For search this list has always existed (`BuiltinRecipes`); that the model side did
/// not have one was a gap and not a decision.
///
/// Every address has been knocked on before it stands here: a POST without a key has to
/// answer with 401 or 400. That does not prove the provider is any good — only that the
/// address and the path exist, and that is exactly the mistake a preset is meant to
/// prevent.
struct ModelProvider: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let baseURL: String
    let path: String
    let wireFormat: LLMWireFormat
    /// A sentence about the provider, where it makes the choice easier. Empty where
    /// there is nothing to say — a line of filler under every entry makes the list
    /// longer and not clearer.
    let note: String

    init(_ name: String, _ baseURL: String, path: String = "/v1/chat/completions",
         format: LLMWireFormat = .openai, note: String = "") {
        self.name = name
        self.baseURL = baseURL
        self.path = path
        self.wireFormat = format
        self.note = note
    }

    /// A fresh configuration from this preset. Without a model and without a key —
    /// both come from the next step.
    func config() -> LLMConfig {
        var c = LLMConfig()
        c.name = name
        c.baseURL = baseURL
        c.path = path
        c.wireFormat = wireFormat
        return c
    }
}

/// The shared preset directory for both sides of the app.
///
/// One place and not two: providers for models and providers for search are the same
/// promise to the user — “we already know the address, you bring the key” — and whoever
/// maintains one of the two lists should see the other beside it.
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

    /// The search side. Still lives in `BuiltinRecipes`, because a search recipe
    /// describes more than an address — parameters, the auth style, where the results sit
    /// in the JSON. The reference stands here so the directory is complete.
    static var search: [SearchRecipe] { BuiltinRecipes.all }
}
