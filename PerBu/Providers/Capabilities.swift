import SwiftUI

/// Was ein Modell kann, soweit man es weiss.
///
/// Drei Fragen mit je drei Antworten: ja, nein, und **ungeprüft**. Das dritte ist
/// keine Spitzfindigkeit, sondern der häufigste Fall und der gefährlichste. Die
/// Modellliste eines Anbieters schweigt regelmässig zu einer Fähigkeit, statt sie zu
/// verneinen — und wer Schweigen als Nein liest, versteckt eine Funktion, die da
/// wäre; wer es als Ja liest, bietet eine an, die beim ersten Versuch mit HTTP 400
/// auseinanderfliegt.
///
/// Gemessen statt geglaubt, wo es billig ist: `z-ai/glm-5.3` führt in der Liste
/// dieses Anbieters gar kein Feld für Bilder — weder wahr noch falsch —, und auf ein
/// Bild antwortet es „Model only supports text input". Dasselbe Modell mit `-flash`
/// am Namen sieht das Bild. Auf die Liste allein ist also kein Verlass.
struct Capabilities: Equatable, Hashable, Sendable {
    var vision: Bool?
    var tools: Bool?
    var reasoning: Bool?

    init(vision: Bool? = nil, tools: Bool? = nil, reasoning: Bool? = nil) {
        self.vision = vision
        self.tools = tools
        self.reasoning = reasoning
    }

    var isEmpty: Bool { vision == nil && tools == nil && reasoning == nil }

    /// Was der Anbieter behauptet, überschrieben von dem, was gemessen wurde.
    ///
    /// Die Messung gewinnt immer, wenn es eine gibt. Sie hat das Modell wirklich
    /// gefragt; die Liste gibt wieder, was jemand einmal eingetragen hat.
    func overridden(by measured: Capabilities) -> Capabilities {
        Capabilities(vision: measured.vision ?? vision,
                     tools: measured.tools ?? tools,
                     reasoning: measured.reasoning ?? reasoning)
    }
}

/// Die Marken unter einem Modellnamen.
///
/// Nur was zutrifft, bekommt eine Marke. Eine Reihe aus „Vision ✗ · Functions ✓"
/// liest sich als Prüfbericht; drei Wörter, von denen jedes für sich steht, liest man
/// im Vorbeigehen. Was fehlt, fehlt — und der Unterschied zwischen „kann es nicht"
/// und „wissen wir nicht" gehört in den Text daneben, nicht in eine durchgestrichene
/// Marke.
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
