import UIKit

/// Finds out whether a configured model actually accepts images.
///
/// There is no reliable way to ask an arbitrary endpoint what it supports — model
/// lists rarely say, and capability fields differ per vendor. So the app simply
/// tries: it sends a tiny two-colour image and asks what is in it. A rejection
/// (usually HTTP 400) means no vision; an answer naming both colours means the
/// model genuinely sees, rather than merely tolerating, the attachment.
enum VisionProbe {

    enum Outcome: Equatable {
        /// The endpoint took the image and the model described it correctly.
        case supported
        /// The image was accepted, but the answer did not name the colours — most
        /// likely still fine, just unconfirmed.
        case acceptedButUnconfirmed(String)
        case notSupported(String)
        case inconclusive(String)
    }

    /// Rendered rather than embedded: a base64 constant would add kilobytes of
    /// source for something two drawing calls produce.
    static func probeImage() -> Data? {
        let side: CGFloat = 64
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            UIColor(red: 0.91, green: 0.50, blue: 0.16, alpha: 1).setFill()      // orange, oben
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
            UIColor(red: 0.48, green: 0.31, blue: 0.75, alpha: 1).setFill()      // violett, unten
            ctx.fill(CGRect(x: 0, y: side / 2, width: side, height: side / 2))
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    private static let question = """
    Das Bild besteht aus zwei waagerechten Farbflächen. Nenne nur die beiden Farben, \
    obere zuerst, getrennt durch ein Komma. Keine weiteren Worte.
    """

    /// Error bodies are often JSON wrapped in JSON. Dig out the innermost human
    /// sentence instead of showing the reader a wall of escaped braces.
    static func readableMessage(from body: String) -> String {
        var current = body
        for _ in 0..<3 {
            guard let data = current.data(using: .utf8),
                  let obj = JSONValue.decode(data)?.objectValue
            else { break }
            guard let message = obj["error"]?["message"]?.stringValue
                    ?? obj["message"]?.stringValue
                    ?? obj["detail"]?.stringValue
            else { break }
            current = message
        }
        let cleaned = current
            .replacingOccurrences(of: "\\\"", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
    }

    static func run(config: LLMConfig, apiKey: String) async -> Outcome {
        guard let jpeg = probeImage() else {
            return .inconclusive(String(localized: "Das Testbild ließ sich nicht erzeugen."))
        }
        let message = Message(role: .user, blocks: [
            .image(data: jpeg.base64EncodedString(), mediaType: "image/jpeg"),
            .text(question),
        ])

        let cfg: LLMConfig = {
            var c = config
            c.supportsVision = true
            return c
        }()
        let provider = ProviderFactory.make(for: cfg.wireFormat)

        let reply: String
        do {
            reply = try await withTimeout(seconds: 90) {
                try await provider.complete(
                    messages: [message], system: "Du antwortest knapp.",
                    config: cfg, apiKey: apiKey,
                    maxTokens: max(3000, min(6000, cfg.maxOutputTokens)))
            }
        } catch let error as LLMError {
            if case .http(let status, let body) = error {
                // 4xx here is the endpoint saying it cannot take images at all;
                // 5xx and the rest say nothing about vision.
                if (400...499).contains(status) {
                    return .notSupported(String(localized: "Der Endpoint hat das Bild abgelehnt (HTTP \(status)). ")
                                         + readableMessage(from: body))
                }
                return .inconclusive(String(localized: "HTTP \(status) — das sagt nichts über Bilder aus."))
            }
            return .inconclusive(error.errorDescription ?? String(localized: "Unklar."))
        } catch {
            return .inconclusive(error.localizedDescription)
        }

        let answer = reply.lowercased()
        let sawOrange = ["orange", "orangefarben"].contains { answer.contains($0) }
        let sawViolet = ["violett", "lila", "purpur", "purple", "violet"].contains { answer.contains($0) }
        if sawOrange && sawViolet { return .supported }
        return .acceptedButUnconfirmed(String(reply.prefix(80)))
    }
}
