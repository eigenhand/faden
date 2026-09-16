import XCTest

/// Der Sprachwechsel am laufenden Gerät.
///
/// Die Unittests zeigen, dass beide Sprachen im Bundle liegen und dass der Lookup
/// stimmt. Das ist nicht dasselbe wie die Frage, um die es geht: ob ein Wechsel in
/// den Einstellungen die Oberfläche tatsächlich umstellt. Daran hängt genau eine
/// Stelle — `AppLanguage.apply` an der Wurzel — und wenn sie jemand entfernt, bleibt
/// alles grün, bis auf diesen Test.
final class LanguageSwitchTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Lässt die App auf Deutsch zurück, egal woran der Test scheitert.
    ///
    /// Alle Tests teilen sich einen Simulator und einen Speicher, und die Wahl
    /// überlebt einen Neustart — eine englische App wäre sonst das Erbe für jeden
    /// folgenden Test. Genau das ist einmal passiert und hat eine halbe Stunde
    /// Fehlersuche an der falschen Stelle gekostet.
    override func tearDownWithError() throws {
        continueAfterFailure = true
        guard app.state == .runningForeground else { return }
        if app.buttons["Settings"].waitForExistence(timeout: 2) {
            try? choose("Deutsch", from: "Settings")
        } else if !app.buttons["Einstellungen"].exists {
            try? choose("Deutsch", from: nil)
        }
    }

    func testSwitchingToEnglishRelabelsTheInterface() throws {
        XCTAssertTrue(app.buttons["Einstellungen"].waitForExistence(timeout: 5))

        try choose("English", from: "Einstellungen")
        let picker = app.buttons["language-picker"]

        // Geprüft wird am Wähler selbst, und das hat einen Grund, der in diesem
        // Projekt noch Arbeit ist: Überschriften laufen durch `EH.label`, das den
        // Text in Großbuchstaben setzt und ihn dabei aus der Übersetzung nimmt, und
        // die Knöpfe der Kopfzeile tragen ihre Beschriftung als Barrierefreiheits-
        // Text, der ebenfalls nicht im Katalog landet. Beide waren die ersten
        // Kandidaten für diesen Test, und beide waren rot, obwohl der Code stimmte.
        XCTAssertTrue(label(of: picker).contains("English"),
                      "Der Wähler steht nicht auf English: \(label(of: picker))")
        XCTAssertTrue(label(of: picker).contains("Language"),
                      "Die Beschriftung ist weiterhin deutsch: \(label(of: picker))")

        // Und zurück, ohne die App neu zu starten: die Umstellung wirkt sofort.
        try choose("Deutsch", from: nil)
        XCTAssertTrue(label(of: picker).contains("Sprache"),
                      "Zurück auf Deutsch hat nicht gewirkt: \(label(of: picker))")
    }

    /// Die Wahl überlebt einen Neustart — sie liegt in den Einstellungen und nicht
    /// nur in der Ansicht.
    func testTheChoiceSurvivesARestart() throws {
        try choose("English", from: "Einstellungen")
        app.terminate()
        app.launch()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5)
                      || app.buttons["Einstellungen"].waitForExistence(timeout: 5))
        try open(settings: app.buttons["Settings"].exists ? "Settings" : "Einstellungen")
        XCTAssertTrue(label(of: app.buttons["language-picker"]).contains("English"),
                      "Nach dem Neustart steht die Wahl nicht mehr auf English.")
    }

    private func label(of element: XCUIElement) -> String {
        _ = element.waitForExistence(timeout: 3)
        return element.label
    }

    /// Öffnet die Einstellungen (wenn nötig), stellt den Wähler auf `value` und
    /// lässt das Blatt offen.
    ///
    /// Angesteuert wird über eine Kennung, nicht über die Beschriftung: Die heißt
    /// nach dem Wechsel anders, und ein Test, der sie sucht, prüfte sich selbst.
    private func choose(_ value: String, from settingsButton: String?) throws {
        if let settingsButton {
            try open(settings: settingsButton)
        }
        let picker = app.buttons["language-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Kein Sprachwähler.")

        // Der Abschnitt steht unten in einer langen Liste — vorhanden ist er sofort,
        // antippbar erst, wenn er auch auf dem Schirm steht.
        for _ in 0..<8 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.isHittable, "Sprachwähler nicht erreichbar.")
        picker.tap()

        let option = app.buttons[value]
        XCTAssertTrue(option.waitForExistence(timeout: 3), "Keine Auswahl „\(value)“.")
        option.tap()
    }

    private func open(settings button: String) throws {
        let entry = app.buttons[button]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Kein Knopf „\(button)“.")
        entry.tap()
    }
}
