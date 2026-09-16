import Foundation

// MARK: - LLM

enum LLMWireFormat: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    /// Apples Modell im System. Kein Draht, daher streng genommen kein Wire-Format —
    /// aber die Anbieterwahl haengt an diesem Schalter, und ein zweiter Schalter
    /// daneben haette dieselben Zustaende noch einmal darstellbar gemacht.
    case appleOnDevice
    var id: String { rawValue }
    var label: String {
        switch self {
        case .anthropic:      return "Anthropic Messages"
        case .openai:         return "OpenAI-kompatibel"
        case .appleOnDevice:  return "Apple, auf dem Gerät"
        }
    }
    var hint: String {
        switch self {
        case .anthropic: return "Anthropic API und alles, was /v1/messages spricht."
        case .openai:    return "OpenAI, Groq, Together, OpenRouter, Mistral, Ollama, vLLM, LM Studio …"
        case .appleOnDevice:
            return "Das Modell im System. Ohne Endpoint, ohne Schlüssel, ohne Netz — "
                 + "und ohne Werkzeuge und Bilder."
        }
    }
    /// Fuer den Segmentschalter, wo drei volle Namen alle drei abschneiden.
    var shortLabel: String {
        switch self {
        case .anthropic:     return "Anthropic"
        case .openai:        return "OpenAI"
        case .appleOnDevice: return "Apple"
        }
    }

    /// Ob dieses Format Adresse, Pfad und Schlüssel braucht.
    var needsEndpoint: Bool { self != .appleOnDevice }
}

