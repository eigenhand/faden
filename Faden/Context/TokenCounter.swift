import Foundation

/// Token accounting for the bar at the bottom of the screen and for the compaction
/// trigger. Estimates locally, then corrects itself whenever a provider reports what
/// a request actually cost — so the bar converges on the truth after the first turn.
struct TokenCounter {

    /// Rough but stable estimate. Latin text lands near four characters per token;
    /// code, markup and JSON run denser, so structural characters are surcharged.
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let chars = text.count
        let structural = text.reduce(into: 0) { acc, c in
            if "{}[]()<>/\\\"'`|=_*#".contains(c) { acc += 1 }
        }
        let base = Double(chars) / 4.0
        let surcharge = Double(structural) * 0.25
        return max(1, Int((base + surcharge).rounded()))
    }

    static func estimate(_ message: Message) -> Int {
        // Every message carries role and delimiter overhead on the wire.
        var n = 8
        for b in message.blocks {
            switch b {
            case .text(let t):                     n += estimate(t)
            case .thinking(let t):                 n += estimate(t)
            case .image(let data, _):
                // Both vendors bill roughly by pixel area; base64 length is a decent
                // proxy for it and keeps the bar honest once a photo is attached.
                n += max(200, data.count / 750)
            case .toolUse(_, let name, let input): n += estimate(name) + estimate(input.compactDescription) + 12
            case .toolResult(_, let c, _):         n += estimate(c) + 12
            }
        }
        return n
    }

    static func estimate(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + estimate($1) }
    }

    /// What the next request will cost: system prompt + tool schemas + history.
    static func projectedInput(messages: [Message], system: String, tools: [ToolSpec]) -> Int {
        let toolCost = tools.reduce(0) {
            $0 + estimate($1.description) + estimate($1.inputSchema.compactDescription) + 20
        }
        return estimate(system) + toolCost + estimate(messages)
    }
}

/// The state the bar renders.
struct ContextUsage: Equatable {
    var used: Int = 0
    var window: Int = 200_000
    /// True while a compaction is running in the background.
    var compacting: Bool = false
    /// True once the numbers come from the provider rather than the estimator.
    var measured: Bool = false

    var fraction: Double {
        guard window > 0 else { return 0 }
        return min(1.0, Double(used) / Double(window))
    }
    var percent: Int { Int((fraction * 100).rounded()) }
    var remaining: Int { max(0, window - used) }
}
