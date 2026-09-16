import XCTest
@testable import Faden

/// Die Antwortlänge, die aus der Nutzung wächst.
///
/// Der Anlass war ein Fehler, den niemand als Fehler sah: Ein Denkmodell an einer
/// schweren Aufgabe brauchte mehr als die voreingestellten 4 096 Token, brauchte sie
/// im Nachdenken auf, und der Zug endete. Ohne Fehlermeldung — die App hat einen Zug
/// aus lauter Gedankengang als fertige Antwort verbucht. Für den Leser hörte das
/// Denken mitten im Satz auf.
final class OutputBudgetTests: XCTestCase {

    // MARK: Erkennen

    /// Der Anbieter sagt es, wenn er kann.
    func testAStatedReasonIsEnough() {
        for reason in ["max_tokens", "length"] {
            XCTAssertTrue(AgentRunner.ranOutOfRoom(stopReason: reason, text: "etwas",
                                                   thinking: "", toolCalls: 0),
                          "»\(reason)« heißt abgeschnitten, egal was sonst ankam.")
        }
    }

    /// Der Fall, um den es geht, und den bisher niemand bemerkt hat: Der Anbieter
    /// sagt nichts, und zurück kommt ein Zug, der nur aus Nachdenken besteht.
    func testOnlyThinkingAndNothingElseCountsAsRunOut() {
        XCTAssertTrue(AgentRunner.ranOutOfRoom(stopReason: nil, text: "",
                                               thinking: "lange nachgedacht …", toolCalls: 0))
        XCTAssertTrue(AgentRunner.ranOutOfRoom(stopReason: "end_turn", text: "   \n ",
                                               thinking: "lange nachgedacht …", toolCalls: 0))
    }

    /// Ein Zug mit Werkzeugaufruf hat oft keinen Text, und das ist der Normalfall
    /// einer Runde, in der das Modell erst etwas nachsehen will. Zählte er mit, würde
    /// jede Suche die Antwortlänge verdoppeln.
    func testATurnThatCallsAToolIsNotOutOfRoom() {
        XCTAssertFalse(AgentRunner.ranOutOfRoom(stopReason: nil, text: "",
                                                thinking: "kurz überlegt", toolCalls: 1))
    }

    func testAnOrdinaryAnswerIsNotOutOfRoom() {
        XCTAssertFalse(AgentRunner.ranOutOfRoom(stopReason: "end_turn", text: "Die Antwort.",
                                                thinking: "", toolCalls: 0))
        XCTAssertFalse(AgentRunner.ranOutOfRoom(stopReason: nil, text: "Die Antwort.",
                                                thinking: "überlegt", toolCalls: 0))
    }

    /// Ein leerer Zug ohne alles ist ein anderer Fehler — dafür gibt es eine eigene
    /// Meldung, und mehr Vorrat hilft dagegen nicht.
    func testAnEmptyTurnIsNotARoomProblem() {
        XCTAssertFalse(AgentRunner.ranOutOfRoom(stopReason: nil, text: "",
                                                thinking: "", toolCalls: 0))
    }

    // MARK: Wachsen

    func testItDoubles() {
        XCTAssertEqual(AgentRunner.nextOutputBudget(after: 4_096, ceiling: nil), 8_192)
        XCTAssertEqual(AgentRunner.nextOutputBudget(after: 8_192, ceiling: nil), 16_384)
    }

    /// Die genannte Grenze des Anbieters ist die Grenze — und sie wird getroffen,
    /// nicht übersprungen. Verdoppeln von 4 000 bei einer Grenze von 6 000 ergibt
    /// 6 000 und nicht 8 000.
    func testAReportedLimitIsMetExactly() {
        XCTAssertEqual(AgentRunner.nextOutputBudget(after: 4_000, ceiling: 6_000), 6_000)
    }

    /// Steht der Regler schon auf der Grenze, gibt es nichts mehr zu holen. Dann ist
    /// die Aufgabe zu groß für dieses Modell, und ein weiterer Versuch kostet nur
    /// noch einmal die ganze Anfrage.
    func testAtTheLimitThereIsNoNextStep() {
        XCTAssertNil(AgentRunner.nextOutputBudget(after: 6_000, ceiling: 6_000))
        XCTAssertNil(AgentRunner.nextOutputBudget(after: 9_000, ceiling: 6_000))
    }

