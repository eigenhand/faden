import Foundation
import CryptoKit

/// Deterministic node identity, as cognee defines it.
///
/// A node's id is derived from what the node *is*, not from when it was created:
/// `uuid5(NAMESPACE_OID, "Type:value")`. Two mentions of "Christoph" in different
/// conversations therefore produce the same id and merge into one node, which is
/// what turns a pile of extractions into a graph. Random ids would leave a new
/// island every time the same person came up.
enum NodeIdentity {

    /// RFC 4122 namespace OID — the same namespace cognee uses.
    static let namespaceOID = UUID(uuidString: "6ba7b812-9dad-11d1-80b4-00c04fd430c8")!

    /// UUID version 5: SHA-1 over namespace + name, with version and variant bits set.
    /// Foundation has no v5 generator, so it is spelled out here.
    static func uuid5(namespace: UUID, name: String) -> UUID {
        var bytes = [UInt8]()
        withUnsafeBytes(of: namespace.uuid) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(name.utf8))

        var digest = Array(Insecure.SHA1.hash(data: Data(bytes)))
        digest[6] = (digest[6] & 0x0F) | 0x50   // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80   // RFC 4122 variant

        let u = (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
                 digest[6], digest[7], digest[8], digest[9], digest[10], digest[11],
                 digest[12], digest[13], digest[14], digest[15])
        return UUID(uuid: u)
    }

    /// cognee's `generate_node_id`: names are normalised so that "Steve Jobs",
    /// "steve jobs" and "Steve  Jobs" are one node rather than three.
    static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
    }

    /// cognee's `DataPoint.id_for`: the type name is part of the namespace, so a
    /// Person and a Place of the same name cannot collide.
    static func id(type: String, values: [String]) -> UUID {
        let joined = values.map(normalize).joined(separator: "|")
        return uuid5(namespace: namespaceOID, name: "\(type):\(joined)")
    }

    static func id(type: String, _ value: String) -> UUID {
        id(type: type, values: [value])
    }
}
