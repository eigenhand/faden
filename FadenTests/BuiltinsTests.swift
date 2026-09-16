import XCTest
@testable import Faden

/// Die mitgelieferten Anbieter-Vorlagen.
///
/// Eine Vorlage ist ein Versprechen: „diese Adresse stimmt, tipp sie nicht selbst".
/// Eine falsche Vorlage ist deshalb schlimmer als keine — der Nutzer traegt seinen
/// Schluessel ein, bekommt einen 404 und sucht den Fehler bei sich.
///
/// Dass die elf Adressen wirklich stehen, ist vor dem Eintragen gemessen worden: ein
/// POST ohne Schluessel muss 401 oder 400 liefern, nicht 404 und keinen DNS-Fehler.
/// Das laesst sich hier nicht wiederholen, ohne bei jedem Testlauf elf fremde Dienste
/// anzufragen. Was hier steht, ist der Teil, der ohne Netz pruefbar ist — und es ist
/// genau der Teil, an dem ein spaeterer Eintrag danebengreift.
final class BuiltinsTests: XCTestCase {

    func testEveryProviderExceptTheBlankOneHasAnAddress() {
        for provider in Builtins.models where provider.baseURL.isEmpty {
            XCTAssertEqual(provider.name, "Eigener Endpoint",
                           "Nur die leere Vorlage darf ohne Adresse dastehen.")
        }
        XCTAssertEqual(Builtins.models.filter { $0.baseURL.isEmpty }.count, 1)
    }

    /// `endpointURL` klebt Adresse und Pfad zusammen. Ein fehlender Schraegstrich am
    /// Pfad oder einer zu viel am Ende der Adresse ergibt eine URL, die aussieht wie
    /// eine und nicht die gemeinte ist.
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

    /// Der eine Eintrag mit einem anderen Format. Faellt er auf OpenAI zurueck,
    /// schickt die App Anthropic-Adressen ein Format, das sie nicht sprechen.
    func testAnthropicKeepsItsOwnFormatAndPath() throws {
        let anthropic = try XCTUnwrap(Builtins.models.first { $0.name == "Anthropic" })
        XCTAssertEqual(anthropic.wireFormat, .anthropic)
        XCTAssertEqual(anthropic.path, "/v1/messages")
        XCTAssertEqual(anthropic.path, LLMConfig.defaultPath(for: .anthropic),
                       "Weicht der Pfad vom Standard ab, ueberschreibt ihn der "
                       + "Formatwechsel in der Oberflaeche.")
    }

    /// Aus einer Vorlage wird eine Konfiguration ohne Modell und ohne Schluessel —
    /// beides gehoert dem Nutzer, und eine Vorlage, die hier etwas vorgibt, waere
    /// wieder der mitgelieferte Anbieter.
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
