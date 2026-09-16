import Foundation

/// Was aus einer fremden Datei in den eigenen Verlauf darf.
///
/// Eine geteilte Unterhaltung ist bequem und harmlos, solange man sie liest. Sie wird
/// etwas anderes, sobald man in ihr weiterschreibt: ab dann geht sie bei jeder
/// Anfrage als Vorgeschichte mit, und was darin als *Assistentenzug* steht, liest das
/// Modell als seine eigene frühere Ausgabe. Kein Sprachmodell wiegt beides gleich —
/// die eigene Vorgeschichte wiegt schwerer als jede Bitte des Nutzers.
///
/// Drei Dinge werden deshalb beim Hereinnehmen entfernt, und jedes hat einen
/// konkreten Anlass:
///
///  - **Gedankengänge.** Sie sind in der Oberfläche eingeklappt und werden von keinem
///    Anbieter zurückgeschickt — sie sind also unsichtbar *und* wirkungslos, wenn sie
///    echt sind. Ein gefälschter wäre das Gegenteil: die überzeugendste Stimme im
///    ganzen Verlauf, weil sie klingt wie das Modell mit sich selbst. Etwas, das nur
///    schaden kann, lässt man draussen.
///  - **Das Kennzeichen „Zusammenfassung".** In der Systemanweisung steht wörtlich:
///    erscheint im Verlauf eine Zusammenfassung, ist sie massgeblich. Genau dieses
///    Kennzeichen kann eine Datei setzen. Eine fremde Datei darf ihren Inhalt nicht
///    selbst für massgeblich erklären.
///  - **Werkzeugaufrufe ohne Ergebnis und Ergebnisse ohne Aufruf.** Das ist weniger
///    Angriff als Defekt, und ein teurer: Anbieter lehnen einen Verlauf mit einem
///    unbeantworteten Aufruf ab — *jede* weitere Anfrage in dieser Unterhaltung, denn
///    der Verlauf geht jedes Mal mit. Eine Datei könnte also eine Unterhaltung
///    erzeugen, in der man nie wieder etwas senden kann.
///
/// Dazu zwei Obergrenzen. Eine Datei aus fremder Hand bestimmt sonst, wie viel
/// Speicher die App belegt und wie gross der Kontext beim nächsten Zug ist — und
/// Kontext ist bezahlt.
enum ImportGuard {

    /// So gross darf die Datei sein. Ein Bild macht aus sechs Nachrichten schon
    /// 340 000 Zeichen; acht Megabyte fassen damit jede Unterhaltung, die jemand
    /// wirklich weiterreicht, und keine, die als Waffe gemeint ist.
    static let maxBytes = 8 * 1024 * 1024
    /// So viele Nachrichten. Behalten wird das **Ende**: dort steht, woran jemand
    /// weiterschreiben will.
    static let maxMessages = 2_000
    static let maxBlocksPerMessage = 200

    struct Outcome {
        var conversation: Conversation
        /// Was entfernt wurde, in einem Satz für den Nutzer — oder leer.
        var note: String?
    }

    static func sanitised(_ incoming: Conversation) -> Outcome {
        var c = incoming
        var droppedThinking = 0
        var droppedSummaries = 0
        var droppedToolBlocks = 0
        var droppedMessages = 0

        if c.messages.count > maxMessages {
            droppedMessages = c.messages.count - maxMessages
            c.messages = Array(c.messages.suffix(maxMessages))
        }

        // Welche Werkzeugaufrufe im Verlauf beantwortet werden, und umgekehrt.
        var answeredCalls: Set<String> = []
        var presentCalls: Set<String> = []
        for m in c.messages {
            for b in m.blocks {
                if case .toolUse(let id, _, _) = b { presentCalls.insert(id) }
                if case .toolResult(let id, _, _) = b { answeredCalls.insert(id) }
            }
        }

        c.messages = c.messages.compactMap { message in
            var m = message
            if m.isCompactionSummary { droppedSummaries += 1 }
            m.isCompactionSummary = false
            m.replacedMessageCount = 0

            var kept: [ContentBlock] = []
            for block in m.blocks.prefix(maxBlocksPerMessage) {
                switch block {
                case .thinking:
                    droppedThinking += 1
                case .toolUse(let id, _, _):
                    if answeredCalls.contains(id) { kept.append(block) } else { droppedToolBlocks += 1 }
                case .toolResult(let id, _, _):
                    if presentCalls.contains(id) { kept.append(block) } else { droppedToolBlocks += 1 }
                case .text, .image:
                    kept.append(block)
                }
            }
            if m.blocks.count > maxBlocksPerMessage {
                droppedToolBlocks += m.blocks.count - maxBlocksPerMessage
            }
            m.blocks = kept
            // Eine Nachricht ohne Inhalt ist keine. Sie stehenzulassen hiesse, dem
            // Anbieter eine leere Rolle zu schicken, und manche lehnen das ab.
            return kept.isEmpty ? nil : m
        }

        var parts: [String] = []
        if droppedMessages > 0 { parts.append("\(droppedMessages) ältere Nachrichten") }
        if droppedThinking > 0 { parts.append("\(droppedThinking) Gedankengänge") }
        if droppedSummaries > 0 { parts.append("\(droppedSummaries) als „Zusammenfassung“ markierte Züge") }
        if droppedToolBlocks > 0 { parts.append("\(droppedToolBlocks) unvollständige Werkzeugschritte") }

        return Outcome(conversation: c,
                       note: parts.isEmpty ? nil
                           : "Beim Übernehmen entfernt: " + parts.joined(separator: ", ") + ".")
    }
}
