import XCTest
@testable import PerBu

/// Was eine Modellliste über die Fähigkeiten verrät.
///
/// Es gibt dafür keinen Standard, und deshalb steht hier ein Test und keine Zeile
/// Code mit einem Feldnamen darin. Drei Schreibweisen sind im Umlauf: der Boolean
/// (`supports_vision`), die Beschreibung dessen, was hineingeht (OpenRouter mit
/// `architecture.input_modalities`), und der Sammelknoten (`capabilities`).
///
/// Der wichtigste Fall ist aber keiner davon, sondern das Schweigen. `z-ai/glm-5.3`
/// führt bei seinem Anbieter gar kein Feld für Bilder — und wer das als „kann keine"
/// liest, hat zufaellig recht, und wer es bei `z-ai/glm-5.2` genauso liest, hat
/// unrecht. Schweigen muss **nil** bleiben, damit die Messung es entscheiden kann.
final class CapabilityTests: XCTestCase {

    private func caps(_ json: String) throws -> Capabilities {
        let value = try XCTUnwrap(JSONValue.decode(Data(json.utf8)))
        return ModelCatalog.capabilities(from: value)
    }

    func testTheBooleanSpelling() throws {
        let c = try caps("""
        {"id": "a", "supports_vision": true, "supports_function_calling": true,
         "supports_reasoning": false}
        """)
        XCTAssertEqual(c.vision, true)
        XCTAssertEqual(c.tools, true)
        XCTAssertEqual(c.reasoning, false)
    }

    /// OpenRouter sagt nicht „kann Bilder", sondern „nimmt Bilder entgegen".
    func testTheOpenRouterSpelling() throws {
        let c = try caps("""
        {"id": "a",
         "architecture": {"input_modalities": ["text", "image"]},
         "supported_parameters": ["tools", "temperature", "reasoning"]}
        """)
        XCTAssertEqual(c.vision, true)
        XCTAssertEqual(c.tools, true)
        XCTAssertEqual(c.reasoning, true)
    }

    func testTheOpenRouterSpellingAlsoSaysNo() throws {
        let c = try caps("""
        {"id": "a",
         "architecture": {"input_modalities": ["text"]},
         "supported_parameters": ["temperature"]}
        """)
        XCTAssertEqual(c.vision, false, "Modalitäten sind aufgezählt, Bild fehlt: das ist ein Nein.")
        XCTAssertEqual(c.tools, false)
        XCTAssertEqual(c.reasoning, false)
    }

    func testTheNestedSpelling() throws {
        let c = try caps("""
        {"id": "a", "capabilities": {"vision": true, "tools": false}}
        """)
        XCTAssertEqual(c.vision, true)
        XCTAssertEqual(c.tools, false)
        XCTAssertNil(c.reasoning)
    }

    /// Der Fall, um den es geht: kein Feld, keine Aussage.
    func testSilenceStaysUnknown() throws {
        let c = try caps("""
        {"id": "z-ai/glm-5.3", "max_input_tokens": 1048576}
        """)
        XCTAssertNil(c.vision, "Schweigen ist kein Nein.")
        XCTAssertNil(c.tools)
        XCTAssertNil(c.reasoning)
    }

    /// Listen schreiben Wahrheitswerte auch als Wort oder Zahl.
    func testBooleansWrittenAsWordsOrNumbers() throws {
        let c = try caps("""
        {"id": "a", "supports_vision": "true", "supports_reasoning": 1}
        """)
        XCTAssertEqual(c.vision, true)
        XCTAssertEqual(c.reasoning, true)
    }

    // MARK: Messung schlägt Behauptung

    func testAMeasurementOverridesTheList() {
        let claimed = Capabilities(vision: true, tools: true, reasoning: nil)
        let measured = Capabilities(vision: false)
        let merged = claimed.overridden(by: measured)
        XCTAssertEqual(merged.vision, false, "Gemessen schlägt behauptet.")
        XCTAssertEqual(merged.tools, true, "Wo nichts gemessen wurde, bleibt die Behauptung.")
        XCTAssertNil(merged.reasoning)
    }

    /// Der Schalter für Bilder ist eine Entscheidung und keine Feststellung: steht er
    /// aus, gibt es keine Marke — auch wenn das Modell Bilder könnte.
    func testTheVisionBadgeFollowsTheSwitch() {
        var config = LLMConfig()
        config.supportsVision = false
        config.supportsTools = true
        XCTAssertNil(config.capabilities.vision)
        XCTAssertEqual(config.capabilities.tools, true)

        config.supportsVision = true
        XCTAssertEqual(config.capabilities.vision, true)
    }
}
