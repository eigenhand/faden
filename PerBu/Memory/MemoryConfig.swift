import Foundation

/// Settings for the memory graph. Like everything else, the endpoint is the user's.
struct MemoryConfig: Codable, Equatable {
    var enabled: Bool = false

    /// Woher die Vektoren kommen.
    enum Source: String, Codable, CaseIterable {
        /// Über den Endpoint des Nutzers — die Voreinstellung, und die genauere.
        case endpoint
        /// Auf dem Gerät, mit Apples Modell. Gröber, dafür verlässt kein Satz das
        /// Telefon und es braucht überhaupt keinen Endpoint.
        case onDevice
    }
    var source: Source = .endpoint

    /// Embeddings come from an OpenAI-compatible endpoint.
    var embeddingBaseURL: String = ""
    var embeddingPath: String = "/v1/embeddings"
    var embeddingModel: String = ""
    var embeddingKeychainAccount: String = "perbu.embedding.key"

    /// Write new memories automatically at the end of a conversation turn, rather
    /// than only when asked.
    var automatic: Bool = true
    /// How many triplets are put in front of an answer.
    var topK: Int = 6
    /// Nodes considered by the first vector pass before the graph is walked —
    /// cognee's `wide_search_top_k`.
    var wideSearchTopK: Int = 40
    /// How far the graph is walked out from the seed nodes.
    var neighborhoodDepth: Int = 1
    /// cognee's `triplet_distance_penalty`: how much a triplet loses per hop away
    /// from a seed node, so directly matched facts outrank distant ones.
    var distancePenalty: Double = 6.5
    /// Minimum similarity for a node to count as a seed at all.
    var minimumSimilarity: Double = 0.25

    var embeddingURL: URL? {
        let b = embeddingBaseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !b.isEmpty else { return nil }
        return URL(string: b + embeddingPath)
    }

    /// Der Name, der als Herkunft an jedem Vektor steht.
    ///
    /// Nicht `embeddingModel`: auf dem Gerät gibt es kein Feld, in das jemand einen
    /// Namen tippt, und der Stempel braucht trotzdem einen — sonst ließen sich die
    /// beiden Quellen nicht auseinanderhalten, und genau dafür ist er da.
    var effectiveModel: String {
        switch source {
        case .endpoint: return embeddingModel
        case .onDevice: return LocalEmbedder.modelIdentifier
        }
    }

    var isReady: Bool {
        guard enabled else { return false }
        switch source {
        case .onDevice:
            return LocalEmbedder.isSupported
        case .endpoint:
            return embeddingURL != nil && !embeddingModel.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Ob die Ähnlichkeiten vor dem Vergleich zentriert werden müssen.
    ///
    /// Beim lokalen Modell liegen alle Kosinuswerte über 0,95 — gemessen: Hund zu
    /// „Welches Haustier habe ich?" 0,979, Auto zur selben Frage 0,970. Die
    /// Rangfolge stimmt noch, aber die Mindestähnlichkeit filtert nichts mehr, weil
    /// jeder Wert über jedem Schwellwert liegt. Den Mittelvektor des Bestands
    /// abzuziehen ist das übliche Mittel dagegen und stellt die Bedeutung des
    /// Reglers wieder her. Auf die Trefferquote wirkt es nicht — auch das gemessen.
    var needsCentering: Bool { source == .onDevice }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MemoryConfig()
        enabled                   = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        source                    = try c.decodeIfPresent(Source.self, forKey: .source) ?? d.source
        embeddingBaseURL          = try c.decodeIfPresent(String.self, forKey: .embeddingBaseURL) ?? ""
        embeddingPath             = try c.decodeIfPresent(String.self, forKey: .embeddingPath) ?? d.embeddingPath
        embeddingModel            = try c.decodeIfPresent(String.self, forKey: .embeddingModel) ?? ""
        embeddingKeychainAccount  = try c.decodeIfPresent(String.self, forKey: .embeddingKeychainAccount) ?? d.embeddingKeychainAccount
        automatic                 = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? d.automatic
        topK                      = try c.decodeIfPresent(Int.self, forKey: .topK) ?? d.topK
        wideSearchTopK            = try c.decodeIfPresent(Int.self, forKey: .wideSearchTopK) ?? d.wideSearchTopK
        neighborhoodDepth         = try c.decodeIfPresent(Int.self, forKey: .neighborhoodDepth) ?? d.neighborhoodDepth
        distancePenalty           = try c.decodeIfPresent(Double.self, forKey: .distancePenalty) ?? d.distancePenalty
        minimumSimilarity         = try c.decodeIfPresent(Double.self, forKey: .minimumSimilarity) ?? d.minimumSimilarity
    }
}
