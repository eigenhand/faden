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
        try startInGerman()

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

        // Und die Kopfzeile dahinter. Sie trägt ihre Beschriftung als
        // Barrierefreiheits-Text, und der ging bis zur Umstellung von
        // `headerButton` auf `LocalizedStringKey` am Katalog vorbei — er blieb
        // deutsch, während die App längst englisch war.
        XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 3),
                      "Der Verlaufs-Knopf heißt weiterhin „Verlauf“.")
        XCTAssertFalse(app.buttons["Verlauf"].exists)

        // Und zurück, ohne die App neu zu starten: die Umstellung wirkt sofort.
        try choose("Deutsch", from: nil)
        XCTAssertTrue(label(of: picker).contains("Sprache"),
                      "Zurück auf Deutsch hat nicht gewirkt: \(label(of: picker))")
        XCTAssertTrue(app.buttons["Verlauf"].waitForExistence(timeout: 3))
    }

    /// Die Wahl überlebt einen Neustart — sie liegt in den Einstellungen und nicht
    /// nur in der Ansicht.
    ///
    /// Geprüft wird am Knopf der Kopfzeile und nicht noch einmal am Wähler: Der
    /// steht unten in einer langen Liste hinter einem Blatt, das nach dem Neustart
    /// erst wieder geöffnet und gescrollt werden müsste, und genau daran war dieser
    /// Test zweimal rot, ohne dass am Code etwas falsch war. Der Knopf sagt
    /// dasselbe und steht sofort da.
    func testTheChoiceSurvivesARestart() throws {
        try startInGerman()
        try choose("English", from: "Einstellungen")
        app.terminate()
        app.launch()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5),
                      "Nach dem Neustart steht die App wieder auf Deutsch.")
        XCTAssertFalse(app.buttons["Einstellungen"].exists)
    }

    /// Stellt den Startzustand her, statt ihn anzunehmen.
    ///
    /// Die Wahl liegt in den Einstellungen und überlebt einen Neustart — also auch
    /// den vorigen Test. Genau daran war dieser hier rot: Er begann mit „der Knopf
    /// heißt Einstellungen“, und der Knopf hieß Settings, weil ein Lauf davor
    /// abgebrochen war. Ein Test, der den Zustand seines Vorgängers erbt, prüft
    /// nicht mehr, was er behauptet.
    private func startInGerman() throws {
        if app.buttons["Einstellungen"].waitForExistence(timeout: 5) { return }
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5),
                      "Weder „Einstellungen“ noch „Settings“ — die App ist nicht da.")
        try choose("Deutsch", from: "Settings")
        // Neu starten statt das Blatt zu schließen: danach ist der Zustand derselbe
        // wie bei einem ersten Lauf, und nicht „gerade umgestellt“.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Einstellungen"].waitForExistence(timeout: 5))
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
