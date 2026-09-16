import Foundation
import NaturalLanguage

/// Embeddings on the device, with Apple's `NLContextualEmbedding`.
///
/// The reason is not speed, although it is there: 8 ms per sentence against a good
/// eight seconds for a whole ingestion over the network. The reason is that memories are
/// the most personal text in this app and had to travel down the wire to be embedded —
/// and that a memory without an embedding endpoint did not run at all. Whoever has only
/// a chat model at a small provider got none.
///
/// The price stands in the same measurements. On nine questions against fourteen German
/// memories, the network model (qwen3-embedding-8b, 4096 dimensions) hit first place
/// seven times, this one five; on average the right memory ranks 1.44 there and 4.33
/// here. And the model weighs 108 MB, while the whole app weighs 3.3 MB. Which is why
/// this is a choice and not a default.
actor LocalEmbedder {
    static let shared = LocalEmbedder()

    /// The name that stands on every vector as its origin.
    ///
    /// With a revision, because Apple can swap the model out in a system update: the
    /// same identifier for two different models would be exactly the quiet nonsense the
    /// stamp was built against.
    static var modelIdentifier: String {
        let revision = NLContextualEmbedding(script: .latin)?.revision ?? 0
        return "apple-nlcontextual-v\(revision)"
    }

    /// One model for all Latin scripts, not one per language.
    ///
    /// A personal memory holds German and English sentences side by side. Two language
    /// models would be two vector spaces, and therefore exactly the problem the origin
    /// stamp is meant to prevent. The Latin model covers 20 languages; measured, a
    /// German sentence and its English counterpart sit at 0.95 to each other.
    private static func makeModel() -> NLContextualEmbedding? {
        NLContextualEmbedding(script: .latin)
    }

    private var model: NLContextualEmbedding?

    /// True when this device knows the model at all.
    nonisolated static var isSupported: Bool { makeModel() != nil }

    /// True when the 108 MB already lie on the device.
    nonisolated static var hasAssets: Bool { makeModel()?.hasAvailableAssets ?? false }

    /// Downloads the model files. Returns at once when they are already there.
    ///
    /// With a time limit, because the call otherwise does not come back: in the
    /// simulator it ran for over six minutes with no result, and `mobileassetd` reports
    /// neither progress nor failure. The limit only cuts off the *waiting* — the
    /// download carries on in the system, and whether it arrived is something only
    /// `hasAssets` says. Which is why this is not an error but a piece of information.
    static func requestAssets(timeout: Duration = .seconds(180)) async throws {
        guard let probe = makeModel() else { throw MemoryError.notConfigured("Das lokale Modell") }
        guard !probe.hasAvailableAssets else { return }

        let result: NLContextualEmbedding.AssetsResult? = try await withThrowingTaskGroup(
            of: NLContextualEmbedding.AssetsResult?.self) { group in
            group.addTask {
                // Its own instance rather than the one from outside:
                // NLContextualEmbedding is not Sendable, and handing it across a task
                // boundary would be exactly the data race the compiler warns about. The
                // object is only a handle on the same system model anyway.
                guard let model = makeModel() else { return nil }
                return try await model.requestAssets()
            }
            group.addTask { try await Task.sleep(for: timeout); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let result else {
            throw MemoryError.embedding(
                "Das System hat noch nicht geantwortet. Der Download läuft unter Umständen "
                + "weiter — beim nächsten Öffnen steht hier, ob er angekommen ist.")
        }
        guard result == .available else {
            throw MemoryError.embedding("Das Modell konnte nicht geladen werden (\(result.rawValue)).")
        }
    }

    private func loaded() throws -> NLContextualEmbedding {
        if let model { return model }
        guard let made = Self.makeModel() else {
            throw MemoryError.notConfigured("Das lokale Modell")
        }
        guard made.hasAvailableAssets else {
            throw MemoryError.embedding("Das lokale Modell ist noch nicht geladen.")
        }
        try made.load()
        model = made
        return made
    }

    /// Releases the memory again — measured at 13.5 MB.
    func unload() {
        model?.unload()
        model = nil
    }

    func embed(_ texts: [String]) throws -> [[Float]] {
        let model = try loaded()
        return try texts.map { try vector(for: $0, model: model) }
    }

    /// The vector of the first token, not the mean across all of them.
    ///
    /// Apple names four methods in the header and recommends none. Measured against the
    /// same nine questions: first token 5/9, mean 3/9, maximum 2/9, last token 1/9. So
    /// measured rather than guessed — the mean would have been the obvious choice and
    /// is the worse one.
    private func vector(for text: String, model: NLContextualEmbedding) throws -> [Float] {
        // An empty text has no first token; without this line a zero vector would
        // come out, whose cosine to everything is 0 — a hit that looks like a miss.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoryError.embedding("Leerer Text.") }

        guard let result = try? model.embeddingResult(for: trimmed, language: nil) else {
            throw MemoryError.embedding("Der Text konnte nicht eingebettet werden.")
        }
        var first: [Double] = []
        result.enumerateTokenVectors(in: trimmed.startIndex ..< trimmed.endIndex) { v, _ in
            first = v
            return false
        }
        guard !first.isEmpty else { throw MemoryError.embedding("Keine Tokenvektoren.") }

        let norm = sqrt(first.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { throw MemoryError.embedding("Nullvektor.") }
        return first.map { Float($0 / norm) }
    }
}