    /// Ohne genannte Grenze trägt die letzte Schranke. Sie ist da, damit das
    /// Verdoppeln nicht ins Absurde läuft — die App probiert keine Grenzen mehr aus.
    func testWithoutAReportedLimitTheLastFloorHolds() {
        XCTAssertEqual(AgentRunner.nextOutputBudget(after: AgentRunner.outputCeiling / 2,
                                                    ceiling: nil),
                       AgentRunner.outputCeiling)
        XCTAssertNil(AgentRunner.nextOutputBudget(after: AgentRunner.outputCeiling, ceiling: nil))
    }

    /// Drei Verdopplungen in einer Runde, aus 4 096 also höchstens 32 768. Jede
    /// kostet die ganze Anfrage noch einmal.
    func testThreeGrowthsReachThirtyTwoThousand() {
        var budget = 4_096
        for _ in 0..<AgentRunner.maxGrowths {
            budget = AgentRunner.nextOutputBudget(after: budget, ceiling: nil) ?? budget
        }
        XCTAssertEqual(budget, 32_768)
    }

    // MARK: Wer die Zahl gesetzt hat

    func testAFreshConfigGrowsByItself() {
        XCTAssertFalse(LLMConfig().maxOutputTokensIsCustom)
    }

    /// Eine Einstellung von vor dieser Funktion weiß nicht, ob jemand die Zahl
    /// angefasst hat. Steht dort noch die Vorgabe, hat es niemand getan.
    func testAnOlderSettingsFileIsReadByItsValue() throws {
        let untouched = Data(#"{"maxOutputTokens":4096}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(LLMConfig.self, from: untouched)
            .maxOutputTokensIsCustom, "Die Vorgabe hat niemand gesetzt.")

        let changed = Data(#"{"maxOutputTokens":12000}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(LLMConfig.self, from: changed)
            .maxOutputTokensIsCustom, "Eine andere Zahl hat jemand gewollt.")
    }

    func testTheFlagSurvivesADecodingRound() throws {
        var c = LLMConfig()
        c.maxOutputTokens = 4_096          // die Vorgabe, aber bewusst gesetzt
        c.maxOutputTokensIsCustom = true
        let back = try JSONDecoder().decode(LLMConfig.self, from: JSONEncoder().encode(c))
        XCTAssertTrue(back.maxOutputTokensIsCustom,
                      "Das ausdrückliche Kennzeichen sticht die Vermutung aus dem Wert.")
    }
}

// MARK: - Noch einmal fragen oder nicht

extension OutputBudgetTests {

    /// Der Fall, für den die Funktion da ist: nur Gedankengang, kein Text.
    func testWithNothingOnScreenTheTurnStartsOver() {
        XCTAssertTrue(AgentRunner.shouldAskAgain(text: "", toolCalls: 0, alreadyGrew: 0))
        XCTAssertTrue(AgentRunner.shouldAskAgain(text: "  \n ", toolCalls: 0, alreadyGrew: 0))
    }

    /// Steht schon Text da, wäre ein neuer Anlauf ein Rückschritt: Der Leser sähe
    /// seine halbe Antwort verschwinden und wartete von vorn. Die Antwortlänge wächst
    /// trotzdem — nur eben für den nächsten Zug.
    func testHalfAnAnswerIsWorthMoreThanAFreshStart() {
        XCTAssertFalse(AgentRunner.shouldAskAgain(text: "Die Antwort beginnt …",
                                                  toolCalls: 0, alreadyGrew: 0))
    }

    func testATurnWithToolCallsIsNeverRestarted() {
        XCTAssertFalse(AgentRunner.shouldAskAgain(text: "", toolCalls: 1, alreadyGrew: 0))
    }

    /// Jeder Anlauf kostet die ganze Anfrage noch einmal — der Verlauf geht jedes Mal
    /// mit. Deshalb eine Grenze und nicht „so lange, bis es passt".
    func testAfterThreeTriesItStops() {
        XCTAssertTrue(AgentRunner.shouldAskAgain(text: "", toolCalls: 0,
                                                 alreadyGrew: AgentRunner.maxGrowths - 1))
        XCTAssertFalse(AgentRunner.shouldAskAgain(text: "", toolCalls: 0,
                                                  alreadyGrew: AgentRunner.maxGrowths))
    }
}
