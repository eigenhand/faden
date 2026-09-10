import Foundation

/// Talks the Anthropic Messages API (`POST /v1/messages`).
/// Headers per the API reference: `x-api-key`, `anthropic-version: 2023-06-01`.
struct AnthropicProvider: LLMProvider {

    static let version = "2023-06-01"

    // MARK: Request assembly

    private func wireMessages(_ messages: [Message]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages where m.role != .system {
            var blocks: [[String: Any]] = []
            for b in m.blocks {
                switch b {
                case .text(let t):
                    guard !t.isEmpty else { continue }
                    blocks.append(["type": "text", "text": t])
                case .thinking:
                    // Thinking blocks are not replayed: they are bound to the producing
                    // model, and a foreign endpoint would reject them.
                    continue
                case .image(let data, let mediaType):
                    blocks.append([
                        "type": "image",
                        "source": ["type": "base64", "media_type": mediaType, "data": data],
                    ])
                case .toolUse(let id, let name, let input):
                    blocks.append(["type": "tool_use", "id": id, "name": name,
                                   "input": input.anyValue as? [String: Any] ?? [:]])
                case .toolResult(let id, let content, let isError):
                    var r: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
                    if isError { r["is_error"] = true }
                    blocks.append(r)
                }
            }
            guard !blocks.isEmpty else { continue }
            out.append(["role": m.role.rawValue, "content": blocks])
        }
        return mergeAdjacent(out)
    }

    /// The API requires strictly alternating roles; tool results from parallel calls
    /// must arrive in one user message.
    private func mergeAdjacent(_ msgs: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in msgs {
            if let last = out.last,
               last["role"] as? String == m["role"] as? String,
               var lc = last["content"] as? [[String: Any]],
               let mc = m["content"] as? [[String: Any]] {
                lc.append(contentsOf: mc)
                out[out.count - 1]["content"] = lc
            } else {
                out.append(m)
            }
        }
        return out
    }

