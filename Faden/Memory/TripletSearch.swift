import Foundation

/// cognee's retrieval, ported: `brute_force_triplet_search` followed by a
/// neighbourhood projection and triplet ranking.
///
/// The shape of it matters more than any single number. A pure vector search over
/// facts returns the facts that sound like the question. Searching *and then walking
/// the graph* also returns what those facts are attached to — which is how "wo
/// arbeitet Christoph" can be answered from a node about Christoph plus an edge to
/// his project, neither of which alone matches the question well.
struct TripletSearch {

    let config: MemoryConfig

    struct Seed {
        let id: UUID
        let similarity: Double
    }

    struct Scored {
        /// Seeds — the best matches, used as entry points into the graph.
        var nodeSeeds: [Seed]
        var edgeSeeds: [Seed]
        /// Similarity of *every* node and edge, kept for ranking whole triplets.
        var nodeSimilarity: [UUID: Double]
        var edgeSimilarity: [UUID: Double]
    }

    /// Stage one, cognee's vector pass: score every node *and* every edge against
    /// the question. Edges are searched too because "Christoph arbeitet an Faden"
    /// is a sentence a question can match, while the bare endpoint names are not.
    ///
    /// All scores are kept, not just the top ones: ranking a triplet needs the
    /// similarity of both its endpoints, and an endpoint that missed the seed cut
    /// is exactly what distinguishes two facts hanging off the same person.
    /// Subtracts the mean vector and renormalises.
    ///
    /// Only needed for the vectors from the device. With BERT-like models every sentence
    /// points in the same direction — measured, all cosines lay above 0.95, and the gap
    /// between a fitting and an unfitting memory was nine thousandths. The ranking
    /// survives that, the minimum similarity does not: every value lies above every
    /// threshold, so the slider filters nothing. Subtracting what they all have in
    /// common leaves what distinguishes them, and gives the slider its meaning back.
    private static func centred(_ v: [Float], _ centroid: [Float]?) -> [Float] {
        guard let centroid, centroid.count == v.count else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var norm: Float = 0
        for i in 0 ..< v.count {
            let d = v[i] - centroid[i]
            out[i] = d
            norm += d * d
        }
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        for i in 0 ..< out.count { out[i] /= norm }
        return out
    }

    static func seeds(for queryVector: [Float],
                      nodes: [MemoryNode],
                      edges: [MemoryEdge],
                      limit: Int,
                      minimum: Double,
                      centroid: [Float]? = nil) -> Scored {
        let query = centred(queryVector, centroid)
        var nodeSimilarity: [UUID: Double] = [:]
        var nodeScores: [Seed] = []
        for n in nodes {
            guard let v = n.embedding else { continue }
            let s = cosineSimilarity(query, centred(v, centroid))
            nodeSimilarity[n.id] = s
            if s >= minimum { nodeScores.append(Seed(id: n.id, similarity: s)) }
        }
        var edgeSimilarity: [UUID: Double] = [:]
        var edgeScores: [Seed] = []
        for e in edges {
            guard let v = e.embedding else { continue }
            let s = cosineSimilarity(query, centred(v, centroid))
            edgeSimilarity[e.id] = s
            if s >= minimum { edgeScores.append(Seed(id: e.id, similarity: s)) }
        }
        nodeScores.sort { $0.similarity > $1.similarity }
        edgeScores.sort { $0.similarity > $1.similarity }
        return Scored(nodeSeeds: Array(nodeScores.prefix(limit)),
                      edgeSeeds: Array(edgeScores.prefix(limit)),
                      nodeSimilarity: nodeSimilarity,
                      edgeSimilarity: edgeSimilarity)
    }

    /// Stage two, the projection: from the seed nodes, walk out `depth` hops and
    /// collect the triplets encountered, scoring each by the similarity of its best
    /// endpoint minus a penalty per hop — cognee's `triplet_distance_penalty`.
    static func project(scored: Scored,
                        store: (nodes: [UUID: MemoryNode], edges: [UUID: MemoryEdge],
                                edgesTouching: (UUID) -> [MemoryEdge]),
                        depth: Int,
                        penalty: Double,
                        limit: Int) -> [Triplet] {

        var best: [UUID: Triplet] = [:]     // by edge id

        func consider(_ edge: MemoryEdge, hop: Int) {
            guard let a = store.nodes[edge.sourceID], let b = store.nodes[edge.targetID] else { return }

            // A triplet is as relevant as its most relevant part. Scoring only the
            // seed node made every fact about a person score identically; taking the
            // best of edge, source and target lets "Nutzer → Brave" outrank
            // "Nutzer → Berlin" when the question is about search providers.
            let edgeSim = scored.edgeSimilarity[edge.id] ?? 0
            let sourceSim = scored.nodeSimilarity[edge.sourceID] ?? 0
            let targetSim = scored.nodeSimilarity[edge.targetID] ?? 0
            // The endpoints count, but the edge — the actual statement — counts most.
            let base = max(edgeSim, 0.9 * max(sourceSim, targetSim))

            // cognee's distance penalty, per hop away from a seed.
            let hopCost = Double(hop) * (penalty / 100.0)
            let reinforcement = min(0.06, Double(edge.mentions - 1) * 0.02)
            let score = max(0, base - hopCost) + reinforcement

            if let existing = best[edge.id], existing.score >= score { return }
            best[edge.id] = Triplet(source: a, edge: edge, target: b, score: score)
        }

        // Edges that matched the question directly are the strongest evidence there is.
        for s in scored.edgeSeeds {
            guard let e = store.edges[s.id] else { continue }
            consider(e, hop: 0)
        }

        var frontier: [(UUID, Double)] = scored.nodeSeeds.map { ($0.id, $0.similarity) }
        var visited = Set(scored.nodeSeeds.map(\.id))

        for hop in 0...max(0, depth) {
            var next: [(UUID, Double)] = []
            for (nodeID, similarity) in frontier {
                for edge in store.edgesTouching(nodeID) {
                    consider(edge, hop: hop)
                    let other = edge.sourceID == nodeID ? edge.targetID : edge.sourceID
                    if visited.insert(other).inserted {
                        next.append((other, similarity))
                    }
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }

        return best.values.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// Renders the retrieved triplets the way cognee hands them to the model: as
    /// plain statements, not as JSON. A model reads "Christoph arbeitet an Faden"
    /// better than it reads a serialised node object.
    static func context(from triplets: [Triplet]) -> String {
        guard !triplets.isEmpty else { return "" }
        return triplets.map { "- " + $0.text }.joined(separator: "\n")
    }
}
