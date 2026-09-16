import Foundation

struct SSEEvent {
    var event: String?
    var data: String
}

/// Line-by-line reader for server-sent events.
///
/// Deliberately *not* an `AsyncStream`: wrapping the byte stream in a second stream
/// meant the inner reader ran in its own `Task`, which the runtime cancelled as soon
/// as the intermediate stream went out of scope — the iteration then stopped after
/// the first record. Feeding lines into a plain value keeps everything in the caller's
/// own task, where cancellation means what it should.
struct SSEAccumulator {
    private var currentEvent: String?
    private var buffer: [String] = []

    /// Feeds one line. Returns an event whenever a record is complete.
    mutating func feed(_ line: String) -> SSEEvent? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }                    // comment / keep-alive
        if line.hasPrefix("event:") {
            currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            var d = String(line.dropFirst(5))
            if d.hasPrefix(" ") { d.removeFirst() }
            buffer.append(d)
            return nil
        }
        return nil
    }

    /// Emits whatever is pending — call once after the byte stream ends.
    mutating func flush() -> SSEEvent? {
        defer { buffer.removeAll(); currentEvent = nil }
        guard !buffer.isEmpty else { return nil }
        return SSEEvent(event: currentEvent, data: buffer.joined(separator: "\n"))
    }
}

extension URLSession.AsyncBytes {
    /// Splits the byte stream on newlines, **keeping empty lines**.
    ///
    /// Foundation's own `.lines` collapses runs of newlines, which silently destroys
    /// SSE record boundaries — the blank line *is* the delimiter, so every record ran
    /// together into one buffer and nothing ever parsed.
    func sseLines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buf = [UInt8]()
                buf.reserveCapacity(4096)
                do {
                    for try await byte in self {
                        if byte == 0x0A {                        // \n
                            if buf.last == 0x0D { buf.removeLast() }   // \r\n
                            continuation.yield(String(decoding: buf, as: UTF8.self))
                            buf.removeAll(keepingCapacity: true)
                        } else {
                            buf.append(byte)
                        }
                    }
                    if !buf.isEmpty {
                        continuation.yield(String(decoding: buf, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Accumulates the partial-JSON fragments a provider streams for a tool call.
struct PartialJSONAccumulator {
    private var raw = ""
    mutating func append(_ s: String) { raw += s }
    var text: String { raw }
    func finish() -> JSONValue {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .object([:]) }
        if let data = t.data(using: .utf8), let v = JSONValue.decode(data) { return v }

        // Fallback: if two calls' arguments ended up in one buffer ("{…}{…}"),
        // decoding the whole thing fails and the tool would be invoked with nothing.
        // Taking the first complete object at least keeps one call working.
        if let first = Self.firstObject(in: t),
           let data = first.data(using: .utf8),
           let v = JSONValue.decode(data) {
            return v
        }
        return .object([:])
    }

    /// Extracts the first balanced `{…}` from a string, ignoring braces in strings.
    private static func firstObject(in s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { inString.toggle() }
            else if !inString {
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(s[start...i]) }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
