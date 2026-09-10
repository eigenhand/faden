import Foundation

/// Settings for the memory graph. Like everything else, the endpoint is the user's.
struct MemoryConfig: Codable, Equatable {
    var enabled: Bool = false

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

    var isReady: Bool {
        enabled && embeddingURL != nil && !embeddingModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MemoryConfig()
        enabled                   = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
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
