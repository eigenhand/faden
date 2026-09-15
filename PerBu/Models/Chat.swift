import Foundation

// MARK: - Content blocks

/// One piece of a message. Modelled after Anthropic's block shape because it is the
/// richer of the two wire formats — the OpenAI adapter folds down into it losslessly.
enum ContentBlock: Codable, Equatable, Hashable, Identifiable, Sendable {
    case text(String)
    case thinking(String)
    /// Base64-encoded image data plus its media type, e.g. `image/jpeg`.
    case image(data: String, mediaType: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)

    var id: String {
        switch self {
        case .text(let t):                    return "t:\(t.hashValue)"
        case .thinking(let t):                return "k:\(t.hashValue)"
        case .image(let d, _):                return "i:\(d.hashValue)"
        case .toolUse(let id, _, _):          return "u:\(id)"
        case .toolResult(let id, _, _):       return "r:\(id)"
        }
    }

    var plainText: String {
        switch self {
        case .text(let t):                    return t
        case .thinking:                       return ""
        case .image:                          return "[Bild]"
        case .toolUse(_, let name, let input):return "[\(name) \(input.compactDescription)]"
        case .toolResult(_, let c, _):        return c
        }
    }
}

enum Role: String, Codable, Hashable, Sendable { case user, assistant, system }

struct Message: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID = UUID()
    var role: Role
    var blocks: [ContentBlock]
    var createdAt: Date = Date()
    /// Token cost as measured/estimated when this message entered the context.
    var tokens: Int = 0
    /// Set on the synthetic message that replaces compacted history.
    var isCompactionSummary: Bool = false
    /// Number of original messages this summary stands in for (UI only).
    var replacedMessageCount: Int = 0
    /// Which model wrote this. Reviews of conversational agents find that visual cues
    /// *without* transparency reduce willingness to keep using a system — and with
    /// several models configured, an answer that does not say who wrote it is exactly
    /// that. Nil for older messages and for anything the user wrote.
    var producedBy: String?

    var text: String { blocks.map(\.plainText).joined(separator: "\n") }

    /// Ob an dieser Nachricht ein Bild haengt.
    ///
    /// Steht hier und nicht dreimal als `if case .image = $0` im Code verteilt: an
    /// dieser Frage haengt jetzt, welches Modell den Zug bearbeitet, und eine
    /// Formulierung an einer Stelle kann nicht an der zweiten anders ausfallen.
    var hasImage: Bool {
        blocks.contains { if case .image = $0 { return true }; return false }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                   = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role                 = try c.decode(Role.self, forKey: .role)
        blocks               = try c.decodeIfPresent([ContentBlock].self, forKey: .blocks) ?? []
        createdAt            = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        tokens               = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        isCompactionSummary  = try c.decodeIfPresent(Bool.self, forKey: .isCompactionSummary) ?? false
        replacedMessageCount = try c.decodeIfPresent(Int.self, forKey: .replacedMessageCount) ?? 0
        producedBy           = try c.decodeIfPresent(String.self, forKey: .producedBy)
    }

    init(role: Role, text: String) {
        self.role = role
        self.blocks = [.text(text)]
    }

    init(role: Role, blocks: [ContentBlock]) {
        self.role = role
        self.blocks = blocks
    }
}

// MARK: - Conversation

struct Conversation: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String = "Neue Unterhaltung"
    var messages: [Message] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Running total of tokens the last request actually consumed, as reported by the
    /// provider. Falls back to the estimator when the provider says nothing.
    var lastReportedInputTokens: Int?
    var compactionCount: Int = 0
    /// Message count when the title was last written by the model. Zero means the
    /// title is still the provisional one taken from the opening message.
    var titledAtMessageCount: Int = 0

    init() {}

    /// Tolerant like the settings: a stored conversation must survive new fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                     = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title                  = try c.decodeIfPresent(String.self, forKey: .title) ?? "Neue Unterhaltung"
        messages               = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        createdAt              = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt              = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        lastReportedInputTokens = try c.decodeIfPresent(Int.self, forKey: .lastReportedInputTokens)
        compactionCount        = try c.decodeIfPresent(Int.self, forKey: .compactionCount) ?? 0
        titledAtMessageCount   = try c.decodeIfPresent(Int.self, forKey: .titledAtMessageCount) ?? 0
    }

    var preview: String {
        messages.first(where: { $0.role == .user })?.text.prefix(80).description ?? ""
    }
}

// MARK: - A tiny dynamic JSON value

/// Needed everywhere: tool inputs, arbitrary search responses, learned parser recipes.
indirect enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Numbers before booleans, and not the other way round: Swift's decoder
        // happily reads JSON `0` and `1` as Bool, so the reverse order silently
        // turned every exact 0.0 in an embedding vector into `false` and dropped
        // it — leaving vectors of differing length whose cosine similarity is 0.
        // `true`/`false` are not decodable as Double, so this order is safe.
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:            try c.encodeNil()
        case .bool(let b):     try c.encode(b)
        case .number(let d):   d == d.rounded() && abs(d) < 9e15 ? try c.encode(Int(d)) : try c.encode(d)
        case .string(let s):   try c.encode(s)
        case .array(let a):    try c.encode(a)
        case .object(let o):   try c.encode(o)
        }
    }

    // Convenience accessors
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let d): return d == d.rounded() ? String(Int(d)) : String(d)
        case .bool(let b):   return String(b)
        default:             return nil
        }
    }
    /// Ein Wahrheitswert, auch wenn er als Wort oder Zahl dasteht.
    ///
    /// Modelllisten schreiben Fähigkeiten mal als `true`, mal als `"true"`, mal als
    /// `1` — und wer nur den echten Boolean liest, hält die anderen beiden für
    /// „nicht angegeben". Das ist der Unterschied zwischen einer Marke, die
    /// erscheint, und einer, die fehlt.
    var boolValue: Bool? {
        switch self {
        case .bool(let b):   return b
        case .number(let d): return d != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "1":  return true
            case "false", "no", "0":  return false
            default:                  return nil
            }
        default: return nil
        }
    }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Resolve a dotted path such as `web.results` or `data.items.0.title`.
    func value(atPath path: String) -> JSONValue? {
        guard !path.isEmpty else { return self }
        var cur: JSONValue = self
        for part in path.split(separator: ".") {
            if let idx = Int(part) {
                guard let arr = cur.arrayValue, arr.indices.contains(idx) else { return nil }
                cur = arr[idx]
            } else {
                guard let next = cur[String(part)] else { return nil }
                cur = next
            }
        }
        return cur
    }

    var compactDescription: String {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return "…" }
        return s.count > 120 ? String(s.prefix(117)) + "…" : s
    }

    static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull:            return .null
        case let b as Bool:        return .bool(b)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String:      return .string(s)
        case let a as [Any]:       return .array(a.map(JSONValue.from))
        case let o as [String: Any]:
            return .object(o.mapValues(JSONValue.from))
        default:                   return .null
        }
    }

    static func decode(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return .from(any)
    }
}