/// Everything the app needs to talk to a model. No defaults are shipped: the endpoint,
/// the key and the model id all come from the user.
struct LLMConfig: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Mein Modell"
    var wireFormat: LLMWireFormat = .anthropic
    /// Base URL without the path, e.g. https://api.anthropic.com
    var baseURL: String = ""
    /// Path appended to the base URL. Pre-filled per wire format, editable.
    var path: String = "/v1/messages"
    var model: String = ""
    /// Worauf ausgewichen wird, wenn das Hauptmodell nicht antwortet. Leer heisst:
    /// gar nicht ausweichen.
    ///
    /// Aus den Einstellungen und nicht aus dem Build. Solange die App einen Anbieter
    /// mitbrachte, stand hier dessen zweites Modell, gebunden an dessen Adresse —
    /// wer seinen eigenen Endpoint eintrug, hätte sonst bei einem Fehlschlag einen
    /// Modellnamen vorgesetzt bekommen, den sein Anbieter nicht kennt. Das war ein
    /// zweiter Fehlschlag statt einer Rettung. Was der Nutzer selbst einträgt, liegt
    /// bei seinem Anbieter.
    var fallbackModel: String = ""
    /// Das Modell für Züge, an denen ein Bild hängt. Leer heisst: das Hauptmodell
    /// macht das mit.
    ///
    /// Es gibt Modelle, die alles besser können ausser sehen. `z-ai/glm-5.3` ist so
    /// eines — dieselbe Familie, dieselbe Geschwindigkeit, und auf ein Bild antwortet
    /// es „Model only supports text input", während `-flash` daneben das Bild
    /// beschreibt. Ohne diese Zeile müsste man sich entscheiden: entweder das bessere
    /// Modell oder Bilder. Mit ihr wandert der eine Zug, an dem ein Bild hängt, zu
    /// dem Modell, das hinsehen kann, und alle anderen bleiben, wo sie sind.
    var visionModel: String = ""
    /// Worauf ein Bild-Zug ausweicht. Muss selbst Bilder sehen, sonst wäre das
    /// Ausweichen nur ein zweiter Fehlschlag.
    var visionFallbackModel: String = ""
    /// Die Modellliste dieses Anbieters, so wie er sie zuletzt herausgegeben hat.
    ///
    /// Aufbewahrt und nicht jedes Mal neu geholt: aus dieser Liste werden die vier
    /// Rollen besetzt, und eine Auswahl, die erst nach einer Netzanfrage aufgeht,
    /// ist im Zug oder im Keller keine. Sie trägt ausserdem die Fähigkeiten mit sich
    /// — deshalb kann die Auswahl für Bilder die Modelle anbieten, von denen bekannt
    /// ist, dass sie welche sehen, statt alle.
    var knownModels: [RemoteModel] = []
    /// Nominal context window in tokens. Drives the bar and the compaction trigger.
    var contextWindow: Int = 200_000
    /// Largest prompt this endpoint has actually accepted. Some providers publish no
    /// limits at all, so the app remembers what demonstrably worked and uses it as a
    /// floor when suggesting a window.
    var observedMaxPromptTokens: Int = 0
    /// Ceiling the endpoint itself reported, when it did.
    var reportedContextLimit: Int?
    var reportedOutputLimit: Int?
    var maxOutputTokens: Int = 4096

    /// Ob die Antwortlänge von Hand gesetzt wurde.
    ///
    /// Ist sie das nicht, wächst sie aus der Nutzung: Wird eine Antwort
    /// abgeschnitten, bevor Text kam, verdoppelt Faden den Vorrat und fragt noch
    /// einmal. Ein Denkmodell an einer schweren Aufgabe braucht ein Vielfaches
    /// dessen, was für eine Auskunft reicht, und 4096 ist für beides die falsche
    /// Zahl — nur merkt man es erst, wenn der Gedankengang mitten im Satz aufhört.
    ///
    /// Wer die Zahl selbst einstellt, wollte sie so. Ab dann wächst nichts mehr.
    var maxOutputTokensIsCustom: Bool = false
    var temperature: Double = 1.0
    /// Extra headers, e.g. `HTTP-Referer` for OpenRouter.
    var extraHeaders: [String: String] = [:]
    /// Whether this model accepts images. Off by default: there is no reliable way
    /// to ask an arbitrary endpoint, and sending an image to a text-only model is a
    /// hard error rather than a graceful degradation.
    var supportsVision: Bool = false
    /// Ob dieses Modell Werkzeuge annimmt. **nil heisst ungeprüft.**
    ///
    /// Der Unterschied trägt hier Gewicht: `false` schaltet die Werkzeuge in jedem
    /// Zug ab, `nil` lässt es beim bisherigen Verhalten — die App schickt sie mit,
    /// wie sie es immer getan hat. Ein Endpoint, der den Parameter nicht kennt,
    /// weist die Anfrage mit HTTP 400 ab; das ist die Messung, die hier landet.
    var supportsTools: Bool?
    /// Ob das Modell seinen Gedankengang mitschickt. **nil heisst ungeprüft.**
    var supportsReasoning: Bool?
    /// Anthropic only: ask for adaptive thinking and stream a summary of it.
    var requestThinking: Bool = false
    /// Anthropic only: mark the system prompt cacheable. Harmless on the first-party
    /// API, but some compatible endpoints reject the field.
    var useCacheControl: Bool = true
    /// Keychain reference; the key itself never lives in UserDefaults.
    var keychainAccount: String = UUID().uuidString

    /// Decoded field by field so that adding a property does not invalidate every
    /// stored settings file. Swift's synthesised decoder ignores default values and
    /// throws on a missing key, which silently reset the user's whole configuration.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMConfig()
        id                    = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name                  = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        wireFormat            = try c.decodeIfPresent(LLMWireFormat.self, forKey: .wireFormat) ?? d.wireFormat
        baseURL               = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        path                  = try c.decodeIfPresent(String.self, forKey: .path) ?? d.path
        model                 = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        fallbackModel         = try c.decodeIfPresent(String.self, forKey: .fallbackModel) ?? d.fallbackModel
        visionModel           = try c.decodeIfPresent(String.self, forKey: .visionModel) ?? d.visionModel
        visionFallbackModel   = try c.decodeIfPresent(String.self, forKey: .visionFallbackModel) ?? d.visionFallbackModel
        knownModels           = try c.decodeIfPresent([RemoteModel].self, forKey: .knownModels) ?? []
        contextWindow         = try c.decodeIfPresent(Int.self, forKey: .contextWindow) ?? d.contextWindow
        observedMaxPromptTokens = try c.decodeIfPresent(Int.self, forKey: .observedMaxPromptTokens) ?? 0
        reportedContextLimit  = try c.decodeIfPresent(Int.self, forKey: .reportedContextLimit)
        reportedOutputLimit   = try c.decodeIfPresent(Int.self, forKey: .reportedOutputLimit)
        maxOutputTokens       = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? d.maxOutputTokens
        // Eine Einstellung von vor dieser Funktion weiß nicht, ob jemand die Zahl
        // angefasst hat. Steht dort noch die Vorgabe, hat es niemand getan — und
        // genau der Fall ist der, dem das Wachsen hilft.
        maxOutputTokensIsCustom = try c.decodeIfPresent(Bool.self, forKey: .maxOutputTokensIsCustom)
            ?? (maxOutputTokens != d.maxOutputTokens)
        temperature           = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        extraHeaders          = try c.decodeIfPresent([String: String].self, forKey: .extraHeaders) ?? [:]
        supportsVision        = try c.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false
        supportsTools         = try c.decodeIfPresent(Bool.self, forKey: .supportsTools)
        supportsReasoning     = try c.decodeIfPresent(Bool.self, forKey: .supportsReasoning)
        requestThinking       = try c.decodeIfPresent(Bool.self, forKey: .requestThinking) ?? false
        useCacheControl       = try c.decodeIfPresent(Bool.self, forKey: .useCacheControl) ?? true
        keychainAccount       = try c.decodeIfPresent(String.self, forKey: .keychainAccount) ?? d.keychainAccount
    }

    init() {}

    /// Die Modelle, die für Bilder in Frage kommen.
    ///
    /// Alles ausser dem, was nachweislich blind ist. Bewusst nicht „nur was
    /// nachweislich sieht": die meisten Anbieter schweigen zu Bildern, und eine
    /// Auswahl, die deshalb leer bleibt, hilft niemandem. Was dasteht, ist also
    /// „kommt in Frage" und nicht „ist geprüft" — geprüft wird beim Verbindungstest.
    var imageCapableModels: [RemoteModel] {
        knownModels.filter { $0.capabilities.vision != false }
    }

    /// Ob überhaupt ein Bild angehängt werden darf.
    ///
    /// Zwei Wege führen dahin, und der zweite ist der neue: entweder das Hauptmodell
    /// sieht Bilder, oder es gibt ein eigenes Modell dafür. Ohne diese Frage an einer
    /// Stelle hinge das Pluszeichen weiter allein am Hauptmodell — und wer gerade ein
    /// Vision-Modell eingetragen hat, sähe es trotzdem nicht.
    var acceptsImages: Bool {
        supportsVision || !visionModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Welches Modell diesen Zug bearbeitet.
    ///
    /// Statisch wäre hier falsch: die Antwort hängt an dieser Konfiguration. Prüfbar
    /// ist sie trotzdem, denn sie fragt nichts ausser sich selbst.
    func model(forImages: Bool) -> String {
        let vision = visionModel.trimmingCharacters(in: .whitespaces)
        return forImages && !vision.isEmpty ? vision : model
    }

    /// Worauf dieser Zug ausweicht, oder nil.
    ///
    /// `active` ist das Modell, das gerade gescheitert ist — auf dasselbe noch einmal
    /// auszuweichen wäre keine zweite Chance, sondern derselbe Fehler.
    ///
    /// Hängt ein Bild am Zug, gilt zuerst das Bild-Ausweichmodell und erst dann das
    /// allgemeine. Andersherum liefe man Gefahr, ein Bild an ein Modell zu schicken,
    /// das nicht sehen kann — und der Rettungsversuch wäre der zweite Fehlschlag.
    func fallback(forImages: Bool, after active: String) -> String? {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        let candidates = forImages
            ? [clean(visionFallbackModel), clean(fallbackModel)]
            : [clean(fallbackModel)]
        return candidates.first { !$0.isEmpty && $0 != active }
    }

    /// Die Marken, die unter diesem Modell stehen.
    ///
    /// `supportsVision` ist hier die Ausnahme: es ist ein Schalter und keine
    /// Feststellung — aus steht für „biete keine Bilder an", gleich ob geprüft oder
    /// nicht. Als Marke zählt deshalb nur das Ja.
    var capabilities: Capabilities {
        Capabilities(vision: supportsVision ? true : nil,
                     tools: supportsTools,
                     reasoning: supportsReasoning)
    }

    var endpointURL: URL? {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return nil }
        return URL(string: base + path)
    }

    /// Ob dieses Modell benutzbar ist.
    ///
    /// Apples Modell braucht weder Adresse noch Modellnamen — es ist da oder nicht,
    /// und das entscheidet das System. Deshalb hier nur die Frage, ob die App es
    /// ansprechen *darf*; ob es gerade bereit ist, sagt `AppleModel.status`.
    var isComplete: Bool {
        if wireFormat == .appleOnDevice { return true }
        return endpointURL != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func defaultPath(for format: LLMWireFormat) -> String {
        switch format {
        case .anthropic:     return "/v1/messages"
        case .openai:        return "/v1/chat/completions"
        case .appleOnDevice: return ""
        }
    }
}

