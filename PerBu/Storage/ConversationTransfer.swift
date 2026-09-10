import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A conversation as a file. Declared in Info.plist as well; the two must agree.
    static let perbuConversation = UTType(exportedAs: "dev.eigenhand.perbu.conversation")
}

/// Passing a conversation on, as a file.
///
/// The obvious alternative was a link carrying the whole chat. Measured on real text
/// that holds for a short exchange and stops holding quickly: six messages pack into
/// about 3 600 characters, twenty into 12 000, sixty into 33 000 — and a single photo
/// pushes it past 340 000, because a JPEG is already compressed and there is nothing
/// left for zlib to take. A file has no such ceiling, travels through AirDrop, Files
/// and Messages the same way, and needs no server at either end.
enum ConversationTransfer {

    /// A version marker so a file written today can still be read after the message
    /// format has moved on.
    private struct Envelope: Codable {
        var perbu: Int = 1
        var conversation: Conversation
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func data(for conversation: Conversation) throws -> Data {
        try encoder.encode(Envelope(conversation: conversation))
    }

    /// Writes the conversation to a temporary file named after its title.
    static func write(_ conversation: Conversation) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename(for: conversation))
        try data(for: conversation).write(to: url, options: .atomic)
        return url
    }

    static func read(_ url: URL) throws -> Conversation {
        // A file handed over by another app lives outside this app's sandbox until
        // it is opened this way.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let raw = try Data(contentsOf: url)
        if let envelope = try? decoder.decode(Envelope.self, from: raw) {
            return envelope.conversation
        }
        // A bare conversation, in case one was ever written without the envelope.
        return try decoder.decode(Conversation.self, from: raw)
    }

    private static func filename(for conversation: Conversation) -> String {
        let title = conversation.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = title.isEmpty ? "Unterhaltung" : String(title.prefix(60))
        return stem + ".perbu"
    }
}

extension Conversation: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .perbuConversation) { conversation in
            SentTransferredFile(try ConversationTransfer.write(conversation))
        }
    }
}
