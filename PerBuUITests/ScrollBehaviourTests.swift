import XCTest

/// Drives the real app in the simulator. These exist because the parts of this app
/// that are easiest to get wrong — following a streaming answer, keeping a long
/// reply readable — cannot be checked by looking at a screenshot.
final class ScrollBehaviourTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private let traceSummary = "2 Suchen · 1 Seite gelesen · 1 fehlgeschlagen"

    /// Puts the fixture conversation on screen whatever a previous test left behind.
    ///
    /// The tests share one simulator and one store, and the app now opens on a new
    /// empty chat when the last one is stale — so a test that taps "new conversation"
    /// changes where the *next* test lands. Reaching for the fixture through the
    /// history makes each test independent of that order.
    private func openFixture() throws {
        if app.buttons[traceSummary].waitForExistence(timeout: 3) { return }
        app.buttons["Verlauf"].tap()
        let row = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Swift 6 Strict Concurrency")).firstMatch
        guard row.waitForExistence(timeout: 3) else {
            throw XCTSkip("Testdaten fehlen — ./seed-fixture.sh <udid> ausführen")
        }
        row.tap()
        guard app.buttons[traceSummary].waitForExistence(timeout: 3) else {
            throw XCTSkip("Testdaten fehlen — ./seed-fixture.sh <udid> ausführen")
        }
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Scrolling up must reveal the way back, and scrolling back down must retract it.
    ///
    /// Currently skipped: driving a swipe over the transcript makes XCTest snapshot
    /// the whole element tree, and on this view that pins the simulator at 100 % CPU
    /// for minutes and then times out — with and without the follow logic, so it is
    /// the harness rather than the feature. Left in place, and skipped, so it is not
    /// rediscovered from scratch; the follow behaviour is unverified by hand.
    func testJumpToLiveAppearsAfterScrollingAway() throws {
        throw XCTSkip("Wischgesten über das Transkript lasten die Automatisierung aus")

        let jump = app.buttons["Zum Ende des Gesprächs springen"]
        XCTAssertFalse(jump.exists, "Der Knopf darf am unteren Ende nicht sichtbar sein")

        // Scoped to the transcript: a swipe on the application element makes XCTest
        // snapshot the entire tree, which a long answer full of selectable blocks
        // makes prohibitively expensive.
        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        transcript.swipeDown()
        transcript.swipeDown()
        shot("nach dem Hochscrollen")
        XCTAssertTrue(jump.waitForExistence(timeout: 3),
                      "Nach dem Hochscrollen muss der Weg zurück angeboten werden")

        jump.tap()
        shot("nach dem Zurückspringen")
        XCTAssertFalse(jump.waitForExistence(timeout: 2),
                       "Am unteren Ende muss der Knopf wieder verschwinden")
    }

    /// The header actions must be reachable, and each must be at least 44 pt.
    func testHeaderTargetsAreLargeEnough() throws {
        for label in ["Verlauf", "Neue Unterhaltung", "Einstellungen"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists, "\(label) fehlt")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44,
                                        "\(label) ist nur \(button.frame.height) pt hoch")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44,
                                        "\(label) ist nur \(button.frame.width) pt breit")
        }
    }

    /// The composer controls, same rule.
    func testComposerTargetsAreLargeEnough() throws {
        let send = app.buttons["Senden"]
        XCTAssertTrue(send.exists)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44, "Senden ist zu klein")
        XCTAssertGreaterThanOrEqual(send.frame.width, 44, "Senden ist zu schmal")
    }

    /// The trace must stay folded until it is asked for — with the one exception of
    /// a step that failed, which belongs on the surface.
    ///
    /// Needs the fixture: `./seed-fixture.sh <udid>` before running.
    func testToolTraceStaysFoldedUntilAsked() throws {
        try openFixture()
        let summary = app.buttons[traceSummary]
        // Narrow, not `descendants(matching: .any)`: a full-tree query over this
        // view is what made the swipe test time out. A chip combines its children
        // into one element, which lands as a static text.
        let steps = app.staticTexts.matching(identifier: "toolStep")
        XCTAssertEqual(steps.count, 1,
                       "Nur der fehlgeschlagene Schritt gehört vor das Aufklappen")
        shot("Spur zugeklappt")

        summary.tap()
        XCTAssertEqual(steps.count, 4, "Aufgeklappt müssen alle vier Schritte dastehen")
        shot("Spur aufgeklappt")

        summary.tap()
        XCTAssertEqual(steps.count, 1, "Erneutes Tippen muss wieder zuklappen")
    }

    /// Sources must be reachable, but must not be dumped under every answer.
    ///
    /// Needs the fixture: `./seed-fixture.sh <udid>` before running.
    func testSourcesAreOfferedNotDumped() throws {
        try openFixture()
        let button = app.buttons["5 Quellen"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        let items = app.buttons.matching(identifier: "answerSource")

        // Ungefragt stehen die ersten drei da — genug, um zu sehen, worauf die
        // Antwort steht, ohne die Antwort zuzuschütten.
        XCTAssertEqual(items.count, 3, "Anfangs gehören drei Quellen sichtbar zu sein")
        shot("Quellen im Ausgangszustand")

        button.tap()
        XCTAssertEqual(items.count, 5, "Aufgeklappt müssen alle fünf dastehen")
        shot("Quellen vollständig")

        // Und wieder zu heißt ganz zu, nicht zurück auf drei.
        button.tap()
        XCTAssertEqual(items.count, 0, "Zugeklappt darf keine Quelle stehen bleiben")
    }

    /// A first run must land on the one form that makes the app work.
    ///
    /// Run against an empty store: `./seed-fixture.sh` must NOT have run.
    func testFirstRunGoesStraightToProviderForm() throws {
        let setUp = app.buttons["Einrichten"]
        guard setUp.waitForExistence(timeout: 5) else {
            throw XCTSkip("Ablage ist nicht leer — dieser Test braucht einen frischen Zustand")
        }
        setUp.tap()
        XCTAssertTrue(app.navigationBars["Anbieter hinzufügen"].waitForExistence(timeout: 4),
                      "Der Erststart muss ohne Umweg im Anbieter-Formular landen")
        shot("Erststart, direkt im Formular")
    }

    /// The keyboard follows the content, not the launch.
    ///
    /// Needs the fixture: `./seed-fixture.sh <udid>` before running.
    func testKeyboardFollowsContent() throws {
        try openFixture()
        XCTAssertEqual(app.keyboards.count, 0,
                       "Ein Gespräch mit Inhalt darf die Tastatur nicht davorschieben")

        app.buttons["Neue Unterhaltung"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                      "Im leeren Chat muss die Tastatur ohne Zutun bereitstehen")
        shot("Leerer Chat, Tastatur bereit")
    }

    /// A conversation must be passable to someone else — as a file, through the
    /// system's own share sheet, with nothing in between.
    ///
    /// Needs the fixture: `./seed-fixture.sh <udid>` before running.
    func testConversationCanBePassedOn() throws {
        try openFixture()
        app.buttons["Verlauf"].tap()
        let row = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Swift 6 Strict Concurrency")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4), "Der Verlauf zeigt die Unterhaltung nicht")

        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Weitergeben"].waitForExistence(timeout: 5),
                      "Im Verlauf fehlt das Weitergeben")
        shot("Weitergeben im Verlauf")
    }

    /// The header carries three things, and the voice mode steps aside as soon as
    /// there is something typed.
    ///
    /// Needs the fixture: `./seed-fixture.sh <udid>` before running.
    func testHeaderIsTrimmedAndVoiceStepsAside() throws {
        try openFixture()

        XCTAssertTrue(app.buttons["Verlauf"].exists)
        XCTAssertTrue(app.buttons["Neue Unterhaltung"].exists)
        XCTAssertTrue(app.buttons["Einstellungen"].exists)
        XCTAssertFalse(app.buttons["Gedächtnis"].exists,
                       "Das Gemerkte gehört in die Einstellungen, nicht in die Kopfzeile")

        let voice = app.buttons["Sprachmodus"]
        guard voice.waitForExistence(timeout: 4) else {
            throw XCTSkip("Sprachmodus nicht verfügbar")
        }
        shot("Eingabezeile mit Sprachmodus")

        let field = app.textViews.firstMatch.exists
            ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        field.typeText("H")

        let gone = expectation(for: NSPredicate(format: "exists == false"),
                               evaluatedWith: voice)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 4), .completed,
                       "Nach dem ersten Buchstaben muss der Sprachmodus verschwinden")
        XCTAssertTrue(app.buttons["Senden"].exists, "Senden muss bleiben")
        shot("Nach dem ersten Buchstaben")
    }

    /// Code offered in an answer must be takeable in one tap.
    func testCodeBlockCanBeCopied() throws {
        try openFixture()
        let copyCode = app.buttons["Code kopieren"]
        XCTAssertTrue(copyCode.waitForExistence(timeout: 3), "Kein Kopier-Knopf am Code-Block")
        copyCode.tap()
        XCTAssertTrue(app.buttons["Code kopiert"].waitForExistence(timeout: 2),
                      "Das Kopieren wird nicht bestätigt")
        shot("Code kopiert")
    }
}
