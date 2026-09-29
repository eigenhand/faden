import Foundation

/// How the assistant speaks.
///
/// Reviews of brand identity in conversational agents converge on two levers: the
/// verbal cues (tone of voice, output style, formality) and the visual ones. Engagement
/// rises with *personality compatibility* — the fit between the person and the voice
/// answering them — which in a bring-your-own-key app makes the user the brand owner.
/// So this is theirs to set, not something baked into the prompt.
///
/// Deliberately part of the *stable* prompt: unlike the clock or recalled memories,
/// this changes only when someone changes it, so it can sit in the cached prefix.
struct Persona: Codable, Equatable {

    enum Address: String, Codable, CaseIterable, Identifiable {
        case informal, formal
        var id: String { rawValue }
        var label: String { self == .informal ? String(localized: "Du") : String(localized: "Sie") }
    }

    enum Length: String, Codable, CaseIterable, Identifiable {
        case terse, balanced, thorough
        var id: String { rawValue }
        var label: String {
            switch self {
            case .terse:    return String(localized: "Knapp")
            case .balanced: return String(localized: "Ausgewogen")
            case .thorough: return String(localized: "Ausführlich")
            }
        }
    }

    enum Tone: String, Codable, CaseIterable, Identifiable {
        case plain, warm, dry
        var id: String { rawValue }
        var label: String {
            switch self {
            case .plain: return String(localized: "Sachlich")
            case .warm:  return String(localized: "Zugewandt")
            case .dry:   return String(localized: "Trocken")
            }
        }
    }

    var address: Address = .informal
    var length: Length = .balanced
    var tone: Tone = .plain
    /// Anything the presets do not cover — the escape hatch that keeps the presets
    /// from having to anticipate everyone.
    var custom: String = ""
    /// What the assistant is called. Empty means the app's own name.
    var name: String = ""

    var displayName: String { name.isEmpty ? "Faden" : name }

    /// The paragraph that goes into the system prompt.
    var instructions: String {
        var lines: [String] = []

        switch address {
        case .informal: lines.append("Du duzt den Nutzer.")
        case .formal:   lines.append("Du siezt den Nutzer.")
        }

        switch length {
        case .terse:
            lines.append("Fasse dich so kurz wie möglich. Eine Frage, eine Antwort — "
                         + "keine Einleitung, keine Zusammenfassung am Ende.")
        case .balanced:
            lines.append("So lang wie nötig, so kurz wie möglich. Eine einfache Frage "
                         + "bekommt einen Satz, keine Liste mit Überschriften.")
        case .thorough:
            lines.append("Geh in die Tiefe. Nenne Hintergründe, Randfälle und "
                         + "Gegenargumente, wo sie zur Sache gehören.")
        }

        switch tone {
        case .plain: lines.append("Dein Ton ist sachlich und klar.")
        case .warm:  lines.append("Dein Ton ist zugewandt und freundlich, ohne anbiedernd zu werden.")
        case .dry:   lines.append("Dein Ton ist trocken und nüchtern, gelegentlich lakonisch.")
        }

        let extra = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { lines.append(extra) }
        return lines.joined(separator: " ")
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Persona()
        address = try c.decodeIfPresent(Address.self, forKey: .address) ?? d.address
        length  = try c.decodeIfPresent(Length.self, forKey: .length) ?? d.length
        tone    = try c.decodeIfPresent(Tone.self, forKey: .tone) ?? d.tone
        custom  = try c.decodeIfPresent(String.self, forKey: .custom) ?? ""
        name    = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}
