import XCTest
@testable import PerBu

/// Welches Modell einen Zug bearbeitet, und worauf es ausweicht.
///
/// Vier Felder, die gegeneinander abgewogen werden, und der Anlass ist gemessen:
/// `z-ai/glm-5.3` kann alles besser als sein `-flash`-Geschwister, ausser sehen. Auf
/// ein Bild antwortet es mit HTTP 400, „Model only supports text input". Ohne diese
/// Weiche muesste man sich entscheiden — das bessere Modell oder Bilder.
///
/// Der Fehler, den diese Tests festhalten, waere kein Absturz, sondern etwas
/// Schlimmeres: ein Bild, das an ein blindes Modell geht, und ein Nutzer, der die
/// Bilderkennung fuer kaputt haelt.
final class ModelRoutingTests: XCTestCase {

    private func config(model: String = "haupt", fallback: String = "",
                        vision: String = "", visionFallback: String = "") -> LLMConfig {
        var c = LLMConfig()
        c.model = model
        c.fallbackModel = fallback
        c.visionModel = vision
        c.visionFallbackModel = visionFallback
        return c
    }

    // MARK: Welches Modell

    func testWithoutImagesTheMainModelWorks() {
        let c = config(vision: "sieht")
        XCTAssertEqual(c.model(forImages: false), "haupt")
    }

    func testAnImageGoesToTheVisionModel() {
        let c = config(vision: "sieht")
        XCTAssertEqual(c.model(forImages: true), "sieht")
    }

    /// Ohne eingetragenes Vision-Modell macht das Hauptmodell es mit. Es faellt dann
    /// unter den Schalter „Bilder anhaengen erlauben" — und der steht nur an, wenn es
    /// sie wirklich sieht.
    func testWithoutAVisionModelTheMainModelKeepsTheImage() {
        let c = config()
        XCTAssertEqual(c.model(forImages: true), "haupt")
    }

    func testWhitespaceIsNotAModelName() {
        let c = config(vision: "   ")
        XCTAssertEqual(c.model(forImages: true), "haupt")
    }

    // MARK: Worauf ausgewichen wird

    func testTheOrdinaryFallback() {
        let c = config(fallback: "ersatz")
        XCTAssertEqual(c.fallback(forImages: false, after: "haupt"), "ersatz")
    }

    func testNoFallbackConfiguredMeansNone() {
        XCTAssertNil(config().fallback(forImages: false, after: "haupt"))
    }

    /// Auf dasselbe Modell auszuweichen waere keine zweite Chance, sondern derselbe
    /// Fehler noch einmal — und eine Wartezeit obendrauf.
    func testItNeverFallsBackToTheModelThatJustFailed() {
        let c = config(fallback: "ersatz")
        XCTAssertNil(c.fallback(forImages: false, after: "ersatz"))
    }

    /// Der Kern: haengt ein Bild am Zug, gilt zuerst das Bild-Ausweichmodell.
    func testAnImageTurnPrefersTheVisionFallback() {
        let c = config(fallback: "blind", vision: "sieht", visionFallback: "sieht-auch")
        XCTAssertEqual(c.fallback(forImages: true, after: "sieht"), "sieht-auch")
    }

    /// Und wenn keines eingetragen ist, ist das allgemeine besser als gar keines —
    /// die Alternative waere, den Zug ohne zweiten Versuch scheitern zu lassen.
    func testAnImageTurnFallsBackToTheOrdinaryOneWhenNoVisionFallbackIsSet() {
        let c = config(fallback: "ersatz", vision: "sieht")
        XCTAssertEqual(c.fallback(forImages: true, after: "sieht"), "ersatz")
    }

    /// Beide eingetragen, aber das Bild-Ausweichmodell ist gerade das gescheiterte:
    /// dann das allgemeine, statt aufzugeben.
    func testItSkipsPastTheCandidateThatJustFailed() {
        let c = config(fallback: "ersatz", vision: "sieht", visionFallback: "sieht-auch")
        XCTAssertEqual(c.fallback(forImages: true, after: "sieht-auch"), "ersatz")
    }

    // MARK: Ob das Pluszeichen erscheint

    func testTheAttachButtonFollowsEitherRoute() {
        var c = config()
        XCTAssertFalse(c.acceptsImages, "Weder Schalter noch Vision-Modell.")

        c.supportsVision = true
        XCTAssertTrue(c.acceptsImages, "Das Hauptmodell sieht selbst.")

        c.supportsVision = false
        c.visionModel = "sieht"
        XCTAssertTrue(c.acceptsImages, "Ein eigenes Modell fuer Bilder reicht auch.")
    }

    // MARK: Woran ein Bild erkannt wird

    /// Ueber die ganze Historie und nicht nur die letzte Nachricht: bei jeder Anfrage
    /// geht die ganze Unterhaltung mit, also auch das Bild von vor zehn Zuegen.
    func testAnImageAnywhereInTheHistoryCounts() {
        let withImage = Message(role: .user, blocks: [
            .image(data: "AAAA", mediaType: "image/jpeg"),
            .text("Was ist das?"),
        ])
        let plain = Message(role: .assistant, text: "Ein Kabel.")
        let later = Message(role: .user, text: "Und das andere?")

        XCTAssertTrue(withImage.hasImage)
        XCTAssertFalse(plain.hasImage)
        XCTAssertTrue([withImage, plain, later].contains(where: \.hasImage),
                      "Das Bild von vorhin geht bei jeder Anfrage wieder mit.")
        XCTAssertFalse([plain, later].contains(where: \.hasImage))
    }
}
