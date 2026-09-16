import XCTest
@testable import Faden

/// The answer length that grows out of use.
///
/// The occasion was a bug nobody saw as a bug: a reasoning model on a hard task needed
/// more than the preset 4,096 tokens, spent them on thinking, and the turn ended. With
/// no error message — the app booked a turn made of nothing but reasoning as a finished
/// answer. To the reader the thinking stopped mid-sentence.
final class OutputBudgetTests: XCTestCase {

    // MARK: Erkennen

    /// The provider says so when it can.
    func testAStatedReasonIsEnough() {
        for reason in ["max_tokens", "length"] {
            XCTAssertTrue(AgentRunner.ranOutOfRoom(stopReason: reason, text: "etwas",
                                                   thinking: "", toolCalls: 0),
                          "»\(reason)« heißt abgeschnitten, egal was sonst ankam.")
        }
    }

    /// The case this is about, and the one nobody noticed so far: the provider says
    /// nothing, and back comes a turn made of nothing but reasoning.
    func testOnlyThinkingAndNothingElseCountsAsRunOut() {
        XCTAssertTrue(AgentRunner.ranOutOfRoom(stopReason: nil, text: "",
                                               thinking: "lange nachgedacht …", toolCalls: 0))
        XCTAssertTrue(AgentRunner.ranOutOfRoom(stopReason: "end_turn", text: "   \n ",
                                               thinking: "lange nachgedacht …", toolCalls: 0))
    }

    /// A turn with a tool call often has no text, and that is the normal case of a
    /// round in which the model wants to look something up first. If it counted, every
    /// search would double the answer length.
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

    /// An empty turn with nothing in it is a different error — there is a message of
    /// its own for that, and more budget does not help against it.
    func testAnEmptyTurnIsNotARoomProblem() {
        XCTAssertFalse(AgentRunner.ranOutOfRoom(stopReason: nil, text: "",
                                                thinking: "", toolCalls: 0))
    }

    // MARK: Wachsen

    func testItDoubles() {
        XCTAssertEqual(AgentRunner.nextOutputBudget(after: 4_096, ceiling: nil), 8_192)
        XCTAssertEqual(AgentRunner.nextOutputBudget(after: 8_192, ceiling: nil), 16_384)
    }

    /// The limit the provider names is the limit — and it is met, not overshot.
    /// Doubling 4,000 with a limit of 6,000 gives 6,000 and not 8,000.
    func testAReportedLimitIsMetExactly() {
        XCTAssertEqual(AgentRunner.nextOutputBudget(after: 4_000, ceiling: 6_000), 6_000)
    }

    /// If the slider already stands at the limit, there is nothing left to get. The
    /// task is then too large for this model, and a further attempt only costs the whole
    /// request once more.
    func testAtTheLimitThereIsNoNextStep() {
        XCTAssertNil(AgentRunner.nextOutputBudget(after: 6_000, ceiling: 6_000))
        XCTAssertNil(AgentRunner.nextOutputBudget(after: 9_000, ceiling: 6_000))
    }

    /// Without a stated limit the last barrier carries. It is there so the doubling
    /// does not run into the absurd — the app no longer probes for limits.
    func testWithoutAReportedLimitTheLastFloorHolds() {
        XCTAssertEqual(AgentRunner.nextOutputBudget(after: AgentRunner.outputCeiling / 2,
                                                    ceiling: nil),
                       AgentRunner.outputCeiling)
        XCTAssertNil(AgentRunner.nextOutputBudget(after: AgentRunner.outputCeiling, ceiling: nil))
    }

    /// Three doublings in one round, so from 4,096 at most 32,768. Each one costs the
    /// whole request again.
    func testThreeGrowthsReachThirtyTwoThousand() {
        var budget = 4_096
        for _ in 0..<AgentRunner.maxGrowths {
            budget = AgentRunner.nextOutputBudget(after: budget, ceiling: nil) ?? budget
        }
        XCTAssertEqual(budget, 32_768)
    }

    // MARK: Who set the number

    func testAFreshConfigGrowsByItself() {
        XCTAssertFalse(LLMConfig().maxOutputTokensIsCustom)
    }

    /// A settings file from before this feature does not know whether anyone touched
    /// the number. If the default still stands there, nobody did.
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

// MARK: - Asking again or not

extension OutputBudgetTests {

    /// The case the function exists for: only reasoning, no text.
    func testWithNothingOnScreenTheTurnStartsOver() {
        XCTAssertTrue(AgentRunner.shouldAskAgain(text: "", toolCalls: 0, alreadyGrew: 0))
        XCTAssertTrue(AgentRunner.shouldAskAgain(text: "  \n ", toolCalls: 0, alreadyGrew: 0))
    }

    /// If text already stands there, a fresh attempt would be a step backwards: the
    /// reader would watch half an answer disappear and wait from the beginning. The
    /// answer length grows all the same — just for the next turn.
    func testHalfAnAnswerIsWorthMoreThanAFreshStart() {
        XCTAssertFalse(AgentRunner.shouldAskAgain(text: "Die Antwort beginnt …",
                                                  toolCalls: 0, alreadyGrew: 0))
    }

    func testATurnWithToolCallsIsNeverRestarted() {
        XCTAssertFalse(AgentRunner.shouldAskAgain(text: "", toolCalls: 1, alreadyGrew: 0))
    }

    /// Every attempt costs the whole request again — the history travels with it every
    /// time. Hence a limit and not “until it fits”.
    func testAfterThreeTriesItStops() {
        XCTAssertTrue(AgentRunner.shouldAskAgain(text: "", toolCalls: 0,
                                                 alreadyGrew: AgentRunner.maxGrowths - 1))
        XCTAssertFalse(AgentRunner.shouldAskAgain(text: "", toolCalls: 0,
                                                  alreadyGrew: AgentRunner.maxGrowths))
    }
}
