import XCTest

/// Switching the language on a running device.
///
/// The unit tests show that both languages lie in the bundle and that the lookup is
/// right. That is not the same as the question this is about: whether a switch in the
/// settings actually changes the interface. Exactly one place carries that —
/// `AppLanguage.apply` at the root — and if somebody removes it, everything stays green
/// except this test.
final class LanguageSwitchTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Leaves the app in German, whatever the test fails on.
    ///
    /// All tests share one simulator and one store, and the choice survives a restart —
    /// an English app would otherwise be the inheritance for every following test. That
    /// is exactly what happened once and cost half an hour of debugging in the wrong
    /// place.
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

        // The check is made on the picker itself, and there is a reason for that
        // which is still work in this project: headings run through `EH.label`, which
        // sets the text in capitals and in doing so takes it out of the translation,
        // and the header buttons carry their label as accessibility text, which also
        // never lands in the catalogue. Both were the first candidates for this test,
        // and both were red although the code was right.
        XCTAssertTrue(label(of: picker).contains("English"),
                      "Der Wähler steht nicht auf English: \(label(of: picker))")
        XCTAssertTrue(label(of: picker).contains("Language"),
                      "Die Beschriftung ist weiterhin deutsch: \(label(of: picker))")

        // And the header behind it. It carries its label as accessibility text, and
        // until `headerButton` was switched to `LocalizedStringKey` that went past the
        // catalogue — it stayed German while the app had long been English.
        XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 3),
                      "Der Verlaufs-Knopf heißt weiterhin „Verlauf“.")
        XCTAssertFalse(app.buttons["Verlauf"].exists)

        // And back, without restarting the app: the switch takes effect at once.
        try choose("Deutsch", from: nil)
        XCTAssertTrue(label(of: picker).contains("Sprache"),
                      "Zurück auf Deutsch hat nicht gewirkt: \(label(of: picker))")
        XCTAssertTrue(app.buttons["Verlauf"].waitForExistence(timeout: 3))
    }

    /// The choice survives a restart — it lies in the settings and not only in the
    /// view.
    ///
    /// The check is made on the header button and not on the picker again: that one
    /// sits at the bottom of a long list behind a sheet which would first have to be
    /// opened and scrolled again after the restart, and on exactly that this test was
    /// red twice without anything being wrong with the code. The button says the same
    /// thing and stands there at once.
    func testTheChoiceSurvivesARestart() throws {
        try startInGerman()
        try choose("English", from: "Einstellungen")
        app.terminate()
        app.launch()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5),
                      "Nach dem Neustart steht die App wieder auf Deutsch.")
        XCTAssertFalse(app.buttons["Einstellungen"].exists)
    }

    /// Establishes the starting state rather than assuming it.
    ///
    /// The choice lies in the settings and survives a restart — so the previous test as
    /// well. On exactly that this one was red: it began with “the button is called
    /// Einstellungen”, and the button was called Settings, because a run before it had
    /// been cut short. A test that inherits its predecessor's state no longer checks
    /// what it claims to.
    private func startInGerman() throws {
        if app.buttons["Einstellungen"].waitForExistence(timeout: 5) { return }
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5),
                      "Weder „Einstellungen“ noch „Settings“ — die App ist nicht da.")
        try choose("Deutsch", from: "Settings")
        // Restart rather than close the sheet: afterwards the state is the same as on
        // a first run, and not “just switched”.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Einstellungen"].waitForExistence(timeout: 5))
    }

    private func label(of element: XCUIElement) -> String {
        _ = element.waitForExistence(timeout: 3)
        return element.label
    }

    /// Opens the settings (if needed), sets the picker to `value` and leaves the sheet
    /// open.
    ///
    /// Addressed by an identifier, not by the label: the label is called something else
    /// after the switch, and a test that looks for it would be testing itself.
    private func choose(_ value: String, from settingsButton: String?) throws {
        if let settingsButton {
            try open(settings: settingsButton)
        }
        let picker = app.buttons["language-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Kein Sprachwähler.")

        // The section stands at the bottom of a long list — it exists at once, but is
        // only tappable when it is actually on screen.
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
