import XCTest
@testable import Faden

/// Switching the language.
///
/// What is checked is the mechanical part: that both languages lie in the bundle and
/// that a key yields something different in each. Whether every sentence *is* translated
/// is what `check-localizations.py` checks on every push — a test cannot see the source
/// catalogue at runtime.
final class LocalizationTests: XCTestCase {

    /// The app bundle, not the test's: the catalogues belong to the app.
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

    /// A placeholder has to survive the translation — if it falls away, the number is
    /// missing at runtime, and if a second one falls in, the formatting crashes.
    func testPlaceholdersSurviveTranslation() throws {
        // `%lld` and not `%@`: the key arises from the format the interpolation
        // produces, and a number becomes `%lld`. Keys entered by hand with `%@` looked
        // right and never matched.
        XCTAssertEqual(try text("%lld Treffer", in: "en"), "%lld results")
        XCTAssertEqual(try text("%@ · %lld Dimensionen", in: "en"), "%@ · %lld dimensions")
    }

    /// An unknown key returns itself. That is the guarantee the choice of German keys
    /// rests on: whoever forgets a sentence sees German — and not an empty line.
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

    /// Every language names itself — whoever does not currently understand the
    /// interface still finds the way back.
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

    /// A settings file from before this feature does not know the field.
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