// MARK: - Search

enum HTTPMethodKind: String, Codable, CaseIterable, Identifiable {
    case get = "GET", post = "POST"
    var id: String { rawValue }
}

enum AuthStyle: Codable, Equatable, Hashable {
    /// e.g. header "X-Subscription-Token" with template "{{key}}", or "Authorization" with "Bearer {{key}}"
    case header(name: String, valueTemplate: String)
    case queryParam(name: String)
    case none

    var describe: String {
        switch self {
        case .header(let n, let v): return "Header \(n): \(v)"
        case .queryParam(let n):    return "Query ?\(n)="
        case .none:                 return "ohne"
        }
    }
}

/// A declarative description of *how to call a search API and how to read its answer*.
///
/// This is the artefact the auto-configuration produces. It is plain data, so it is
/// synthesised once by a model, stored on the phone, and from then on executed entirely
/// locally by `RecipeEngine` — no model call is involved in a normal search.
struct SearchRecipe: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Eigener Anbieter"

    // ---- Request shape
    var method: HTTPMethodKind = .get
    /// Full URL, may contain `{{query}}`.
    var url: String = ""
    /// For GET: the parameter carrying the query, e.g. `q`.
    var queryParamName: String? = "q"
    /// Static query items, e.g. `count=5`, `search_lang=de`.
    var staticQueryItems: [String: String] = [:]
    var authStyle: AuthStyle = .none
    var headers: [String: String] = ["Accept": "application/json"]
    /// For POST: a JSON body template with `{{query}}`, `{{key}}`, `{{count}}` placeholders.
    var bodyTemplate: String?

    // ---- Response shape
    /// Dotted path to the array of results, e.g. `web.results`, `data`, `organic`.
    var resultsPath: String = ""
    /// Dotted paths *inside* one result item.
    var titleKey: String = "title"
    var urlKey: String = "url"
    var snippetKey: String = "description"
    var dateKey: String?
    /// Optional path to a provider-written answer/summary shown before the results.
    var answerPath: String?
    /// Path *inside a result* to an array of further text fragments. Providers often
    /// return a short teaser plus several longer passages; using only the teaser
    /// throws away most of what was retrieved.
    var extraTextKey: String?
    /// Path inside a result to the name of the source, e.g. `profile.name`.
    var sourceKey: String?
    /// Further result lists in the same response, e.g. `news.results`. For current
    /// events these often matter more than the plain web results.
    var additionalResultPaths: [String] = []

    // ---- Provenance
    var isBuiltIn: Bool = false
    /// Set when a model synthesised this recipe, for display in settings.
    var synthesizedBy: String?
    var synthesizedAt: Date?

    var keychainAccount: String = UUID().uuidString

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SearchRecipe()
        id               = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name             = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        method           = try c.decodeIfPresent(HTTPMethodKind.self, forKey: .method) ?? d.method
        url              = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
        queryParamName   = try c.decodeIfPresent(String.self, forKey: .queryParamName)
        staticQueryItems = try c.decodeIfPresent([String: String].self, forKey: .staticQueryItems) ?? [:]
        authStyle        = try c.decodeIfPresent(AuthStyle.self, forKey: .authStyle) ?? .none
        headers          = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? d.headers
        bodyTemplate     = try c.decodeIfPresent(String.self, forKey: .bodyTemplate)
        resultsPath      = try c.decodeIfPresent(String.self, forKey: .resultsPath) ?? ""
        titleKey         = try c.decodeIfPresent(String.self, forKey: .titleKey) ?? d.titleKey
        urlKey           = try c.decodeIfPresent(String.self, forKey: .urlKey) ?? d.urlKey
        snippetKey       = try c.decodeIfPresent(String.self, forKey: .snippetKey) ?? d.snippetKey
        dateKey          = try c.decodeIfPresent(String.self, forKey: .dateKey)
        answerPath       = try c.decodeIfPresent(String.self, forKey: .answerPath)
        extraTextKey     = try c.decodeIfPresent(String.self, forKey: .extraTextKey)
        sourceKey        = try c.decodeIfPresent(String.self, forKey: .sourceKey)
        additionalResultPaths = try c.decodeIfPresent([String].self, forKey: .additionalResultPaths) ?? []
        isBuiltIn        = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        synthesizedBy    = try c.decodeIfPresent(String.self, forKey: .synthesizedBy)
        synthesizedAt    = try c.decodeIfPresent(Date.self, forKey: .synthesizedAt)
        keychainAccount  = try c.decodeIfPresent(String.self, forKey: .keychainAccount) ?? d.keychainAccount
    }
}

