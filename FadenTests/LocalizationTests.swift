import XCTest
@testable import Faden

/// Die Sprachumschaltung.
///
/// Geprueft wird der mechanische Teil: dass beide Sprachen im Bundle liegen und dass
/// ein Schluessel in beiden etwas anderes ergibt. Ob jeder Satz uebersetzt *ist*,
/// prueft `check-localizations.py` bei jedem Push — ein Test kann den Quellkatalog
/// zur Laufzeit nicht sehen.
final class LocalizationTests: XCTestCase {

    /// Das App-Bundle, nicht das des Tests: die Kataloge gehoeren zur App.
    private var app: Bundle {
        let here = Bundle(for: type(of: self))
        return Bundle(url: here.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Faden.app")) ?? .main
    }

    func testBothLanguagesAreInTheBundle() {
        XCTAssertEqual(Set(app.localizations), ["de", "en"])
    }

    func testTheSameKeyReadsDifferentlyInEachLanguage() throws {
        for (key, de, en) in [("Einstellungen", "Einstellungen", "Settings"),
                              ("Oberfläche", "Oberfläche", "Interface"),
                              ("Anbieter hinzufügen", "Anbieter hinzufügen", "Add provider")] {
            XCTAssertEqual(try text(key, in: "de"), de)
            XCTAssertEqual(try text(key, in: "en"), en)
        }
    }

    /// Ein Platzhalter muss die Uebersetzung ueberleben — faellt er weg, fehlt zur
    /// Laufzeit die Zahl, und faellt ein zweiter hinein, stuerzt das Formatieren ab.
    func testPlaceholdersSurviveTranslation() throws {
        XCTAssertEqual(try text("%@ Treffer", in: "en"), "%@ results")
        XCTAssertEqual(try text("%@ · %@ Dimensionen", in: "en"), "%@ · %@ dimensions")
    }

    /// Ein unbekannter Schluessel gibt sich selbst zurueck. Das ist die Zusicherung,
    /// auf der die Wahl deutscher Schluessel beruht: Wer einen Satz vergisst, sieht
    /// Deutsch — und nicht eine leere Zeile.
    func testAnUnknownKeyFallsBackToItself() throws {
        XCTAssertEqual(try text("Diesen Satz gibt es nicht", in: "en"),
                       "Diesen Satz gibt es nicht")
    }

    // MARK: Die Einstellung selbst

    func testSystemMeansTheDeviceDecides() {
        XCTAssertNil(AppLanguage.system.locale)
        XCTAssertNil(AppLanguage.system.code)
        XCTAssertEqual(AppLanguage.german.locale?.identifier, "de")
        XCTAssertEqual(AppLanguage.english.locale?.identifier, "en")
    }

    /// Jede Sprache nennt sich in sich selbst — wer die Oberflaeche gerade nicht
    /// versteht, findet trotzdem den Weg zurueck.
    func testEachLanguageNamesItselfInItsOwnTongue() {
        XCTAssertEqual(AppLanguage.german.label, "Deutsch")
        XCTAssertEqual(AppLanguage.english.label, "English")
    }

    func testTheSettingSurvivesADecodingRound() throws {
        var settings = AppSettings()
        settings.language = .english
        let back = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.language, .english)
    }

    /// Eine Einstellung aus der Zeit vor dieser Funktion kennt das Feld nicht.
    func testAnOlderSettingsFileDefaultsToTheDevice() throws {
        let old = Data(#"{"searchEnabled":true}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: old).language,
                       .system)
    }

    private func text(_ key: String, in language: String) throws -> String {
        let path = try XCTUnwrap(app.path(forResource: language, ofType: "lproj"),
                                 "kein \(language).lproj im App-Bundle")
        let bundle = try XCTUnwrap(Bundle(path: path))
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
