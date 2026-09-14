import XCTest
@testable import PerBu

/// Was passiert, wenn der Anbieter drosselt.
///
/// Fadens erste Unittests, und es ist kein Zufall, dass sie hier anfangen. Bis eben
/// hat die App bei einem 429 sofort auf das Ausweichmodell geschaltet — nach der
/// eigenen Messung in `BundledSetup` 72 Sekunden gegen 12. Aus zwei Sekunden Warten
/// wurde eine Minute, und der Nutzer bekam die schlechtere Antwort obendrein.
///
/// Diese Entscheidung stand nirgends geschrieben, wo jemand sie nachlesen musste.
/// Jetzt steht sie hier.
final class BackoffTests: XCTestCase {

    /// „Zu viele Anfragen" und „gerade überlastet" sind Wartezeiten. Ein falscher
    /// Schlüssel ist es nicht — dort brächte Warten nur dreimal dasselbe Ergebnis.
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

    /// Ein Kopf mit „3600" darf die App nicht für eine Stunde anhalten.
    func testAnAbsurdRetryAfterIsCapped() {
        XCTAssertEqual(Backoff.pause(retryAfter: "3600", attempt: 0), 30, accuracy: 0.001)
    }

    func testWithoutAHeaderTheWaitDoubles() {
        XCTAssertEqual(Backoff.pause(retryAfter: nil, attempt: 0), 2, accuracy: 0.001)
        XCTAssertEqual(Backoff.pause(retryAfter: nil, attempt: 1), 4, accuracy: 0.001)
    }

    /// Manche Anbieter schicken ein Datum statt einer Zahl. Das darf nicht zu null
    /// Sekunden führen — das wäre ein Schwarm statt einer Pause.
    func testUnusableHeadersFallBackToTheFormula() {
        for header in ["Wed, 21 Oct 2026 07:28:00 GMT", "", "sofort", "0", "-5"] {
            XCTAssertEqual(Backoff.pause(retryAfter: header, attempt: 0), 2, accuracy: 0.001,
                           "Kopf \(header.isEmpty ? "(leer)" : header)")
        }
    }

    /// Höchstens zwei Pausen, dann ist das Ausweichmodell an der Reihe. Sechs Sekunden
    /// sind die Grenze dessen, was man stillschweigend aussitzen darf.
    func testTheWaitingIsBoundedBeforeFallingBack() {
        XCTAssertEqual(Backoff.maxWaits, 2)
        let total = (0 ..< Backoff.maxWaits)
            .map { Backoff.pause(retryAfter: nil, attempt: $0) }
            .reduce(0, +)
        XCTAssertEqual(total, 6, accuracy: 0.001)
    }

    // MARK: Das Ausweichmodell kommt danach, nicht davor

    /// Nach den Pausen darf ausgewichen werden — dann ist die Drosselung kein
    /// Sekundenproblem mehr, und ein anderes Modell hat womöglich ein eigenes Kontingent.
    func testThrottlingStillAllowsTheFallbackAfterwards() {
        XCTAssertTrue(AgentRunner.isWorthRetrying(LLMError.http(status: 429, body: "")))
        XCTAssertTrue(AgentRunner.isWorthRetrying(LLMError.http(status: 503, body: "")))
    }

    /// Ein falscher Schlüssel bleibt mit jedem Modellnamen falsch.
    func testAWrongKeyIsNotWorthAnotherModel() {
        XCTAssertFalse(AgentRunner.isWorthRetrying(LLMError.http(status: 401, body: "")))
    }

    /// 403 ist ausdrücklich dabei: der Anbieter antwortet auf ein unbekanntes Modell
    /// genau so.
    func testForbiddenIsWorthAnotherModel() {
        XCTAssertTrue(AgentRunner.isWorthRetrying(LLMError.http(status: 403, body: "")))
    }

    /// Ohne Endpoint und ohne Schlüssel hilft kein anderer Modellname.
    func testLocalProblemsAreNotWorthAnotherModel() {
        XCTAssertFalse(AgentRunner.isWorthRetrying(LLMError.notConfigured))
        XCTAssertFalse(AgentRunner.isWorthRetrying(LLMError.missingKey))
    }

    // MARK: Die Meldung

    func testThrottlingSaysSoInsteadOfShowingJSON() throws {
        let text = try XCTUnwrap(
            LLMError.http(status: 429, body: "{\"error\":{\"message\":\"rate limit exceeded\"}}")
                .errorDescription)
        XCTAssertTrue(text.contains("drosselt"), text)
        XCTAssertFalse(text.contains("{"), "Kein rohes JSON in der Zeile.")

        let other = try XCTUnwrap(LLMError.http(status: 404, body: "nope").errorDescription)
        XCTAssertTrue(other.contains("404"), "Alles andere bleibt beim rohen Befund.")
    }
}
