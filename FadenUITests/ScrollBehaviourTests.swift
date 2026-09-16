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
            assertTarget(button, label)
        }
    }

    /// The composer controls, same rule.
    func testComposerTargetsAreLargeEnough() throws {
        // From the app's window and not from `app.buttons`.
        //
        // The keyboard is a window of its own and brings its own buttons, among them a
        // key called “Senden”. `app.buttons` finds that one first, and what would then
        // be measured is a keyboard key instead of the send button. The test only
        // passed for years because it ran on a store without a provider — there is no
        // empty chat there and therefore no keyboard. As soon as somebody ran the suite
        // on a configured device it failed, and with a message about automation types
        // rather than about sizes.
        let send = app.windows.element(boundBy: 0).buttons["Senden"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        assertTarget(send, "Senden")
    }

    /// A 44 pt target, with half a point of leniency.
    ///
    /// The check used to stand at `>= 44` and failed at **43.99999999999994** — six
    /// ten-trillionths of a point too small. The button had not changed, only its
    /// position, and with it the rounding of the accumulated layout arithmetic. An
    /// assertion that reacts to one bit past the fifteenth decimal place is not testing
    /// the hit area but the floating-point representation. Half a point is a third of a
    /// device pixel at @3x — below any threshold a thumb notices, and far above the
    /// noise.
    private func assertTarget(_ element: XCUIElement, _ name: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let f = element.frame
        XCTAssertGreaterThanOrEqual(f.height, 43.5,
                                    "\(name) ist nur \(f.height) pt hoch",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(f.width, 43.5,
                                    "\(name) ist nur \(f.width) pt breit",
                                    file: file, line: line)
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

        // Unasked, the first three stand there — enough to see what the answer rests
        // on, without burying the answer.
        XCTAssertEqual(items.count, 3, "Anfangs gehören drei Quellen sichtbar zu sein")
        shot("Quellen im Ausgangszustand")

        button.tap()
        XCTAssertEqual(items.count, 5, "Aufgeklappt müssen alle fünf dastehen")
        shot("Quellen vollständig")

        // And closed again means fully closed, not back to three.
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

        // And back again. The rule holds in both directions: a saved conversation is
        // opened to be read, not to be typed in.
        try openFixture()
        let gone = expectation(for: NSPredicate(format: "count == 0"),
                               evaluatedWith: app.keyboards)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 4), .completed,
                       "Beim Öffnen einer Unterhaltung muss die Tastatur weichen")
        shot("Zurück im Gespräch, Tastatur unten")
    }

    /// A sheet over a focused composer leaves the keyboard standing.
    ///
    /// It then lies under the history and pushes it up — whoever is looking for a
    /// conversation gets half a list and a keyboard they did not ask for. SwiftUI does
    /// not clear it away by itself when presenting; the app has to do that before it
    /// shows the sheet.
    func testOpeningTheHistoryPutsTheKeyboardAway() throws {
        app.buttons["Neue Unterhaltung"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                      "Im leeren Chat steht die Tastatur bereit — sonst prüft dieser Test nichts.")

        app.buttons["Verlauf"].tap()

        let gone = expectation(for: NSPredicate(format: "count == 0"),
                               evaluatedWith: app.keyboards)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 4), .completed,
                       "Beim Öffnen des Verlaufs muss die Tastatur weichen")
        shot("Verlauf offen, Tastatur unten")

        // Close the sheet again so the next test sees an ordinary chat.
        app.buttons["Fertig"].firstMatch.tap()
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

    /// A long question stays a heading, and Markdown inside it is typeset.
    ///
    /// Since the rebuild the question stands in 20 pt semibold. Whoever pastes an
    /// excerpt filled half the screen with it and pushed the answer — the reason for
    /// the app — below the fold. Three lines, then the rest on request.
    ///
    /// Needs the fixture: `./seed-fixture.sh <udid>` before running.
    func testLongQuestionFoldsToThreeLines() throws {
        try openFixture()

        let auf = app.buttons["Ganze Nachricht zeigen"]
        XCTAssertTrue(auf.waitForExistence(timeout: 4),
                      "Eine lange Frage muss sich aufklappen lassen")

        // The raw asterisks must not stand there — Markdown is typeset, not shown.
        // The check applies to the shortened version as well as the full one.
        XCTAssertFalse(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "**")).firstMatch.exists,
            "In der Frage stehen rohe Markdown-Zeichen")
        shot("Frage auf drei Zeilen")

        auf.tap()
        let zu = app.buttons["Nachricht einklappen"]
        XCTAssertTrue(zu.waitForExistence(timeout: 3),
                      "Aufgeklappt muss sie sich auch wieder einklappen lassen")
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Datenrennsicherheit in dem Zusammenhang")).firstMatch.exists,
            "Aufgeklappt muss der Schluss der Frage sichtbar sein")
        shot("Frage ganz")
    }

    /// Embeddings from two models must not count as one index.
    ///
    /// The mistake this prevents makes no noise: whoever switches the embedding model
    /// keeps the old vectors, and a cosine between two spaces returns numbers that look
    /// like hits. The fixture produces exactly that case — six vectors from the
    /// configured model plus one edge, three from a different model, two without a
    /// stamp from the time before, two with no vector at all.
    ///
    /// Needs the fixture: `./seed-memory.sh <udid>` before running.
    func testIndexClassifiesEmbeddingsByProvenance() throws {
        app.buttons["Einstellungen"].tap()

        let gedaechtnis = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Wissensgraph")).firstMatch
        guard gedaechtnis.waitForExistence(timeout: 4) else {
            throw XCTSkip("Gedächtnis-Fixture fehlt — ./seed-memory.sh <udid> ausführen")
        }
        gedaechtnis.tap()

        let status = app.otherElements["indexStatus"]
        guard status.waitForExistence(timeout: 5) else {
            throw XCTSkip("Kein Index in der Fixture")
        }
        XCTAssertEqual(status.label, "7 nutzbar, 5 fremd, 2 offen",
                       "Die Einstufung nach Herkunft stimmt nicht")
        shot("Index nach Herkunft eingestuft")

        // The foreign ones count towards the work still outstanding — otherwise the
        // index would quietly stay half wrong instead of being replaced at the next
        // catch-up.
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "7 warten auf Einbettung")).firstMatch.exists,
            "Fremde Vektoren müssen wie fehlende behandelt werden")
    }

    /// The attribution stands under the composer — in the same place in every state.
    ///
    /// In the scroll view that did not hold: with four suggestions and the keyboard
    /// open, the line lay behind the composer; with three it was half cut off. The
    /// empty chat with the keyboard is exactly the case that exposes this — so the test
    /// covers it.
    ///
    /// Needs the fixture: `./seed-fixture.sh <udid>` before running.
    func testBrandSitsBelowTheComposer() throws {
        try openFixture()

        let field = app.textViews.firstMatch.exists
            ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4))

        let mark = app.staticTexts["eigenhand.dev"]
        XCTAssertTrue(mark.waitForExistence(timeout: 3),
                      "Im laufenden Gespräch fehlt die Herkunft unter der Eingabezeile")
        XCTAssertGreaterThan(mark.frame.minY, field.frame.maxY,
                             "Die Herkunft muss unter der Eingabezeile stehen, nicht darüber")
        shot("Herkunft unter der Eingabezeile")

        app.buttons["Neue Unterhaltung"].tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 4))
        XCTAssertTrue(mark.waitForExistence(timeout: 3),
                      "Im leeren Chat fehlt die Herkunft")
        XCTAssertGreaterThan(mark.frame.minY, field.frame.maxY,
                             "Auch im leeren Chat gehört sie unter die Eingabezeile")
        XCTAssertLessThan(mark.frame.maxY, keyboard.frame.minY,
                          "Die Zeile darf nicht unter der Tastatur liegen")
        shot("Herkunft im leeren Chat, Tastatur offen")

        // Restore the state rather than leaving it to the next test.
        try openFixture()
    }

    /// A long history is unusable by scrolling — it needs to be searchable.
    ///
    /// Needs the fixture: `./seed-fixture.sh <udid>` before running.
    func testHistoryCanBeSearched() throws {
        try openFixture()
        app.buttons["Verlauf"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4), "Der Verlauf hat kein Suchfeld")

        let row = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Swift 6 Strict Concurrency")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))

        field.tap()
        field.typeText("Concurrency")
        XCTAssertTrue(row.exists, "Der passende Eintrag ist verschwunden")

        // And something that does not match filters it away.
        field.typeText("xyz")
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 4), .completed,
                       "Die Suche filtert nicht")
        shot("Verlauf mit Suche")
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
