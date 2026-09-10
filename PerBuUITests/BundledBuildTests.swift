import XCTest

/// Checks the build that goes to testers: a key compiled in, everything configured,
/// the model plumbing out of sight.
///
/// Separate from the rest because it needs a different app *and* a different device
/// state — a build carrying keys, installed over an empty store. Guessing at that
/// from inside a test only produced tests that skipped themselves silently, so it is
/// spelled out instead:
///
///     ./run-bundled-tests.sh <udid>
///
/// The everyday suite excludes this class.
final class BundledBuildTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// A build with a key baked in must be usable at once, with no model plumbing
    /// on show — and it must actually answer.
    func testBundledBuildIsReadyAndAnswers() throws {
        guard !app.buttons["Einrichten"].waitForExistence(timeout: 3) else {
            throw XCTSkip("Build ohne eingebetteten Schlüssel")
        }
        XCTAssertTrue(app.staticTexts["BEREIT"].waitForExistence(timeout: 3),
                      "Ein verwalteter Build muss sich selbst eingerichtet haben")

        app.buttons["Einstellungen"].tap()
        XCTAssertTrue(app.staticTexts["WEBSUCHE"].waitForExistence(timeout: 4),
                      "Die Einstellungen sind nicht geöffnet")
        XCTAssertFalse(app.staticTexts["MODELL"].exists,
                       "Der Modell-Abschnitt darf für Tester nicht sichtbar sein")
        shot("Einstellungen ohne Modellauswahl")
        app.buttons["Fertig"].firstMatch.tap()

        // Der eigentliche Beweis: eine echte Anfrage gegen den eingebetteten Key.
        let field = app.textViews.firstMatch.exists
            ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4), "Kein Eingabefeld gefunden")
        field.tap()
        field.typeText("Antworte mit genau einem Wort: Hallo")
        app.buttons["Senden"].tap()

        // Eine Antwort erscheint als Nachricht mit Aktionen darunter.
        let copied = app.buttons["Kopieren"].firstMatch
        XCTAssertTrue(copied.waitForExistence(timeout: 60),
                      "Der eingebettete Schlüssel liefert keine Antwort")
        shot("Echte Antwort mit eingebettetem Schlüssel")
    }

    /// The plus must be there: the bundled model understands images, and with the
    /// model screens hidden there is no way for a tester to switch it on.
    func testImageButtonIsAvailable() throws {
        guard !app.buttons["Einrichten"].waitForExistence(timeout: 3) else {
            throw XCTSkip("Build ohne eingebetteten Schlüssel")
        }
        XCTAssertTrue(app.buttons["Bild hinzufügen"].waitForExistence(timeout: 5),
                      "Der Bildknopf fehlt, obwohl der mitgelieferte Anbieter Bilder versteht")
        shot("Bildknopf vorhanden")
    }

    /// The openers must be questions one can judge at a glance, not category
    /// labels with a hidden prompt behind them — and an empty chat must not offer a
    /// way back to an end that does not exist.
    func testOpenersAreQuestions() throws {
        guard !app.buttons["Einrichten"].waitForExistence(timeout: 3) else {
            throw XCTSkip("Build ohne eingebetteten Schlüssel")
        }
        // Den Zustand herstellen, nicht annehmen: die Tests laufen alphabetisch, und
        // die vorherigen haben Nachrichten gesendet. Ein leerer Chat ist einen Tipp
        // entfernt — dieselbe Lehre wie bei den Fixture-Tests.
        app.buttons["Neue Unterhaltung"].tap()

        let news = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Was ist heute in den Nachrichten")).firstMatch
        XCTAssertTrue(news.waitForExistence(timeout: 5),
                      "Der Öffner steht nicht als Frage da")
        XCTAssertFalse(app.buttons["Etwas erklären"].exists,
                       "Oberbegriffe statt Fragen sind zurück")
        XCTAssertFalse(app.buttons["Zum Ende des Gesprächs springen"].exists,
                       "Im leeren Chat gibt es kein Ende, zu dem man springen könnte")
        shot("Öffner als Fragen")
    }

    /// The model must be able to reach into the memory graph itself.
    func testMemoryToolIsReachable() throws {
        guard !app.buttons["Einrichten"].waitForExistence(timeout: 3) else {
            throw XCTSkip("Build ohne eingebetteten Schlüssel")
        }
        let field = app.textViews.firstMatch.exists
            ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        // Genau die Frage aus dem Alltag, ohne das Werkzeug zu nennen: wenn das
        // Modell hier nicht von selbst nachsieht, nützt das Werkzeug niemandem.
        field.typeText("Was weißt du bislang über mich?")
        app.buttons["Senden"].tap()

        let trace = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Gedächtnis")).firstMatch
        XCTAssertTrue(trace.waitForExistence(timeout: 90),
                      "Das Gedächtnis-Werkzeug wurde nicht aufgerufen")
        shot("Gedächtnis-Werkzeug im Einsatz")
    }

}
