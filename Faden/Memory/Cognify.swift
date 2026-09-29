import Foundation

/// The ingestion pipeline — cognee's `cognify`, reduced to the steps that carry it:
/// chunk, extract a graph, embed what is searchable, merge into the store.
///
/// Left out on purpose: document classification (everything here is conversation),
/// ontology grounding, provenance records and contradiction resolution. Those are
/// the parts of cognee that earn their keep on a corpus with many sources; for a
/// personal memory they would cost model calls without changing what comes back.
struct Cognify {
    let llm: LLMConfig
    let llmKey: String
    let memory: MemoryConfig
    let embeddingKey: String

    struct Outcome {
        var nodesAdded = 0
        var edgesAdded = 0
        var summary = ""
        /// Nodes and edges stored without a vector, waiting for `backfill`.
        var pendingEmbeddings = 0
        var embeddingProblem: String?
    }

    /// Splits on paragraphs, keeping chunks below what an extraction handles well.
    /// cognee has a token-aware chunker; character count is a close enough proxy
    /// and avoids carrying a tokeniser onto the phone.
    static func chunk(_ text: String, maxChars: Int = 4000) -> [String] {
        guard text.count > maxChars else { return [text] }
        var chunks: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if current.count + paragraph.count > maxChars, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + paragraph
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    func run(on text: String,
             framing: String = GraphExtractor.personalFraming,
             onProgress: (@Sendable (String) -> Void)? = nil) async throws -> Outcome {
        let extractor = GraphExtractor(config: llm, apiKey: llmKey)
        let embedder = Embedder(config: memory, apiKey: embeddingKey)
        var outcome = Outcome()

        for piece in Self.chunk(text) {
            let graph = try await extractor.extract(from: piece, framing: framing)
            guard !graph.nodes.isEmpty else { continue }
            outcome.summary = graph.summary

            // Nodes first: edges reference them by the extractor's own ids, which
            // have to be mapped onto the deterministic ones.
            var byExtractedID: [String: MemoryNode] = [:]
            var newNodes: [MemoryNode] = []
            for n in graph.nodes {
                let name = n.name.isEmpty ? n.id : n.name
                guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let node = MemoryNode(name: name, type: n.type, description: n.description)
                byExtractedID[n.id] = node
                byExtractedID[name] = node
                newNodes.append(node)
            }

            var newEdges: [MemoryEdge] = []
            for e in graph.edges {
                guard let source = byExtractedID[e.source_node_id],
                      let target = byExtractedID[e.target_node_id],
                      source.id != target.id else { continue }
                newEdges.append(MemoryEdge(
                    sourceID: source.id, targetID: target.id,
                    relationship: e.relationship_name,
                    description: e.description ?? ""))
            }

            // Embed nodes and edges in one batch — this is the only network cost
            // that scales with the size of the extraction.
            //
            // If the embedding endpoint is rate-limited or down, the extraction is
            // still kept: the facts were already paid for with a model call, and
            // throwing them away would mean paying again to rediscover them. The
            // vectors are filled in later by `backfill`; until then those nodes are
            // simply not findable by similarity, which is a smaller loss than not
            // having them at all.
            let texts = newNodes.map(\.embeddableText) + newEdges.map(\.embeddableText)
            var vectors: [[Float]] = []
            do {
                vectors = try await embedder.embed(texts, onWait: { attempt in
                    onProgress?(String(localized: "Einbettung wartet auf den Anbieter (Versuch \(attempt)) …"))
                })
            } catch {
                outcome.pendingEmbeddings += newNodes.count + newEdges.count
                outcome.embeddingProblem = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }

            for (i, var node) in newNodes.enumerated() {
                let vector = vectors.indices.contains(i) ? vectors[i] : nil
                node.embedding = vector
                node.embeddingStamp = vector.map {
                    EmbeddingStamp(model: memory.effectiveModel, dimension: $0.count)
                }
                await MemoryStore.shared.upsert(node)
            }
            for (i, var edge) in newEdges.enumerated() {
                let index = newNodes.count + i
                let vector = vectors.indices.contains(index) ? vectors[index] : nil
                edge.embedding = vector
                edge.embeddingStamp = vector.map {
                    EmbeddingStamp(model: memory.effectiveModel, dimension: $0.count)
                }
                await MemoryStore.shared.upsert(edge)
            }
            await MemoryStore.shared.commit()

            outcome.nodesAdded += newNodes.count
            outcome.edgesAdded += newEdges.count
        }
        return outcome
    }

    /// Fills in vectors for anything stored without one.
    ///
    /// This is what makes a metered embedding endpoint survivable: ingestion never
    /// blocks on it, and whatever could not be embedded at the time is picked up
    /// here — on the next launch, the next turn, or a manual retry.
    @discardableResult
    static func backfill(memory: MemoryConfig, embeddingKey: String,
                         limit: Int = 64,
                         onProgress: (@Sendable (String) -> Void)? = nil) async -> Int {
        guard memory.isReady else { return 0 }
        await MemoryStore.shared.load()

        // Foreign vectors count here like missing ones: they are present but in the
        // wrong space, and the catch-up is exactly the route by which they are replaced
        // — without anyone having to start anything.
        let nodes = await MemoryStore.shared.nodesNeedingEmbedding(model: memory.effectiveModel, limit: limit)
        let edges = await MemoryStore.shared.edgesNeedingEmbedding(model: memory.effectiveModel, limit: limit)
        guard !nodes.isEmpty || !edges.isEmpty else { return 0 }

        let embedder = Embedder(config: memory, apiKey: embeddingKey)
        let texts = nodes.map(\.embeddableText) + edges.map(\.embeddableText)
        onProgress?(String(localized: "Hole \(texts.count) Einbettungen nach …"))

        guard let vectors = try? await embedder.embed(texts, onWait: { attempt in
            onProgress?(String(localized: "Anbieter ausgelastet, neuer Versuch in einer Minute (\(attempt)) …"))
        }) else { return 0 }

        for (i, node) in nodes.enumerated() where vectors.indices.contains(i) {
            let stamp = EmbeddingStamp(model: memory.effectiveModel, dimension: vectors[i].count)
            await MemoryStore.shared.setEmbedding(vectors[i], stamp: stamp, forNode: node.id)
        }
        for (i, edge) in edges.enumerated() {
            let index = nodes.count + i
            guard vectors.indices.contains(index) else { continue }
            let stamp = EmbeddingStamp(model: memory.effectiveModel, dimension: vectors[index].count)
            await MemoryStore.shared.setEmbedding(vectors[index], stamp: stamp, forEdge: edge.id)
        }
        await MemoryStore.shared.commit()
        return texts.count
    }

    /// The read side: find what the graph knows about a question.
    static func recall(question: String, memory: MemoryConfig, embeddingKey: String) async throws -> [Triplet] {
        await MemoryStore.shared.load()
        let (nodeCount, _) = await MemoryStore.shared.counts
        guard nodeCount > 0 else { return [] }

        let embedder = Embedder(config: memory, apiKey: embeddingKey)
        let queryVector = try await embedder.embed(question)

        // Only vectors from the configured model. Everything else lies in a different
        // space; a cosine against it is a number without meaning.
        let nodes = await MemoryStore.shared.nodesWithEmbeddings(model: memory.effectiveModel)
        let edges = await MemoryStore.shared.edgesWithEmbeddings(model: memory.effectiveModel)
        let centroid = memory.needsCentering
            ? await MemoryStore.shared.centroid(model: memory.effectiveModel)
            : nil
        let scored = TripletSearch.seeds(
            for: queryVector, nodes: nodes, edges: edges,
            limit: memory.wideSearchTopK, minimum: memory.minimumSimilarity,
            centroid: centroid)
        guard !scored.nodeSeeds.isEmpty || !scored.edgeSeeds.isEmpty else { return [] }

        let nodeMap = await MemoryStore.shared.nodes
        let edgeMap = await MemoryStore.shared.edges
        let adjacency = await MemoryStore.shared.adjacency()
        return TripletSearch.project(
            scored: scored,
            store: (nodes: nodeMap, edges: edgeMap,
                    edgesTouching: { adjacency[$0] ?? [] }),
            depth: memory.neighborhoodDepth,
            penalty: memory.distancePenalty,
            limit: memory.topK)
    }
}
