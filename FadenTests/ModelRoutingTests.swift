import XCTest
@testable import Faden

/// Which model handles a turn, and what it falls back to.
///
/// Four fields weighed against each other, and the occasion is measured: `z-ai/glm-5.3`
/// does everything better than its `-flash` sibling, except see. To an image it answers
/// with HTTP 400, “Model only supports text input”. Without this switch you would have
/// to choose — the better model or images.
///
/// The bug these tests hold down would be no crash but something worse: an image going
/// to a blind model, and a user who thinks image recognition is broken.
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

    /// Without a vision model entered, the main model handles it too. It then falls
    /// under the “allow image attachments” switch — and that is only on when it really
    /// sees them.
    func testWithoutAVisionModelTheMainModelKeepsTheImage() {
        let c = config()
        XCTAssertEqual(c.model(forImages: true), "haupt")
    }

    func testWhitespaceIsNotAModelName() {
        let c = config(vision: "   ")
        XCTAssertEqual(c.model(forImages: true), "haupt")
    }

    // MARK: What it falls back to

    func testTheOrdinaryFallback() {
        let c = config(fallback: "ersatz")
        XCTAssertEqual(c.fallback(forImages: false, after: "haupt"), "ersatz")
    }

    func testNoFallbackConfiguredMeansNone() {
        XCTAssertNil(config().fallback(forImages: false, after: "haupt"))
    }

    /// Falling back to the same model would be no second chance but the same mistake
    /// again — with a wait on top.
    func testItNeverFallsBackToTheModelThatJustFailed() {
        let c = config(fallback: "ersatz")
        XCTAssertNil(c.fallback(forImages: false, after: "ersatz"))
    }

    /// The core: if an image hangs on the turn, the image fallback applies first.
    func testAnImageTurnPrefersTheVisionFallback() {
        let c = config(fallback: "blind", vision: "sieht", visionFallback: "sieht-auch")
        XCTAssertEqual(c.fallback(forImages: true, after: "sieht"), "sieht-auch")
    }

    /// And if none is entered, the general one is better than none — the alternative
    /// would be letting the turn fail without a second attempt.
    func testAnImageTurnFallsBackToTheOrdinaryOneWhenNoVisionFallbackIsSet() {
        let c = config(fallback: "ersatz", vision: "sieht")
        XCTAssertEqual(c.fallback(forImages: true, after: "sieht"), "ersatz")
    }

    /// Both entered, but the image fallback is the one that has just failed: then the
    /// general one, rather than giving up.
    func testItSkipsPastTheCandidateThatJustFailed() {
        let c = config(fallback: "ersatz", vision: "sieht", visionFallback: "sieht-auch")
        XCTAssertEqual(c.fallback(forImages: true, after: "sieht-auch"), "ersatz")
    }

    // MARK: Whether the plus sign appears

    func testTheAttachButtonFollowsEitherRoute() {
        var c = config()
        XCTAssertFalse(c.acceptsImages, "Weder Schalter noch Vision-Modell.")

        c.supportsVision = true
        XCTAssertTrue(c.acceptsImages, "Das Hauptmodell sieht selbst.")

        c.supportsVision = false
        c.visionModel = "sieht"
        XCTAssertTrue(c.acceptsImages, "Ein eigenes Modell fuer Bilder reicht auch.")
    }

    // MARK: Welche Modelle zur Auswahl stehen

    /// The picker for images shows everything except what is demonstrably blind.
    ///
    /// Deliberately not “only what demonstrably sees”: most providers say nothing about
    /// images, and a picker that stayed empty because of it helps nobody. The difference
    /// is exactly the one between `nil` and `false`, and it was expensive this morning —
    /// `z-ai/glm-5.3` has no field for images at all, `z-ai/glm-5-turbo` has one and it
    /// says false.
    func testTheImagePickerHidesOnlyWhatIsProvablyBlind() {
        var c = LLMConfig()
        c.knownModels = [
            RemoteModel(id: "schweigt"),
            RemoteModel(id: "sieht", capabilities: Capabilities(vision: true)),
            RemoteModel(id: "blind", capabilities: Capabilities(vision: false)),
        ]
        let offered = c.imageCapableModels.map(\.id)
        XCTAssertEqual(offered, ["schweigt", "sieht"])
        XCTAssertFalse(offered.contains("blind"), "Ein Vorschlag, der ein blindes Modell nennt, waere schlimmer als keiner.")
    }

    /// Without a loaded list there is nothing to choose — the field then stays a
    /// field.
    func testWithoutAListThereIsNothingToChooseFrom() {
        XCTAssertTrue(LLMConfig().imageCapableModels.isEmpty)
    }

    // MARK: How an image is recognised

    /// Across the whole history and not only the last message: every request carries the
    /// entire conversation, so the image from ten turns ago as well.
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
