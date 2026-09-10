import Foundation

/// The persisted memory graph.
///
/// cognee splits storage across a graph database, a vector database and a relational
/// one. At personal scale that separation buys nothing and costs three dependencies,
/// so nodes, edges and their vectors live together in one file that is loaded once
/// and held in memory — which is also what makes the brute-force triplet search fast.
actor MemoryStore {
    static let shared = MemoryStore()

    private(set) var nodes: [UUID: MemoryNode] = [:]
    private(set) var edges: [UUID: MemoryEdge] = [:]
    /// Adjacency in both directions, so a neighbourhood walk does not scan all edges.
    private var outgoing: [UUID: Set<UUID>] = [:]
    private var incoming: [UUID: Set<UUID>] = [:]

    private let url: URL
    private var loaded = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PerBu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("memory.json")
    }

    private struct Persisted: Codable {
        var nodes: [MemoryNode]
        var edges: [MemoryEdge]
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let p = try? decoder.decode(Persisted.self, from: data) else { return }
        nodes = Dictionary(uniqueKeysWithValues: p.nodes.map { ($0.id, $0) })
        edges = Dictionary(uniqueKeysWithValues: p.edges.map { ($0.id, $0) })
        rebuildAdjacency()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let p = Persisted(nodes: Array(nodes.values), edges: Array(edges.values))
        guard let data = try? encoder.encode(p) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func rebuildAdjacency() {
        outgoing.removeAll(); incoming.removeAll()
        for e in edges.values where e.isValid {
            outgoing[e.sourceID, default: []].insert(e.id)
            incoming[e.targetID, default: []].insert(e.id)
        }
    }

    // MARK: Writing

    /// Merges a node. Because the id is derived from type and name, a node that was
    /// seen before is found here and reinforced rather than duplicated — this is
    /// where a graph is built instead of a heap.
    func upsert(_ node: MemoryNode) {
        if var existing = nodes[node.id] {
            existing.mentions += 1
            existing.updatedAt = Date()
            // A later, fuller description wins; an empty one never overwrites.
            if existing.nodeDescription.count < node.nodeDescription.count {
                existing.nodeDescription = node.nodeDescription
                existing.embedding = node.embedding ?? existing.embedding
                existing.version += 1
            } else if existing.embedding == nil {
                existing.embedding = node.embedding
            }
            nodes[node.id] = existing
        } else {
            nodes[node.id] = node
        }
    }

    func upsert(_ edge: MemoryEdge) {
        if var existing = edges[edge.id] {
            existing.mentions += 1
            if existing.edgeDescription.count < edge.edgeDescription.count {
                existing.edgeDescription = edge.edgeDescription
                existing.embedding = edge.embedding ?? existing.embedding
            } else if existing.embedding == nil {
                existing.embedding = edge.embedding
            }
            edges[edge.id] = existing
        } else {
            edges[edge.id] = edge
        }
        outgoing[edge.sourceID, default: []].insert(edge.id)
        incoming[edge.targetID, default: []].insert(edge.id)
    }

    func commit() { save() }

    /// Writes a node exactly as given.
    ///
    /// `upsert` merges: it counts a mention and refuses a shorter description, which
    /// is right when the same fact arrives twice from extraction and wrong when
    /// somebody is correcting it by hand.
    func replace(_ node: MemoryNode) {
        guard nodes[node.id] != nil else { return }
        nodes[node.id] = node
        save()
    }

    /// cognee's `close_node`: a fact that no longer holds is closed, not erased, so
    /// the graph keeps its history instead of quietly rewriting it.
    func close(nodeID: UUID) {
        guard var n = nodes[nodeID] else { return }
        n.validTo = Date()
        nodes[nodeID] = n
        save()
    }

    func forget(nodeID: UUID) {
        nodes[nodeID] = nil
        for id in (outgoing[nodeID] ?? []).union(incoming[nodeID] ?? []) { edges[id] = nil }
        outgoing[nodeID] = nil
        incoming[nodeID] = nil
        save()
    }

    func forgetAll() {
        nodes.removeAll(); edges.removeAll()
        outgoing.removeAll(); incoming.removeAll()
        save()
    }

    // MARK: Reading

    var counts: (nodes: Int, edges: Int) {
        (nodes.values.filter(\.isValid).count, edges.values.filter(\.isValid).count)
    }

    func allNodes() -> [MemoryNode] {
        nodes.values.filter(\.isValid).sorted { $0.updatedAt > $1.updatedAt }
    }

    func edges(touching id: UUID) -> [MemoryEdge] {
        let ids = (outgoing[id] ?? []).union(incoming[id] ?? [])
        return ids.compactMap { edges[$0] }.filter(\.isValid)
    }

    func node(_ id: UUID) -> MemoryNode? { nodes[id] }

    /// Adjacency snapshot for the search, so the projection walks the graph instead
    /// of scanning every edge per node.
    func adjacency() -> [UUID: [MemoryEdge]] {
        var map: [UUID: [MemoryEdge]] = [:]
        for e in edges.values where e.isValid {
            map[e.sourceID, default: []].append(e)
            map[e.targetID, default: []].append(e)
        }
        return map
    }

    /// What still needs a vector — the queue the backfill works through.
    func nodesMissingEmbeddings(limit: Int) -> [MemoryNode] {
        Array(nodes.values.filter { $0.isValid && $0.embedding == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit))
    }

    func edgesMissingEmbeddings(limit: Int) -> [MemoryEdge] {
        Array(edges.values.filter { $0.isValid && $0.embedding == nil }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit))
    }

    var pendingEmbeddingCount: Int {
        nodes.values.filter { $0.isValid && $0.embedding == nil }.count
            + edges.values.filter { $0.isValid && $0.embedding == nil }.count
    }

    func setEmbedding(_ vector: [Float], forNode id: UUID) {
        guard var n = nodes[id] else { return }
        n.embedding = vector
        nodes[id] = n
    }

    func setEmbedding(_ vector: [Float], forEdge id: UUID) {
        guard var e = edges[id] else { return }
        e.embedding = vector
        edges[id] = e
    }

    func nodesWithEmbeddings() -> [MemoryNode] {
        nodes.values.filter { $0.isValid && $0.embedding != nil }
    }

    func edgesWithEmbeddings() -> [MemoryEdge] {
        edges.values.filter { $0.isValid && $0.embedding != nil }
    }
}
