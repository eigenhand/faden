import XCTest
@testable import Faden

/// The consent to send data to a provider (App Review guideline 5.1.2(i)).
///
/// What is checked is the bookkeeping: that a yes is remembered for exactly the host
/// and the purpose it was given for, that it survives a restart, and that an install
/// from before the consent existed starts with nothing agreed.
final class DataSharingTests: XCTestCase {

    private func need(_ purpose: SharingPurpose, _ url: String) throws -> SharingNeed {
        try XCTUnwrap(SharingNeed(purpose, url: URL(string: url)))
    }

    func testNothingIsAgreedAtFirst() throws {
        let consent = DataSharingConsent()
        XCTAssertFalse(consent.covers(try need(.chat, "https://api.openai.com/v1/chat/completions")))
    }

    func testAYesCoversThatHostAndPurpose() throws {
        var consent = DataSharingConsent()
        let chat = try need(.chat, "https://api.openai.com/v1/chat/completions")
        consent.grant([chat])
        XCTAssertTrue(consent.covers(chat))
        // Another path on the same host is the same provider.
        XCTAssertTrue(consent.covers(try need(.chat, "https://api.openai.com/v1/models")))
    }

    /// Scheme, port and letter case do not make another provider.
    func testTheHostIsNormalised() throws {
        var consent = DataSharingConsent()
        consent.grant([try need(.chat, "https://API.OpenAI.com/v1")])
        XCTAssertTrue(consent.covers(try need(.chat, "http://api.openai.com:8443/v1")))
    }

    func testAnotherHostIsAskedAgain() throws {
        var consent = DataSharingConsent()
        consent.grant([try need(.chat, "https://api.openai.com/v1")])
        XCTAssertFalse(consent.covers(try need(.chat, "https://api.anthropic.com/v1/messages")))
    }

    /// Agreeing that a provider may answer chats is not agreeing that it may have the
    /// voice recordings.
    func testAnotherPurposeOnTheSameHostIsAskedAgain() throws {
        var consent = DataSharingConsent()
        consent.grant([try need(.chat, "https://api.openai.com/v1")])
        XCTAssertFalse(consent.covers(try need(.transcription, "https://api.openai.com/v1/audio")))
    }

    func testMissingDropsWhatIsAgreedAndDuplicates() throws {
        var consent = DataSharingConsent()
        let chat = try need(.chat, "https://a.example/v1")
        let search = try need(.search, "https://b.example/search")
        consent.grant([chat])
        XCTAssertEqual(consent.missing([chat, search, search]), [search])
    }

    func testRevokeForgetsTheHost() throws {
        var consent = DataSharingConsent()
        let chat = try need(.chat, "https://a.example/v1")
        consent.grant([chat])
        consent.revoke(host: "A.example")
        XCTAssertFalse(consent.covers(chat))
    }

    /// No host, nothing leaves the device — nothing to ask.
    func testNoURLNoNeed() {
        XCTAssertNil(SharingNeed(.chat, url: nil))
        XCTAssertNil(SharingNeed(.chat, url: URL(string: "/v1/chat/completions")))
    }

    /// Search URLs carry placeholders that are not valid URL characters.
    func testTheSearchHostIsReadPastThePlaceholders() {
        let need = SearchRecipe.sharingNeed(for: "https://api.search.brave.com/res/v1/web/search?q={{query}}")
        XCTAssertEqual(need?.host, "api.search.brave.com")
        XCTAssertEqual(need?.purpose, .search)
        XCTAssertNil(SearchRecipe.sharingNeed(for: ""))
    }

    func testTheConsentSurvivesARestart() throws {
        var settings = AppSettings()
        let chat = try need(.chat, "https://api.openai.com/v1")
        settings.dataSharing.grant([chat, try need(.speech, "https://tts.example/v1")])
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.dataSharing, settings.dataSharing)
        XCTAssertTrue(back.dataSharing.covers(chat))
    }

    /// An install from before the consent existed has agreed to nothing and is asked
    /// before its next request — its providers stay.
    func testAnOlderSettingsFileHasAgreedToNothing() throws {
        let old = Data(#"{"searchEnabled":true,"llms":[]}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertEqual(settings.dataSharing, DataSharingConsent())
    }

    /// A purpose written by a later version is dropped, not the whole consent.
    func testAnUnknownPurposeIsDroppedAndTheRestKept() throws {
        let json = Data(#"{"agreed":{"api.openai.com":["chat","telepathy"]}}"#.utf8)
        let consent = try JSONDecoder().decode(DataSharingConsent.self, from: json)
        XCTAssertTrue(consent.covers(try need(.chat, "https://api.openai.com")))
        XCTAssertEqual(consent.agreed["api.openai.com"], [.chat])
    }

    // MARK: What a turn asks for

    private func remoteModel() -> LLMConfig {
        var c = LLMConfig()
        c.wireFormat = .openai
        c.baseURL = "https://api.openai.com"
        c.path = "/v1/chat/completions"
        c.model = "gpt"
        return c
    }

    func testATurnNeedsTheModelsHost() {
        let needs = AppSettings().sharingNeeds(forTurnWith: remoteModel())
        XCTAssertEqual(needs, [SharingNeed(host: "api.openai.com", purpose: .chat)])
    }

    /// Apple's model runs on the device: nothing to disclose, nothing to ask.
    func testTheOnDeviceModelNeedsNothing() {
        var c = LLMConfig()
        c.wireFormat = .appleOnDevice
        var settings = AppSettings()
        var recipe = SearchRecipe()
        recipe.url = "https://search.example/q"
        settings.recipes = [recipe]
        XCTAssertTrue(settings.sharingNeeds(forTurnWith: c).isEmpty)
    }

    func testSearchCountsOnlyWhileSwitchedOn() {
        var settings = AppSettings()
        var recipe = SearchRecipe()
        recipe.url = "https://search.example/q?x={{query}}"
        settings.recipes = [recipe]
        XCTAssertTrue(settings.sharingNeeds(forTurnWith: remoteModel())
            .contains(SharingNeed(host: "search.example", purpose: .search)))
        settings.searchEnabled = false
        XCTAssertFalse(settings.sharingNeeds(forTurnWith: remoteModel())
            .contains { $0.purpose == .search })
    }

    func testTheRequestGroupsByHost() {
        let request = DataSharingRequest(needs: [
            SharingNeed(host: "a.example", purpose: .chat),
            SharingNeed(host: "b.example", purpose: .search),
            SharingNeed(host: "a.example", purpose: .embedding),
        ])
        XCTAssertEqual(request.byHost.map(\.host), ["a.example", "b.example"])
        XCTAssertEqual(request.byHost.first?.purposes, [.chat, .embedding])
    }
}