// MARK: - Persisted app settings

struct AppSettings: Codable, Equatable {
    var llms: [LLMConfig] = []
    var activeLLMID: UUID?

    var recipes: [SearchRecipe] = []
    var activeRecipeID: UUID?

    var persona = Persona()
    var speech = SpeechConfig()
    var memory = MemoryConfig()
    var searchEnabled: Bool = true
    var resultsPerSearch: Int = 5
    /// Fraction of the context window at which a background compaction fires.
    var compactionThreshold: Double = 0.75
    var autoCompactEnabled: Bool = true
    var showThinking: Bool = true
    var language: AppLanguage = .system
    var appearance: AppAppearance = .system

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        llms                = try c.decodeIfPresent([LLMConfig].self, forKey: .llms) ?? []
        activeLLMID         = try c.decodeIfPresent(UUID.self, forKey: .activeLLMID)
        recipes             = try c.decodeIfPresent([SearchRecipe].self, forKey: .recipes) ?? []
        persona             = try c.decodeIfPresent(Persona.self, forKey: .persona) ?? Persona()
        speech              = try c.decodeIfPresent(SpeechConfig.self, forKey: .speech) ?? SpeechConfig()
        memory              = try c.decodeIfPresent(MemoryConfig.self, forKey: .memory) ?? MemoryConfig()
        activeRecipeID      = try c.decodeIfPresent(UUID.self, forKey: .activeRecipeID)
        searchEnabled       = try c.decodeIfPresent(Bool.self, forKey: .searchEnabled) ?? d.searchEnabled
        resultsPerSearch    = try c.decodeIfPresent(Int.self, forKey: .resultsPerSearch) ?? d.resultsPerSearch
        compactionThreshold = try c.decodeIfPresent(Double.self, forKey: .compactionThreshold) ?? d.compactionThreshold
        autoCompactEnabled  = try c.decodeIfPresent(Bool.self, forKey: .autoCompactEnabled) ?? d.autoCompactEnabled
        showThinking        = try c.decodeIfPresent(Bool.self, forKey: .showThinking) ?? d.showThinking
        language            = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? d.language
        appearance          = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? d.appearance
    }

    var activeLLM: LLMConfig? {
        guard let id = activeLLMID else { return llms.first }
        return llms.first { $0.id == id } ?? llms.first
    }
    var activeRecipe: SearchRecipe? {
        guard let id = activeRecipeID else { return recipes.first }
        return recipes.first { $0.id == id } ?? recipes.first
    }
}
