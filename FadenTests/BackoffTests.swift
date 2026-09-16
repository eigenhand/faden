import XCTest
@testable import Faden

/// What happens when the provider throttles.
///
/// Faden's first unit tests, and it is no accident that they begin here. Until just now
/// the app switched to the fallback model immediately on a 429 — measured on the same
/// question, 72 seconds against 12. Two seconds of waiting turned into a minute, and the
/// user got the worse answer on top.
///
/// This decision stood written nowhere that anyone had to read. Now it stands here.
final class BackoffTests: XCTestCase {

    /// “Too many requests” and “overloaded right now” are waiting times. A wrong key is
    /// not — there, waiting would only bring the same result three times.
    func testOnlyBusyStatusesAreWaitedOut() {
        XCTAssertTrue(Backoff.isBusy(429))
        XCTAssertTrue(Backoff.isBusy(503))
        XCTAssertTrue(Backoff.isBusy(529))

        XCTAssertFalse(Backoff.isBusy(401), "Ein falscher Schlüssel bleibt falsch.")
        XCTAssertFalse(Backoff.isBusy(403))
        XCTAssertFalse(Backoff.isBusy(404))
        XCTAssertFalse(Backoff.isBusy(500))
    }

    func testRetryAfterWins() {
        XCTAssertEqual(Backoff.pause(retryAfter: "5", attempt: 0), 5, accuracy: 0.001)
        XCTAssertEqual(Backoff.pause(retryAfter: " 12 ", attempt: 1), 12, accuracy: 0.001)
    }

    /// A header saying “3600” must not stop the app for an hour.
    func testAnAbsurdRetryAfterIsCapped() {
        XCTAssertEqual(Backoff.pause(retryAfter: "3600", attempt: 0), 30, accuracy: 0.001)
    }

    func testWithoutAHeaderTheWaitDoubles() {
        XCTAssertEqual(Backoff.pause(retryAfter: nil, attempt: 0), 2, accuracy: 0.001)
        XCTAssertEqual(Backoff.pause(retryAfter: nil, attempt: 1), 4, accuracy: 0.001)
    }

    /// Some providers send a date instead of a number. That must not lead to zero
    /// seconds — that would be a swarm instead of a pause.
    func testUnusableHeadersFallBackToTheFormula() {
        for header in ["Wed, 21 Oct 2026 07:28:00 GMT", "", "sofort", "0", "-5"] {
            XCTAssertEqual(Backoff.pause(retryAfter: header, attempt: 0), 2, accuracy: 0.001,
                           "Kopf \(header.isEmpty ? "(leer)" : header)")
        }
    }

    /// At most two waits, then the fallback model's turn has come. Six seconds is the
    /// limit of what may be sat out in silence.
    func testTheWaitingIsBoundedBeforeFallingBack() {
        XCTAssertEqual(Backoff.maxWaits, 2)
        let total = (0 ..< Backoff.maxWaits)
            .map { Backoff.pause(retryAfter: nil, attempt: $0) }
            .reduce(0, +)
        XCTAssertEqual(total, 6, accuracy: 0.001)
    }

    // MARK: The fallback comes after, not before

    /// After the waits the fallback is allowed — by then the throttling is no longer a
    /// matter of seconds, and another model may well have a quota of its own.
    func testThrottlingStillAllowsTheFallbackAfterwards() {
        XCTAssertTrue(AgentRunner.isWorthRetrying(LLMError.http(status: 429, body: "")))
        XCTAssertTrue(AgentRunner.isWorthRetrying(LLMError.http(status: 503, body: "")))
    }

    /// A wrong key stays wrong with every model name.
    func testAWrongKeyIsNotWorthAnotherModel() {
        XCTAssertFalse(AgentRunner.isWorthRetrying(LLMError.http(status: 401, body: "")))
    }

    /// 403 is expressly included: that is exactly how the provider answers for an
    /// unknown model.
    func testForbiddenIsWorthAnotherModel() {
        XCTAssertTrue(AgentRunner.isWorthRetrying(LLMError.http(status: 403, body: "")))
    }

    /// Without an endpoint and without a key, no other model name helps.
    func testLocalProblemsAreNotWorthAnotherModel() {
        XCTAssertFalse(AgentRunner.isWorthRetrying(LLMError.notConfigured))
        XCTAssertFalse(AgentRunner.isWorthRetrying(LLMError.missingKey))
    }

    // MARK: Die Meldung

    /// What is checked is the form and not the wording.
    ///
    /// Since the error texts go through the string catalogue, the sentence hangs on the
    /// device's language — on an English simulator “throttling” stood here and the test
    /// was red although the code was right. What this test really asserts is not the
    /// wording either: a 429 becomes a line a human reads, and not the JSON the provider
    /// sent.
    func testThrottlingSaysSoInsteadOfShowingJSON() throws {
        let text = try XCTUnwrap(
            LLMError.http(status: 429, body: "{\"error\":{\"message\":\"rate limit exceeded\"}}")
                .errorDescription)
        XCTAssertFalse(text.contains("{"), "Kein rohes JSON in der Zeile.")
        XCTAssertFalse(text.contains("rate limit exceeded"),
                       "Der Rumpf der Antwort gehört nicht in die Meldung.")
        XCTAssertTrue(text.contains("429"), "Der Status darf dastehen: \(text)")

        let other = try XCTUnwrap(LLMError.http(status: 404, body: "nope").errorDescription)
        XCTAssertTrue(other.contains("404"), "Alles andere bleibt beim rohen Befund.")
    }
}
