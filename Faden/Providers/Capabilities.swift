import SwiftUI

/// What a model can do, as far as it is known.
///
/// Three questions with three answers each: yes, no, and **unchecked**. The third is no
/// pedantry but the most common case and the most dangerous. A provider's model list
/// regularly says nothing about a capability rather than denying it — and whoever reads
/// silence as no hides a feature that is there; whoever reads it as yes offers one that
/// falls apart with HTTP 400 on the first attempt.
///
/// Measured rather than believed, where it is cheap: `z-ai/glm-5.3` carries no field for
/// images at all in this provider's list — neither true nor false — and to an image it
/// answers “Model only supports text input”. The same model with `-flash` in the name
/// sees the picture. So the list alone cannot be relied on.
struct Capabilities: Codable, Equatable, Hashable, Sendable {
    var vision: Bool?
    var tools: Bool?
    var reasoning: Bool?

    init(vision: Bool? = nil, tools: Bool? = nil, reasoning: Bool? = nil) {
        self.vision = vision
        self.tools = tools
        self.reasoning = reasoning
    }

    var isEmpty: Bool { vision == nil && tools == nil && reasoning == nil }

    /// What the provider claims, overridden by what was measured.
    ///
    /// The measurement always wins when there is one. It really asked the model; the
    /// list repeats what somebody once entered.
    func overridden(by measured: Capabilities) -> Capabilities {
        Capabilities(vision: measured.vision ?? vision,
                     tools: measured.tools ?? tools,
                     reasoning: measured.reasoning ?? reasoning)
    }
}

/// The badges under a model name.
///
/// Only what applies gets a badge. A row reading “Vision ✗ · Functions ✓” reads like an
/// inspection report; three words that each stand on their own are read in passing. What
/// is missing is missing — and the difference between “cannot do it” and “we do not
/// know” belongs in the text beside it, not in a struck-through badge.
struct CapabilityBadges: View {
    let capabilities: Capabilities

    var body: some View {
        if !shown.isEmpty {
            HStack(spacing: 6) {
                ForEach(shown, id: \.label) { badge in
                    HStack(spacing: 4) {
                        Image(systemName: badge.icon)
                            .font(.eh(9.5, .caption2, weight: .semibold))
                        Text(badge.label)
                            .font(.eh(11, .caption, weight: .medium))
                    }
                    .foregroundStyle(EH.slate)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(EH.surfaceSunk))
                }
            }
        }
    }

    private var shown: [(icon: String, label: String)] {
        var out: [(String, String)] = []
        if capabilities.vision == true { out.append(("photo", "Vision")) }
        if capabilities.tools == true {
            out.append(("chevron.left.forwardslash.chevron.right", "Functions"))
        }
        if capabilities.reasoning == true { out.append(("bolt", "Reasoning")) }
        return out.map { (icon: $0.0, label: $0.1) }
    }
}
