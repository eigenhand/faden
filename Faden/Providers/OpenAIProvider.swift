import Foundation

/// Talks the OpenAI chat-completions shape — which is what almost every other
/// endpoint speaks: Groq, Together, OpenRouter, Mistral, Ollama, vLLM, LM Studio.
struct OpenAIProvider: LLMProvider {

    // MARK: Request assembly

    private func wireMessages(_ messages: [Message], system: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if !system.isEmpty { out.append(["role": "system", "content": system]) }

        for m in messages.pairingToolCallsAndResults() where m.role != .system {
            switch m.role {
            case .user:
                // Tool results are their own `role: "tool"` messages here.
                var textParts: [String] = []
                var images: [[String: Any]] = []
                for b in m.blocks {
                    switch b {
                    case .toolResult(let id, let content, _):
                        out.append(["role": "tool", "tool_call_id": id, "content": content])
                    case .text(let t):
                        if !t.isEmpty { textParts.append(t) }
                    case .image(let data, let mediaType):
                        images.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(mediaType);base64,\(data)"],
                        ])
                    default: break
                    }
                }
                if !images.isEmpty {
                    // With images the content becomes an array of parts; text-only
                    // messages keep the plain-string form, which every endpoint takes.
                    var parts: [[String: Any]] = images
                    if !textParts.isEmpty {
                        parts.append(["type": "text", "text": textParts.joined(separator: "\n")])
                    }
                    out.append(["role": "user", "content": parts])
                } else if !textParts.isEmpty {
                    out.append(["role": "user", "content": textParts.joined(separator: "\n")])
                }

            case .assistant:
                var text = ""
                var calls: [[String: Any]] = []
                for b in m.blocks {
                    switch b {
                    case .text(let t): text += t
                    case .toolUse(let id, let name, let input):
                        let args = (try? JSONSerialization.data(withJSONObject: input.anyValue))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        calls.append(["id": id, "type": "function",
                                      "function": ["name": name, "arguments": args]])
                    default: break
                    }
                }
                var msg: [String: Any] = ["role": "assistant"]
                msg["content"] = text.isEmpty ? NSNull() : text
                if !calls.isEmpty { msg["tool_calls"] = calls }
                if !text.isEmpty || !calls.isEmpty { out.append(msg) }

            case .system:
                break
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
            "messages": wireMessages(messages, system: system),
            "max_tokens": maxTokens,
        ]
        if config.temperature != 1.0 { b["temperature"] = config.temperature }
        if !tools.isEmpty {
            b["tools"] = tools.map { t in
                ["type": "function",
                 "function": ["name": t.name, "description": t.description,
                              "parameters": t.inputSchema.anyValue]]
            }
            b["tool_choice"] = "auto"
        }
        if stream {
            b["stream"] = true
            b["stream_options"] = ["include_usage": true]
        }
        return b
    }

    private func request(_ config: LLMConfig, apiKey: String, url: URL, body: [String: Any]) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        if !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
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
                    let bytes = try await Backoff.open {
                        try request(config, apiKey: apiKey, url: url,
                                    body: body(messages: messages, system: system, tools: tools,
                                               config: config, stream: true,
                                               maxTokens: config.maxOutputTokens))
                    }

                    // tool_calls arrive as indexed fragments that must be stitched together.
                    var callID: [Int: String] = [:]
                    var callName: [Int: String] = [:]
                    var callArgs: [Int: PartialJSONAccumulator] = [:]
                    var announced: Set<Int> = []
                    /// Slot that continuation chunks belong to when they carry no index.
                    var currentSlot = 0

                    func flushCalls() {
                        for (idx, id) in callID.sorted(by: { $0.key < $1.key }) {
                            let name = callName[idx] ?? ""
                            guard !name.isEmpty else { continue }
                            continuation.yield(.toolUseCompleted(
                                id: id, name: name, input: callArgs[idx]?.finish() ?? .object([:])))
                        }
                        callID.removeAll(); callName.removeAll(); callArgs.removeAll(); announced.removeAll()
                        currentSlot = 0
                    }

                    /// Handles one SSE record. Returns false when the stream is finished.
                    func handle(_ ev: SSEEvent) throws -> Bool {
                        if ev.data == "[DONE]" { return false }
                        guard let data = ev.data.data(using: .utf8),
                              let obj = JSONValue.decode(data)?.objectValue else { return true }

                        if let err = obj["error"] {
                            throw LLMError.transport(err["message"]?.stringValue ?? err.compactDescription)
                        }
                        if let u = obj["usage"]?.objectValue {
                            continuation.yield(.usage(
                                input: u["prompt_tokens"].flatMap { Int($0.stringValue ?? "") },
                                output: u["completion_tokens"].flatMap { Int($0.stringValue ?? "") }))
                        }
                        guard let choice = obj["choices"]?.arrayValue?.first?.objectValue else { return true }
                        let delta = choice["delta"]?.objectValue ?? [:]

                        if let c = delta["content"]?.stringValue, !c.isEmpty {
                            continuation.yield(.textDelta(c))
                        }
                        // Several providers expose chain-of-thought under this key.
                        if let r = delta["reasoning_content"]?.stringValue ?? delta["reasoning"]?.stringValue,
                           !r.isEmpty {
                            continuation.yield(.thinkingDelta(r))
                        }

                        if let tcs = delta["tool_calls"]?.arrayValue {
                            for tc in tcs {
                                // `index` is the documented key, but providers are not
                                // consistent about repeating it on continuation chunks.
                                // A fresh `id` always means a new call, so that starts a
                                // slot; anything without an index continues the last one.
                                var idx: Int
                                if let raw = tc["index"]?.stringValue, let n = Int(raw) {
                                    idx = n
                                } else {
                                    idx = currentSlot
                                }
                                if let id = tc["id"]?.stringValue, !id.isEmpty,
                                   let existing = callID[idx], existing != id {
                                    // Same index reused for a different call: give it
                                    // its own slot rather than merging the arguments.
                                    idx = (callID.keys.max() ?? idx) + 1
                                }
                                currentSlot = idx
                                if let id = tc["id"]?.stringValue, !id.isEmpty { callID[idx] = id }
                                if let n = tc["function"]?["name"]?.stringValue, !n.isEmpty {
                                    // The name may arrive in pieces, or — as some
                                    // providers do — complete in every chunk. Blind
                                    // concatenation then yields "web_searchweb_search"
                                    // and every call fails as an unknown tool.
                                    let existing = callName[idx] ?? ""
                                    if existing.isEmpty || n.hasPrefix(existing) {
                                        callName[idx] = n
                                    } else if !existing.hasSuffix(n), !existing.contains(n) {
                                        callName[idx] = existing + n
                                    }
                                }
                                if let a = tc["function"]?["arguments"]?.stringValue {
                                    callArgs[idx, default: PartialJSONAccumulator()].append(a)
                                }
                                if let id = callID[idx], let n = callName[idx],
                                   !n.isEmpty, !announced.contains(idx) {
                                    announced.insert(idx)
                                    continuation.yield(.toolUseStarted(id: id, name: n))
                                }
                            }
                        }

                        if let reason = choice["finish_reason"]?.stringValue {
                            flushCalls()
                            continuation.yield(.stopped(reason: reason))
                        }
                        return true
                    }

                    var acc = SSEAccumulator()
                    for try await line in bytes.sseLines() {
                        guard let ev = acc.feed(line) else { continue }
                        if try !handle(ev) { flushCalls(); continuation.finish(); return }
                    }
                    if let ev = acc.flush() { _ = try handle(ev) }
                    flushCalls()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
