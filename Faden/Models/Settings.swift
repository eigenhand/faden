import Foundation

// MARK: - LLM

enum LLMWireFormat: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    /// Apple's model in the system. No wire, so strictly speaking no wire format —
    /// but the provider choice hangs on this switch, and a second switch beside it
    /// would have made the same states representable twice over.
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
    /// For the segmented control, where three full names truncate all three.
    var shortLabel: String {
        switch self {
        case .anthropic:     return "Anthropic"
        case .openai:        return "OpenAI"
        case .appleOnDevice: return "Apple"
        }
    }

    /// Whether this format needs an address, a path and a key.
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
    /// What to fall back to when the main model does not answer. Empty means: do not
    /// fall back at all.
    ///
    /// From the settings and not from the build. While the app still shipped a
    /// provider, its second model stood here, tied to its address — whoever entered
    /// their own endpoint would otherwise have been handed a model name on a failure
    /// that their provider does not know. That was a second failure instead of a
    /// rescue. What the user enters themselves lives at their own provider.
    var fallbackModel: String = ""
    /// The model for turns that carry an image. Empty means: the main model handles
    /// those too.
    ///
    /// There are models that do everything better except see. `z-ai/glm-5.3` is one —
    /// the same family, the same speed, and to an image it answers “Model only supports
    /// text input”, while `-flash` beside it describes the picture. Without this line
    /// you would have to choose: either the better model or images. With it, the one
    /// turn that carries an image goes to the model that can look, and all the others
    /// stay where they are.
    var visionModel: String = ""
    /// What an image turn falls back to. Has to see images itself, or the fallback
    /// would only be a second failure.
    var visionFallbackModel: String = ""
    /// This provider's model list, as it last handed it out.
    ///
    /// Kept rather than fetched anew every time: the four roles are filled from this
    /// list, and a picker that only opens after a network request is no picker on a
    /// train or in a basement. It also carries the capabilities along — which is why
    /// the picker for images can offer the models known to see them, rather than all
    /// of them.
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

    /// Whether the answer length was set by hand.
    ///
    /// If it was not, it grows out of use: when an answer is cut off before any text
    /// arrived, Faden doubles the budget and asks again. A reasoning model on a hard
    /// task needs a multiple of what suffices for a piece of information, and 4096 is
    /// the wrong number for both — you only notice when the reasoning stops
    /// mid-sentence.
    ///
    /// Whoever sets the number themselves wanted it that way. From then on nothing
    /// grows any more.
    var maxOutputTokensIsCustom: Bool = false
    var temperature: Double = 1.0
    /// Extra headers, e.g. `HTTP-Referer` for OpenRouter.
    var extraHeaders: [String: String] = [:]
    /// Whether this model accepts images. Off by default: there is no reliable way
    /// to ask an arbitrary endpoint, and sending an image to a text-only model is a
    /// hard error rather than a graceful degradation.
    var supportsVision: Bool = false
    /// Whether this model accepts tools. **nil means unchecked.**
    ///
    /// The difference carries weight here: `false` switches the tools off in every
    /// turn, `nil` leaves the previous behaviour in place — the app sends them along as
    /// it always has. An endpoint that does not know the parameter refuses the request
    /// with HTTP 400; that is the measurement that lands here.
    var supportsTools: Bool?
    /// Whether the model sends its reasoning along. **nil means unchecked.**
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
        // A settings file from before this feature does not know whether anyone
        // touched the number. If the default still stands there, nobody did — and that
        // is exactly the case the growing helps.
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

    /// The models that come into question for images.
    ///
    /// Everything except what is demonstrably blind. Deliberately not “only what
    /// demonstrably sees”: most providers say nothing about images, and a picker that
    /// stays empty because of it helps nobody. What stands there therefore means “comes
    /// into question” and not “has been checked” — checking happens in the connection
    /// test.
    var imageCapableModels: [RemoteModel] {
        knownModels.filter { $0.capabilities.vision != false }
    }

    /// Whether an image may be attached at all.
    ///
    /// Two routes lead there, and the second is the new one: either the main model sees
    /// images, or there is a separate model for them. Without this question in one
    /// place the plus sign would still hang on the main model alone — and whoever had
    /// just entered a vision model would still not see it.
    var acceptsImages: Bool {
        supportsVision || !visionModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Which model handles this turn.
    ///
    /// Static would be wrong here: the answer hangs on this configuration. It is
    /// testable all the same, because it asks nothing but itself.
    func model(forImages: Bool) -> String {
        let vision = visionModel.trimmingCharacters(in: .whitespaces)
        return forImages && !vision.isEmpty ? vision : model
    }

    /// What this turn falls back to, or nil.
    ///
    /// `active` is the model that has just failed — falling back to the same one again
    /// would be no second chance but the same mistake.
    ///
    /// If an image hangs on the turn, the image fallback applies first and the general
    /// one only after. The other way round you would risk sending an image to a model
    /// that cannot see — and the rescue attempt would be the second failure.
    func fallback(forImages: Bool, after active: String) -> String? {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        let candidates = forImages
            ? [clean(visionFallbackModel), clean(fallbackModel)]
            : [clean(fallbackModel)]
        return candidates.first { !$0.isEmpty && $0 != active }
    }

    /// The badges that stand under this model.
    ///
    /// `supportsVision` is the exception here: it is a switch and not a finding — off
    /// stands for “do not offer images”, whether checked or not. Only the yes counts as
    /// a badge, therefore.
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

    /// Whether this model is usable.
    ///
    /// Apple's model needs neither an address nor a model name — it is there or it is
    /// not, and the system decides that. So the question here is only whether the app
    /// *may* address it; whether it is ready right now is what `AppleModel.status`
    /// says.
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
