import XCTest
@testable import Faden

/// What a model list reveals about capabilities.
///
/// There is no standard for it, which is why a test stands here and not a line of code
/// with one field name in it. Three spellings are in circulation: the boolean
/// (`supports_vision`), the description of what goes in (OpenRouter with
/// `architecture.input_modalities`), and the collecting node (`capabilities`).
///
/// The most important case is none of them, though, but the silence. `z-ai/glm-5.3`
/// carries no field for images at all at its provider — and whoever reads that as
/// “cannot do any” happens to be right, while whoever reads it the same way for
/// `z-ai/glm-5.2` is wrong. Silence has to stay **nil**, so the measurement can
/// decide it.
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

    /// OpenRouter does not say “can do images” but “accepts images”.
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

    /// The case this is about: no field, no statement.
    func testSilenceStaysUnknown() throws {
        let c = try caps("""
        {"id": "z-ai/glm-5.3", "max_input_tokens": 1048576}
        """)
        XCTAssertNil(c.vision, "Schweigen ist kein Nein.")
        XCTAssertNil(c.tools)
        XCTAssertNil(c.reasoning)
    }

    /// Lists write truth values as words or numbers too.
    func testBooleansWrittenAsWordsOrNumbers() throws {
        let c = try caps("""
        {"id": "a", "supports_vision": "true", "supports_reasoning": 1}
        """)
        XCTAssertEqual(c.vision, true)
        XCTAssertEqual(c.reasoning, true)
    }

    // MARK: Measurement beats assertion

    func testAMeasurementOverridesTheList() {
        let claimed = Capabilities(vision: true, tools: true, reasoning: nil)
        let measured = Capabilities(vision: false)
        let merged = claimed.overridden(by: measured)
        XCTAssertEqual(merged.vision, false, "Gemessen schlägt behauptet.")
        XCTAssertEqual(merged.tools, true, "Wo nichts gemessen wurde, bleibt die Behauptung.")
        XCTAssertNil(merged.reasoning)
    }

    /// The switch for images is a decision and not a finding: with it off there is no
    /// badge — even if the model could do images.
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