    private func body(
        messages: [Message], system: String, tools: [ToolSpec],
        config: LLMConfig, stream: Bool, maxTokens: Int
    ) -> [String: Any] {
        var b: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": wireMessages(messages),
        ]
        if !system.isEmpty {
            var sysBlock: [String: Any] = ["type": "text", "text": system]
            if config.useCacheControl { sysBlock["cache_control"] = ["type": "ephemeral"] }
            b["system"] = [sysBlock]
        }
        if !tools.isEmpty {
            b["tools"] = tools.map { t in
                ["name": t.name, "description": t.description,
                 "input_schema": t.inputSchema.anyValue]
            }
        }
        if config.requestThinking {
            b["thinking"] = ["type": "adaptive", "display": "summarized"]
        } else if config.temperature != 1.0 {
            // Sampling parameters are rejected alongside adaptive thinking.
            b["temperature"] = config.temperature
        }
        if stream { b["stream"] = true }
        return b
    }

    private func request(_ config: LLMConfig, apiKey: String, url: URL, body: [String: Any]) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        for (k, v) in config.extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    // MARK: Streaming

    func stream(
        messages: [Message], system: String, tools: [ToolSpec],
        config: LLMConfig, apiKey: String
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = config.endpointURL else { throw LLMError.notConfigured }
                    let req = try request(config, apiKey: apiKey, url: url,
                                          body: body(messages: messages, system: system, tools: tools,
                                                     config: config, stream: true,
                                                     maxTokens: config.maxOutputTokens))
                    let (bytes, response) = try await Net.session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw LLMError.transport("Keine HTTP-Antwort") }
                    guard (200...299).contains(http.statusCode) else {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line; if errBody.count > 2000 { break } }
                        throw LLMError.http(status: http.statusCode, body: errBody)
                    }

                    // Per-index state for the blocks the server streams.
                    var toolID: [Int: String] = [:]
                    var toolName: [Int: String] = [:]
                    var toolJSON: [Int: PartialJSONAccumulator] = [:]

                    /// Handles one SSE record. Returns false when the turn is over.
                    func handle(_ ev: SSEEvent) throws -> Bool {
                        guard let data = ev.data.data(using: .utf8),
                              let obj = JSONValue.decode(data)?.objectValue else { return true }
                        let type = obj["type"]?.stringValue ?? ev.event ?? ""

                        switch type {
                        case "message_start":
                            if let u = obj["message"]?["usage"]?.objectValue {
                                continuation.yield(.usage(
                                    input: u["input_tokens"].flatMap { Int($0.stringValue ?? "") },
                                    output: u["output_tokens"].flatMap { Int($0.stringValue ?? "") }))
                            }

                        case "content_block_start":
                            let idx = Int(obj["index"]?.stringValue ?? "") ?? 0
                            guard let cb = obj["content_block"]?.objectValue else { break }
                            if cb["type"]?.stringValue == "tool_use" {
                                let id = cb["id"]?.stringValue ?? UUID().uuidString
                                let name = cb["name"]?.stringValue ?? ""
                                toolID[idx] = id; toolName[idx] = name
                                toolJSON[idx] = PartialJSONAccumulator()
                                continuation.yield(.toolUseStarted(id: id, name: name))
                            }

                        case "content_block_delta":
                            let idx = Int(obj["index"]?.stringValue ?? "") ?? 0
                            guard let d = obj["delta"]?.objectValue else { break }
                            switch d["type"]?.stringValue {
                            case "text_delta":
                                if let t = d["text"]?.stringValue { continuation.yield(.textDelta(t)) }
                            case "thinking_delta":
                                if let t = d["thinking"]?.stringValue { continuation.yield(.thinkingDelta(t)) }
                            case "input_json_delta":
                                if let p = d["partial_json"]?.stringValue { toolJSON[idx]?.append(p) }
                            default: break
                            }

                        case "content_block_stop":
                            let idx = Int(obj["index"]?.stringValue ?? "") ?? 0
                            if let id = toolID[idx], let name = toolName[idx] {
                                let input = toolJSON[idx]?.finish() ?? .object([:])
                                continuation.yield(.toolUseCompleted(id: id, name: name, input: input))
                                toolID[idx] = nil; toolName[idx] = nil; toolJSON[idx] = nil
                            }

                        case "message_delta":
                            if let u = obj["usage"]?.objectValue {
                                continuation.yield(.usage(
                                    input: u["input_tokens"].flatMap { Int($0.stringValue ?? "") },
                                    output: u["output_tokens"].flatMap { Int($0.stringValue ?? "") }))
                            }
                            if let reason = obj["delta"]?["stop_reason"]?.stringValue {
                                continuation.yield(.stopped(reason: reason))
                            }

                        case "message_stop":
                            return false

                        case "error":
                            throw LLMError.transport(obj["error"]?["message"]?.stringValue ?? ev.data)

                        default: break
                        }
                        return true
                    }

                    var acc = SSEAccumulator()
                    for try await line in bytes.sseLines() {
                        guard let ev = acc.feed(line) else { continue }
                        if try !handle(ev) { continuation.finish(); return }
                    }
                    if let ev = acc.flush() { _ = try handle(ev) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Exact token count

    func countTokens(messages: [Message], system: String, config: LLMConfig, apiKey: String) async -> Int? {
        guard let base = config.endpointURL?.deletingLastPathComponent()
            .appendingPathComponent("messages/count_tokens") else { return nil }
        var b: [String: Any] = ["model": config.model, "messages": wireMessages(messages)]
        if !system.isEmpty { b["system"] = [["type": "text", "text": system]] }
        guard let req = try? request(config, apiKey: apiKey, url: base, body: b),
              let (data, resp) = try? await Net.session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = JSONValue.decode(data)?.objectValue,
              let n = obj["input_tokens"]?.stringValue
        else { return nil }
        return Int(n)
    }
}

extension JSONValue {
    /// Bridge to the `Any` tree `JSONSerialization` expects.
    var anyValue: Any {
        switch self {
        case .null:          return NSNull()
        case .bool(let b):   return b
        case .number(let d): return d == d.rounded() && abs(d) < 9e15 ? Int(d) : d
        case .string(let s): return s
        case .array(let a):  return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }
}
