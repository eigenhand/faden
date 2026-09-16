import Foundation

enum SpeechError: LocalizedError {
    case notConfigured(String)
    case http(status: Int, body: String)
    case transport(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return String(localized: "\(what) ist nicht eingerichtet.")
        case .http(let s, let b):
            let snippet = b.count > 200 ? String(b.prefix(200)) + "…" : b
            return String(localized: "HTTP \(s)\n\(snippet)")
        case .transport(let m):        return String(localized: "Verbindungsfehler: \(m)")
        case .empty:                   return String(localized: "Die Antwort war leer.")
        }
    }
}

/// Speech-to-text against an OpenAI-compatible `/v1/audio/transcriptions`, which is
/// what Whisper servers and most hosted providers speak.
enum RemoteSTT {

    static func transcribe(audio: Data, filename: String, config: SpeechConfig, apiKey: String) async throws -> String {
        guard let url = config.sttURL, !config.sttModel.isEmpty else {
            throw SpeechError.notConfigured("Der Endpoint für Spracherkennung")
        }

        let boundary = "perbu.\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)
        field("model", config.sttModel)
        if !config.sttLanguage.isEmpty { field("language", config.sttLanguage) }
        field("response_format", "json")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body

        let data: Data, response: URLResponse
        do { (data, response) = try await Net.session.data(for: req) }
        catch { throw SpeechError.transport(error.localizedDescription) }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw SpeechError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        // Servers answer with {"text": "..."} — or with plain text for some formats.
        if let obj = JSONValue.decode(data)?.objectValue, let t = obj["text"]?.stringValue {
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let plain = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !plain.isEmpty else { throw SpeechError.empty }
        return plain
    }
}

/// Text-to-speech against an OpenAI-compatible `/v1/audio/speech`.
enum RemoteTTS {

    static func synthesize(text: String, config: SpeechConfig, apiKey: String) async throws -> Data {
        guard let url = config.ttsURL, !config.ttsModel.isEmpty else {
            throw SpeechError.notConfigured("Der Endpoint für Sprachausgabe")
        }
        var body: [String: Any] = [
            "model": config.ttsModel,
            "input": text,
            "response_format": config.ttsFormat,
        ]
        if !config.ttsVoice.isEmpty { body["voice"] = config.ttsVoice }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await Net.session.data(for: req) }
        catch { throw SpeechError.transport(error.localizedDescription) }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw SpeechError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard data.count > 128 else { throw SpeechError.empty }
        return data
    }
}
