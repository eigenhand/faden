import XCTest
@testable import Faden

/// The shipped provider presets.
///
/// A preset is a promise: “this address is right, do not type it yourself”. A wrong
/// preset is therefore worse than none — the user enters their key, receives a 404 and
/// looks for the mistake in themselves.
///
/// That the eleven addresses really stand was measured before they were entered: a POST
/// without a key has to return 401 or 400, not 404 and no DNS error. That cannot be
/// repeated here without asking eleven foreign services on every test run. What stands
/// here is the part that is testable without a network — and it is exactly the part a
/// later entry gets wrong.
final class BuiltinsTests: XCTestCase {

    func testEveryProviderExceptTheBlankOneHasAnAddress() {
        // The blank preset is the last one; its name is localized, so it is found by position.
        let blank = Builtins.models.filter { $0.baseURL.isEmpty }
        XCTAssertEqual(blank.count, 1, "Nur die leere Vorlage darf ohne Adresse dastehen.")
        XCTAssertEqual(blank.first?.name, Builtins.models.last?.name)
        XCTAssertEqual(blank.first?.name, String(localized: "Eigener Endpoint"))
    }

    /// `endpointURL` glues the address and the path together. A missing slash on the
    /// path or one too many at the end of the address produces a URL that looks like one
    /// and is not the intended one.
    func testEveryProviderProducesAUsableEndpoint() throws {
        for provider in Builtins.models where !provider.baseURL.isEmpty {
            XCTAssertTrue(provider.baseURL.hasPrefix("https://"),
                          "\(provider.name): ohne TLS blockt ATS die Anfrage.")
            XCTAssertFalse(provider.baseURL.hasSuffix("/"),
                           "\(provider.name): der Schraegstrich kommt vom Pfad.")
            XCTAssertTrue(provider.path.hasPrefix("/"), "\(provider.name): Pfad ohne Schraegstrich.")

            let url = try XCTUnwrap(provider.config().endpointURL, provider.name)
            XCTAssertEqual(url.absoluteString, provider.baseURL + provider.path)
        }
    }

    /// The one entry with a different format. If it falls back to OpenAI, the app sends
    /// Anthropic addresses a format they do not speak.
    func testAnthropicKeepsItsOwnFormatAndPath() throws {
        let anthropic = try XCTUnwrap(Builtins.models.first { $0.name == "Anthropic" })
        XCTAssertEqual(anthropic.wireFormat, .anthropic)
        XCTAssertEqual(anthropic.path, "/v1/messages")
        XCTAssertEqual(anthropic.path, LLMConfig.defaultPath(for: .anthropic),
                       "Weicht der Pfad vom Standard ab, ueberschreibt ihn der "
                       + "Formatwechsel in der Oberflaeche.")
    }

    /// A preset becomes a configuration without a model and without a key — both belong
    /// to the user, and a preset that set something here would be the bundled provider
    /// all over again.
    func testAConfigFromATemplateCarriesNoModelAndNoKey() throws {
        let groq = try XCTUnwrap(Builtins.models.first { $0.name == "Groq" })
        let config = groq.config()
        XCTAssertEqual(config.baseURL, "https://api.groq.com/openai")
        XCTAssertTrue(config.model.isEmpty)
        XCTAssertTrue(config.fallbackModel.isEmpty)
        XCTAssertFalse(config.isComplete, "Ohne Modell ist nichts eingerichtet.")
    }

    func testTheNamesAreDistinct() {
        let names = Builtins.models.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "Zwei Vorlagen mit demselben Namen.")
    }
}
