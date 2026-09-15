import XCTest
@testable import PerBu

/// Grenzen, die ein Anbieter in einer Absage nennt.
///
/// Bis eben hat die App danach gefragt: eine Anfrage mit `max_tokens: 99999999`,
/// und aus der Absage liess sich die echte Grenze lesen. Das funktionierte — und ist
/// weg, weil die App keine Zahlen erfinden soll, um Grenzen auszuloten.
///
/// Damit wird dieses Auslesen wichtiger statt unwichtiger: es ist jetzt der einzige
/// Weg, auf dem ein Anbieter ohne veroeffentlichte Grenzen der App seine mitteilt.
/// Die Vorlagen unten sind echte Fehlertexte in den Formulierungen, die im Umlauf
/// sind — die Stelle, an der ein zu strenger regulaerer Ausdruck still nichts mehr
/// findet und niemandem auffaellt.
final class LimitTests: XCTestCase {

    func testOpenAIStyleContextMessage() {
        let body = """
        {"error": {"message": "This model's maximum context length is 128000 tokens. \
        However, you requested 130000 tokens.", "type": "invalid_request_error"}}
        """
        let limits = ModelCatalog.extractLimits(from: body)
        XCTAssertEqual(limits.context, 128_000)
    }

    func testAnOutputCeilingNamedAfterMaxTokens() {
        let body = """
        {"error": {"message": "max_tokens must be less than or equal to 8192"}}
        """
        let limits = ModelCatalog.extractLimits(from: body)
        XCTAssertEqual(limits.output, 8192)
    }

    func testTheWordyVariant() {
        let body = "maximum number of output tokens for this model is 16384"
        XCTAssertEqual(ModelCatalog.extractLimits(from: body).output, 16_384)
    }

    func testContextWindowSpelledAsAWindow() {
        let body = "Request exceeds the maximum context window of 32768 tokens."
        XCTAssertEqual(ModelCatalog.extractLimits(from: body).context, 32_768)
    }

    /// Ein Fehler ohne Zahl darf nichts setzen. Waere das anders, schriebe der erste
    /// Netzausfall eine erfundene Grenze in die Einstellungen.
    func testAMessageWithoutNumbersChangesNothing() {
        let limits = ModelCatalog.extractLimits(from: "Internal server error")
        XCTAssertNil(limits.context)
        XCTAssertNil(limits.output)
    }

    /// Zahlen ausserhalb jeder plausiblen Groesse sind keine Grenzen, sondern
    /// Zeitstempel, Fehlernummern oder Kennungen, die zufaellig danebenstehen.
    func testImplausibleNumbersAreIgnored() {
        XCTAssertNil(ModelCatalog.extractLimits(from: "max_tokens 12").output,
                     "Zwoelf Token ist keine Grenze, das ist ein Tippfehler.")
        XCTAssertNil(ModelCatalog.extractLimits(from: "max_tokens 99999999999").output,
                     "Hundert Milliarden auch nicht.")
    }

    /// Die Absage nennt beides — dann wird auch beides gelernt.
    func testBothCeilingsAtOnce() {
        let body = """
        {"error": {"message": "max_tokens must be <= 4096; this model's maximum \
        context length is 200000 tokens"}}
        """
        let limits = ModelCatalog.extractLimits(from: body)
        XCTAssertEqual(limits.output, 4096)
        XCTAssertEqual(limits.context, 200_000)
    }
}
