import Foundation
import NaturalLanguage

/// Einbettungen auf dem Gerät, mit Apples `NLContextualEmbedding`.
///
/// Der Grund dafür ist nicht Geschwindigkeit, obwohl sie da ist: 8 ms je Satz gegen
/// gut acht Sekunden für eine ganze Aufnahme über das Netz. Der Grund ist, dass
/// Erinnerungen der persönlichste Text in dieser App sind und zum Einbetten bisher
/// über die Leitung mussten — und dass ein Gedächtnis ohne Einbettungs-Endpoint
/// überhaupt nicht lief. Wer bei einem kleinen Anbieter nur ein Chat-Modell hat,
/// bekam gar keines.
///
/// Der Preis steht in denselben Messungen. Auf neun Fragen gegen vierzehn deutsche
/// Erinnerungen traf das Netzmodell (qwen3-embedding-8b, 4096 Dimensionen) siebenmal
/// auf Platz eins, dieses hier fünfmal; im Mittel steht die richtige Erinnerung dort
/// auf Rang 1,44, hier auf 4,33. Und das Modell wiegt 108 MB, während die ganze App
/// 3,3 MB wiegt. Deshalb ist das hier eine Wahl und keine Voreinstellung.
actor LocalEmbedder {
    static let shared = LocalEmbedder()

    /// Der Name, der als Herkunft an jedem Vektor steht.
    ///
    /// Mit Revision, weil Apple das Modell mit einem Systemupdate austauschen kann:
    /// dieselbe Kennung für zwei verschiedene Modelle wäre genau der stille Unsinn,
    /// gegen den der Stempel gebaut wurde.
    static var modelIdentifier: String {
        let revision = NLContextualEmbedding(script: .latin)?.revision ?? 0
        return "apple-nlcontextual-v\(revision)"
    }

    /// Ein Modell für alle lateinischen Schriften, nicht eines je Sprache.
    ///
    /// Ein persönliches Gedächtnis enthält deutsche und englische Sätze
    /// nebeneinander. Zwei Sprachmodelle wären zwei Vektorräume, und damit genau
    /// das Problem, das der Herkunftsstempel verhindern soll. Das lateinische Modell
    /// deckt 20 Sprachen ab; gemessen liegt ein deutscher Satz und seine englische
    /// Entsprechung bei 0,95 zueinander.
    private static func makeModel() -> NLContextualEmbedding? {
        NLContextualEmbedding(script: .latin)
    }

    private var model: NLContextualEmbedding?

    /// True, wenn dieses Gerät das Modell überhaupt kennt.
    nonisolated static var isSupported: Bool { makeModel() != nil }

    /// True, wenn die 108 MB schon auf dem Gerät liegen.
    nonisolated static var hasAssets: Bool { makeModel()?.hasAvailableAssets ?? false }

    /// Lädt die Modelldateien. Kommt sofort zurück, wenn sie schon da sind.
    ///
    /// Mit Zeitgrenze, weil der Aufruf sonst nicht zurückkommt: im Simulator lief er
    /// über sechs Minuten ohne Ergebnis, und `mobileassetd` meldet keinen Fortschritt
    /// und keinen Fehlschlag. Die Zeitgrenze bricht nur das *Warten* ab — der
    /// Download läuft im System weiter, und ob er ankam, sagt allein `hasAssets`.
    /// Deshalb ist das hier auch kein Fehler, sondern eine Auskunft.
    static func requestAssets(timeout: Duration = .seconds(180)) async throws {
        guard let probe = makeModel() else { throw MemoryError.notConfigured("Das lokale Modell") }
        guard !probe.hasAvailableAssets else { return }

        let result: NLContextualEmbedding.AssetsResult? = try await withThrowingTaskGroup(
            of: NLContextualEmbedding.AssetsResult?.self) { group in
            group.addTask {
                // Eigene Instanz statt der von draußen: NLContextualEmbedding ist
                // nicht Sendable, und sie über eine Aufgabengrenze zu reichen wäre
                // genau das Datenrennen, vor dem der Compiler warnt. Das Objekt ist
                // ohnehin nur ein Griff auf dasselbe Systemmodell.
                guard let model = makeModel() else { return nil }
                return try await model.requestAssets()
            }
            group.addTask { try await Task.sleep(for: timeout); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let result else {
            throw MemoryError.embedding(
                "Das System hat noch nicht geantwortet. Der Download läuft unter Umständen "
                + "weiter — beim nächsten Öffnen steht hier, ob er angekommen ist.")
        }
        guard result == .available else {
            throw MemoryError.embedding("Das Modell konnte nicht geladen werden (\(result.rawValue)).")
        }
    }

    private func loaded() throws -> NLContextualEmbedding {
        if let model { return model }
        guard let made = Self.makeModel() else {
            throw MemoryError.notConfigured("Das lokale Modell")
        }
        guard made.hasAvailableAssets else {
            throw MemoryError.embedding("Das lokale Modell ist noch nicht geladen.")
        }
        try made.load()
        model = made
        return made
    }

    /// Gibt den Arbeitsspeicher wieder frei — gemessen 13,5 MB.
    func unload() {
        model?.unload()
        model = nil
    }

    func embed(_ texts: [String]) throws -> [[Float]] {
        let model = try loaded()
        return try texts.map { try vector(for: $0, model: model) }
    }

    /// Der Vektor des ersten Tokens, nicht der Mittelwert über alle.
    ///
    /// Apple nennt in der Kopfzeile vier Verfahren und empfiehlt keines. Gemessen an
    /// denselben neun Fragen: erster Token 5/9, Mittelwert 3/9, Maximum 2/9, letzter
    /// Token 1/9. Also gemessen statt geraten — der Mittelwert wäre die naheliegende
    /// Wahl gewesen und ist die schlechtere.
    private func vector(for text: String, model: NLContextualEmbedding) throws -> [Float] {
        // Ein leerer Text hat keinen ersten Token; ohne diese Zeile käme ein
        // Nullvektor heraus, dessen Kosinus zu allem 0 ist — also ein Treffer, der
        // wie ein Nichttreffer aussieht.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoryError.embedding("Leerer Text.") }

        guard let result = try? model.embeddingResult(for: trimmed, language: nil) else {
            throw MemoryError.embedding("Der Text konnte nicht eingebettet werden.")
        }
        var first: [Double] = []
        result.enumerateTokenVectors(in: trimmed.startIndex ..< trimmed.endIndex) { v, _ in
            first = v
            return false
        }
        guard !first.isEmpty else { throw MemoryError.embedding("Keine Tokenvektoren.") }

        let norm = sqrt(first.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { throw MemoryError.embedding("Nullvektor.") }
        return first.map { Float($0 / norm) }
    }
}
