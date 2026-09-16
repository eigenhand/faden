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
        // „PerBu“ war der Arbeitsname, und dieser Ordner behält ihn. Ein
        // anderer Name wäre auf jedem Gerät, auf dem die App schon liegt,
        // ein leerer Ordner neben einem vollen — der ganze Wissensgraph weg.
        // Umbenennen ginge nur mit einem Umzug beim ersten Start, und der
        // hat einen Fehlerfall.
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

    // MARK: Der Index

    /// Wie der gespeicherte Index zum eingestellten Modell steht.
    struct IndexStatus: Equatable {
        /// Vektor vorhanden und vom eingestellten Modell — nutzbar.
        var usable = 0
        /// Vektor vorhanden, aber aus einem anderen Modell oder mit anderer
        /// Dimension. Rechnerisch unbrauchbar, muss neu eingebettet werden.
        var foreign = 0
        /// Noch gar kein Vektor.
        var missing = 0
        /// Welche Modelle im Index stecken, mit Anzahl — damit sichtbar ist,
        /// *was* da liegt, statt nur, dass etwas nicht passt.
        var byModel: [String: Int] = [:]
        /// Die Dimension, auf die sich das eingestellte Modell eingependelt hat.
        var dimension: Int?

        var total: Int { usable + foreign + missing }
        var needsWork: Int { foreign + missing }
        var isClean: Bool { needsWork == 0 }
    }

    /// Die Dimension, die das eingestellte Modell hier tatsächlich liefert.
    ///
    /// Nicht aus einer Tabelle, sondern aus dem Bestand: Anbieter ändern die Länge
    /// unter demselben Modellnamen. Die häufigste gewinnt; Ausreißer gelten damit
    /// als fremd und werden neu geholt.
    private func dominantDimension(for model: String) -> Int? {
        let wanted = EmbeddingStamp.normalise(model)
        var counts: [Int: Int] = [:]
        for stamp in allStamps() where EmbeddingStamp.normalise(stamp.model) == wanted {
            counts[stamp.dimension, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private func allStamps() -> [EmbeddingStamp] {
        nodes.values.filter(\.isValid).compactMap(\.embeddingStamp)
            + edges.values.filter(\.isValid).compactMap(\.embeddingStamp)
    }

    func indexStatus(model: String) -> IndexStatus {
        var status = IndexStatus()
        status.dimension = dominantDimension(for: model)

        func classify(embedding: [Float]?, stamp: EmbeddingStamp?) {
            guard embedding != nil else { status.missing += 1; return }
            if let stamp {
                status.byModel[stamp.model, default: 0] += 1
                if stamp.matches(model: model, dimension: status.dimension) {
                    status.usable += 1
                } else {
                    status.foreign += 1
                }
            } else {
                // Vektor ohne Stempel: aus einer Fassung vor dieser Kennzeichnung.
                // Unbekannte Herkunft ist so gut wie falsche Herkunft.
                status.byModel["unbekannt", default: 0] += 1
                status.foreign += 1
            }
        }

        for n in nodes.values where n.isValid { classify(embedding: n.embedding, stamp: n.embeddingStamp) }
        for e in edges.values where e.isValid { classify(embedding: e.embedding, stamp: e.embeddingStamp) }
        return status
    }

    /// Alles, was für das eingestellte Modell noch einen Vektor braucht — fehlend
    /// wie fremd. Die Warteschlange des Nachholens.
    func nodesNeedingEmbedding(model: String, limit: Int) -> [MemoryNode] {
        let dimension = dominantDimension(for: model)
        return Array(nodes.values
            .filter { $0.isValid && !usable($0.embedding, $0.embeddingStamp, model, dimension) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit))
    }

    func edgesNeedingEmbedding(model: String, limit: Int) -> [MemoryEdge] {
        let dimension = dominantDimension(for: model)
        return Array(edges.values
            .filter { $0.isValid && !usable($0.embedding, $0.embeddingStamp, model, dimension) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit))
    }

    private func usable(_ embedding: [Float]?, _ stamp: EmbeddingStamp?,
                        _ model: String, _ dimension: Int?) -> Bool {
        guard embedding != nil, let stamp else { return false }
        return stamp.matches(model: model, dimension: dimension)
    }

    func pendingEmbeddingCount(model: String) -> Int {
        indexStatus(model: model).needsWork
    }

    /// Wirft Vektoren weg — entweder alle, oder alles außer dem einen Modell.
    ///
    /// Weggeworfen statt aufgehoben, und zwar aus Platzgründen: ein Vektor mit 4096
    /// Dimensionen belegt in dieser JSON-Datei rund 48 KB. Zwei Modelle nebeneinander
    /// aufzuheben verdoppelt eine Datei, die ohnehin bei jedem Start vollständig
    /// gelesen wird.
    @discardableResult
    func dropEmbeddings(keeping model: String?) -> Int {
        let dimension = model.flatMap { dominantDimension(for: $0) }
        var dropped = 0

        for (id, var n) in nodes where n.embedding != nil {
            if let model, usable(n.embedding, n.embeddingStamp, model, dimension) { continue }
            n.embedding = nil; n.embeddingStamp = nil
            nodes[id] = n; dropped += 1
        }
        for (id, var e) in edges where e.embedding != nil {
            if let model, usable(e.embedding, e.embeddingStamp, model, dimension) { continue }
            e.embedding = nil; e.embeddingStamp = nil
            edges[id] = e; dropped += 1
        }
        save()
        return dropped
    }

    func setEmbedding(_ vector: [Float], stamp: EmbeddingStamp, forNode id: UUID) {
        guard var n = nodes[id] else { return }
        n.embedding = vector
        n.embeddingStamp = stamp
        nodes[id] = n
    }

    func setEmbedding(_ vector: [Float], stamp: EmbeddingStamp, forEdge id: UUID) {
        guard var e = edges[id] else { return }
        e.embedding = vector
        e.embeddingStamp = stamp
        edges[id] = e
    }

    /// Der Mittelvektor über alle nutzbaren Einbettungen.
    ///
    /// Wird für die Zentrierung der Vektoren vom Gerät gebraucht. Aus dem Bestand
    /// gerechnet statt gespeichert: er ändert sich mit jeder neuen Erinnerung, und
    /// über ein paar tausend Vektoren zu mitteln kostet weniger als eine Millisekunde.
    func centroid(model: String) -> [Float]? {
        let dimension = dominantDimension(for: model)
        var sum: [Float] = []
        var count = 0
        for v in (nodesWithEmbeddings(model: model).compactMap(\.embedding)
                  + edgesWithEmbeddings(model: model).compactMap(\.embedding)) {
            if sum.isEmpty { sum = [Float](repeating: 0, count: v.count) }
            guard sum.count == v.count else { continue }
            for i in 0 ..< v.count { sum[i] += v[i] }
            count += 1
        }
        guard count > 0, dimension != nil else { return nil }
        return sum.map { $0 / Float(count) }
    }

    /// Was die Suche benutzen darf: nur Vektoren aus dem eingestellten Modell.
    func nodesWithEmbeddings(model: String) -> [MemoryNode] {
        let dimension = dominantDimension(for: model)
        return nodes.values.filter { $0.isValid && usable($0.embedding, $0.embeddingStamp, model, dimension) }
    }

    func edgesWithEmbeddings(model: String) -> [MemoryEdge] {
        let dimension = dominantDimension(for: model)
        return edges.values.filter { $0.isValid && usable($0.embedding, $0.embeddingStamp, model, dimension) }
    }
}
