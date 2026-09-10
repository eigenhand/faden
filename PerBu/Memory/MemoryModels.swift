import Foundation

/// What the extracting model is asked to return — cognee's `KnowledgeGraph`.
struct ExtractedGraph: Codable, Equatable {
    var summary: String = ""
    var description: String = ""
    var nodes: [ExtractedNode] = []
    var edges: [ExtractedEdge] = []
}

struct ExtractedNode: Codable, Equatable {
    /// Human-readable identifier from the text, never an integer — cognee is
    /// explicit about this, because the id doubles as the merge key.
    var id: String
    var name: String
    var type: String
    var description: String
}

struct ExtractedEdge: Codable, Equatable {
    var source_node_id: String
    var target_node_id: String
    var relationship_name: String
    /// One concrete sentence stating the fact, phrased with the endpoint names.
    /// This is what gets embedded for edge search.
    var description: String?
}

// MARK: - Stored graph

/// A node in the persisted memory graph — cognee's `DataPoint`, reduced to the
/// fields that carry weight on a phone.
struct MemoryNode: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var type: String
    var nodeDescription: String

    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// cognee's bi-temporal validity: a superseded fact is closed, not deleted, so
    /// "where did Christoph live before" stays answerable.
    var validTo: Date?
    var version: Int = 1

    /// How often this node has been seen. Repetition is evidence of importance.
    var mentions: Int = 1
    /// Embedding of the node's embeddable text.
    var embedding: [Float]?

    var isValid: Bool { validTo == nil }

    /// The text that gets embedded — cognee's `get_embeddable_data`.
    var embeddableText: String {
        nodeDescription.isEmpty ? "\(name) (\(type))" : "\(name) (\(type)): \(nodeDescription)"
    }

    init(name: String, type: String, description: String) {
        self.id = NodeIdentity.id(type: type, name)
        self.name = name
        self.type = type
        self.nodeDescription = description
    }
}

/// An edge, stored as its own searchable object.
///
/// cognee embeds edges as well as nodes, and it matters: "Christoph arbeitet an
/// PerBu" is a sentence a question can match against, while the two endpoint names
/// on their own are not.
struct MemoryEdge: Identifiable, Codable, Equatable {
    var id: UUID
    var sourceID: UUID
    var targetID: UUID
    var relationship: String
    var edgeDescription: String

    var createdAt: Date = Date()
    var validTo: Date?
    var mentions: Int = 1
    var embedding: [Float]?
    /// Adjusted by feedback; cognee weights triplets by it during ranking.
    var weight: Double = 1.0

    var isValid: Bool { validTo == nil }

    var embeddableText: String {
        edgeDescription.isEmpty ? relationship.replacingOccurrences(of: "_", with: " ") : edgeDescription
    }

    init(sourceID: UUID, targetID: UUID, relationship: String, description: String) {
        // An edge is identified by what it connects and how, so the same statement
        // seen twice reinforces one edge instead of duplicating it.
        self.id = NodeIdentity.id(type: "Edge",
                                  values: [sourceID.uuidString, relationship, targetID.uuidString])
        self.sourceID = sourceID
        self.targetID = targetID
        self.relationship = relationship
        self.edgeDescription = description
    }
}

/// A node–edge–node triplet, the unit cognee retrieves and hands to the model.
struct Triplet: Identifiable, Equatable {
    var id: UUID { edge.id }
    var source: MemoryNode
    var edge: MemoryEdge
    var target: MemoryNode
    /// Relevance, combining vector distance with the penalties cognee applies.
    var score: Double = 0

    /// cognee's `format_triplets`, trimmed to what reads well in a prompt.
    var text: String {
        var line = "\(source.name) — \(edge.relationship.replacingOccurrences(of: "_", with: " ")) → \(target.name)"
        if !edge.edgeDescription.isEmpty { line += "\n  \(edge.edgeDescription)" }
        if !source.nodeDescription.isEmpty { line += "\n  \(source.name): \(source.nodeDescription)" }
        if !target.nodeDescription.isEmpty { line += "\n  \(target.name): \(target.nodeDescription)" }
        return line
    }
}
