import Foundation

/// Turns text into vectors through an OpenAI-compatible `/v1/embeddings` endpoint.
///
/// cognee keeps embeddings in a dedicated vector database; on a phone the vectors
/// live next to the nodes and similarity is computed directly. For a personal
/// memory that is not a compromise — cognee's own default retrieval path is a
/// brute-force scan, and a few thousand vectors are scanned in milliseconds.
struct Embedder {
    let config: MemoryConfig
    let apiKey: String

    /// How long to wait after being rate-limited, and how often to keep trying.
    /// Embedding models are commonly metered per minute, so a minute is the unit
    /// that actually clears the limit — shorter retries just burn the quota again.
    static let retryDelay: UInt64 = 60
    static let maxAttempts = 5

    /// True for failures that are worth waiting out rather than giving up on.
    static func isTransient(_ error: Error) -> Bool {
        if let e = error as? MemoryError, case .embedding(let message) = e {
            let m = message.lowercased()
            if m.contains("http 429") || m.contains("http 503") || m.contains("http 502")
                || m.contains("http 504") || m.contains("rate") || m.contains("limit")
                || m.contains("quota") || m.contains("capacity") || m.contains("overload")
                || m.contains("temporarily") { return true }
        }
        // Connection drops and timeouts are the same kind of "try again later".
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return true }
        return false
    }

    /// Batched: one request for many texts, because ingestion embeds a whole
    /// extraction at once and per-item requests would dominate the runtime.
    ///
    /// Retries on its own when the endpoint is metered: rate limits are the normal
    /// case for embedding models, not an exception, and losing an extraction to one
    /// would mean paying for the model call again to rediscover the same facts.
    func embed(_ texts: [String], onWait: (@Sendable (Int) -> Void)? = nil) async throws -> [[Float]] {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await embedOnce(texts)
            } catch {
                guard Self.isTransient(error), attempt < Self.maxAttempts else { throw error }
                onWait?(attempt)
                try await Task.sleep(nanoseconds: Self.retryDelay * 1_000_000_000)
            }
        }
    }

    private func embedOnce(_ texts: [String]) async throws -> [[Float]] {
        guard let url = config.embeddingURL, !config.embeddingModel.isEmpty else {
            throw MemoryError.notConfigured("Der Einbettungs-Endpoint")
        }
        guard !texts.isEmpty else { return [] }

        var vectors: [[Float]] = []
        // Keep requests to a size every endpoint accepts.
        for chunk in texts.chunked(into: 32) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 120
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": config.embeddingModel,
                "input": chunk,
            ])

            let (data, response) = try await Net.session.data(for: req)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            guard (200...299).contains(status) else {
                var message = "HTTP \(status): "
                    + String((String(data: data, encoding: .utf8) ?? "").prefix(160))
                // Some services say exactly how long to wait; that beats guessing.
                if let after = http?.value(forHTTPHeaderField: "Retry-After") {
                    message += " (Retry-After: \(after))"
                }
                throw MemoryError.embedding(message)
            }
            guard let obj = JSONValue.decode(data)?.objectValue,
                  let items = obj["data"]?.arrayValue else {
                throw MemoryError.embedding("Feld `data` fehlt.")
            }
            for item in items {
                guard let raw = item["embedding"]?.arrayValue else { continue }
                // Map rather than compactMap: a value that fails to convert would
                // silently shorten the vector, and a vector of the wrong length
                // scores zero against every other one.
                var vector = [Float]()
                vector.reserveCapacity(raw.count)
                for v in raw {
                    switch v {
                    case .number(let d): vector.append(Float(d))
                    case .bool(let b):   vector.append(b ? 1 : 0)
                    default:
                        throw MemoryError.embedding("Unerwarteter Wert im Vektor.")
                    }
                }
                vectors.append(vector)
            }
        }
        guard vectors.count == texts.count else {
            throw MemoryError.embedding("Es kamen \(vectors.count) Vektoren für \(texts.count) Texte zurück.")
        }
        return vectors
    }

    func embed(_ text: String) async throws -> [Float] {
        guard let first = try await embed([text], onWait: nil).first else {
            throw MemoryError.embedding("Kein Vektor erhalten.")
        }
        return first
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/// Cosine similarity. Vectors are stored unnormalised, so the norms are computed
/// here rather than assumed.
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
    // Differing lengths mean something went wrong upstream. Returning 0 here is
    // what hid exactly that bug once already, so it is worth being loud about in
    // debug builds while staying harmless in release.
    assert(a.count == b.count || a.isEmpty || b.isEmpty, "Vektorlängen \(a.count) vs. \(b.count)")
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Double = 0, na: Double = 0, nb: Double = 0
    for i in 0..<a.count {
        let x = Double(a[i]), y = Double(b[i])
        dot += x * y; na += x * x; nb += y * y
    }
    guard na > 0, nb > 0 else { return 0 }
    return dot / (na.squareRoot() * nb.squareRoot())
}
