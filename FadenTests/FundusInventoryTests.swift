import XCTest
@testable import Faden

/// Reading the stock Fundus keeps.
///
/// What is checked here is the half that can go wrong silently. Faden reads a file a
/// second app writes, on a device where the two are updated separately — so the
/// decoding has to survive a schema it does not know, and the search has to be strict
/// enough that "USB Kabel" does not return every cable and every USB stick in the
/// house. Both failures look like a working app: one loses entries, the other buries
/// the right answer at position nine.
final class FundusInventoryTests: XCTestCase {

    // MARK: Fixtures

    private let keller = UUID()
    private let regal = UUID()
    private let werkstatt = UUID()

    private func inventory(_ items: [FundusItem]) -> FundusInventory {
        var inv = FundusInventory()
        inv.places = [
            FundusPlace(id: keller, name: "Keller", parentID: nil),
            FundusPlace(id: regal, name: "Regal links", parentID: keller),
            FundusPlace(id: werkstatt, name: "Werkstatt", parentID: nil),
        ]
        inv.items = items
        return inv
    }

    private func item(_ name: String, at place: UUID? = nil, quantity: Int? = nil,
                      unit: String = "", note: String = "", tags: [String] = [],
                      code: FundusCode? = nil, seen: Date? = nil) -> FundusItem {
        FundusItem(id: UUID(), name: name, quantity: quantity, unit: unit, note: note,
                   placeID: place, tags: tags, code: code, lastSeenAt: seen)
    }

    // MARK: Decoding

    /// The normal case, and the fields that carry meaning rather than bulk.
    func testAnInventoryIsReadWithItsPlaces() throws {
        let json = """
        {
          "items": [
            {"id": "11111111-1111-1111-1111-111111111111", "name": "USB-C-Kabel",
             "quantity": 3, "unit": "", "note": "weiß, 1 m", "tags": ["kabel"],
             "lastSeenAt": "2026-03-12T10:00:00Z",
             "code": {"value": "MP1584EN", "kind": "manufacturer", "origin": "read"}}
          ],
          "places": [
            {"id": "22222222-2222-2222-2222-222222222222", "name": "Keller"}
          ]
        }
        """
        let inv = try XCTUnwrap(FundusInventory.decode(Data(json.utf8)))
        XCTAssertEqual(inv.items.count, 1)
        XCTAssertEqual(inv.items[0].name, "USB-C-Kabel")
        XCTAssertEqual(inv.items[0].quantity, 3)
        XCTAssertEqual(inv.items[0].code?.value, "MP1584EN")
        XCTAssertEqual(inv.places.count, 1)
    }

    /// The vectors are the largest part of the file and the one part Faden has no use
    /// for. Reading them and then holding them would be the whole inventory a second
    /// time in memory, per turn.
    func testTheEmbeddingIsParsedAndNotKept() throws {
        let json = """
        {"items": [{"name": "Lötzinn", "embedding": [0.1, 0.2, 0.3],
                    "photoIDs": ["a.jpg"], "embeddingStamp": {"model": "x"}}]}
        """
        let inv = try XCTUnwrap(FundusInventory.decode(Data(json.utf8)))
        XCTAssertEqual(inv.items.count, 1)
        XCTAssertEqual(inv.items[0].name, "Lötzinn")
    }

    /// A Fundus newer than this build is the ordinary case, not an edge one: the user
    /// updates the two apps on different days. A field that changed shape has to cost
    /// that field — not the entry, and above all not the inventory.
    func testAFieldOfTheWrongTypeCostsOnlyThatField() throws {
        let json = """
        {"items": [{"name": "Schrauben", "quantity": {"amount": 40, "unit": "Stück"},
                    "tags": "kein Array"}]}
        """
        let inv = try XCTUnwrap(FundusInventory.decode(Data(json.utf8)))
        XCTAssertEqual(inv.items.count, 1, "Der Eintrag bleibt.")
        XCTAssertEqual(inv.items[0].name, "Schrauben")
        XCTAssertNil(inv.items[0].quantity, "Ungezählt ist die ehrliche Antwort, nicht 0.")
        XCTAssertEqual(inv.items[0].tags, [])
    }

    func testAnUnreadableEntryDoesNotTakeTheOthersWithIt() throws {
        let json = """
        {"items": [{"name": "Erstes"}, ["kein Objekt"], {"name": "Drittes"}]}
        """
        let inv = try XCTUnwrap(FundusInventory.decode(Data(json.utf8)))
        XCTAssertEqual(inv.items.map(\.name), ["Erstes", "Drittes"])
    }

    func testAnEntryWithoutANameIsDropped() throws {
        let json = #"{"items": [{"note": "nur eine Notiz"}, {"name": "Zange"}]}"#
        let inv = try XCTUnwrap(FundusInventory.decode(Data(json.utf8)))
        XCTAssertEqual(inv.items.map(\.name), ["Zange"])
    }

    /// Anything that is not literally "scanned" is a guess, and the answer has to say
    /// so. An unknown value falls to the cautious side, not the convenient one.
    func testOnlyAScannedCodeCountsAsExact() throws {
        let json = """
        {"items": [
          {"name": "A", "code": {"value": "4006381333931", "kind": "ean", "origin": "scanned"}},
          {"name": "B", "code": {"value": "BC547B", "kind": "manufacturer", "origin": "read"}},
          {"name": "C", "code": {"value": "X", "kind": "was-auch-immer"}}
        ]}
        """
        let inv = try XCTUnwrap(FundusInventory.decode(Data(json.utf8)))
        XCTAssertEqual(inv.items[0].code?.scanned, true)
        XCTAssertEqual(inv.items[0].code?.label, "EAN")
        XCTAssertEqual(inv.items[1].code?.scanned, false)
        XCTAssertEqual(inv.items[1].code?.label, "Herstellernummer")
        XCTAssertEqual(inv.items[2].code?.scanned, false, "Unbekannt heißt fehlbar.")
    }

    func testRubbishIsNotAnInventory() {
        XCTAssertNil(FundusInventory.decode(Data("kein JSON".utf8)))
    }

    // MARK: Places

    func testAPlacePathReadsFromTheTopDown() {
        let inv = inventory([])
        XCTAssertEqual(inv.path(of: regal), "Keller › Regal links")
        XCTAssertEqual(inv.path(of: keller), "Keller")
        XCTAssertNil(inv.path(of: nil))
        XCTAssertNil(inv.path(of: UUID()), "Ein Ort, den es nicht gibt, hat keinen Pfad.")
    }

    /// A `parentID` chain is a tree only as long as the file is sound. One cycle — from
    /// a half-written save or a hand-edited file — would otherwise hang the turn, and a
    /// hung turn looks to the user like a broken model.
    func testACycleInThePlacesDoesNotHang() {
        var inv = FundusInventory()
        let a = UUID(), b = UUID()
        inv.places = [FundusPlace(id: a, name: "A", parentID: b),
                      FundusPlace(id: b, name: "B", parentID: a)]
        XCTAssertNotNil(inv.path(of: a))
    }

    func testAPlaceHoldsWhatStandsBelowIt() {
        let inv = inventory([item("Kabel", at: regal), item("Hammer", at: werkstatt)])
        XCTAssertEqual(inv.itemCount(in: keller), 1, "Das Regal zählt zum Keller.")
        XCTAssertEqual(inv.itemCount(in: werkstatt), 1)
        XCTAssertEqual(inv.subtree(of: keller), [keller, regal])
    }

    /// Two shelves can carry the same name, and picking one of them would put a wrong
    /// shelf into an answer that sounds certain.
    func testAnAmbiguousPlaceNameStaysAmbiguous() {
        var inv = inventory([])
        let zweites = UUID()
        inv.places.append(FundusPlace(id: zweites, name: "Regal links", parentID: werkstatt))
        XCTAssertEqual(inv.places(matching: "Regal links").count, 2)
        XCTAssertEqual(inv.places(matching: "Keller Regal").map(\.id), [regal],
                       "Über den vollen Pfad wird es wieder eindeutig.")
    }

    /// Matching against the path means a name high in the tree matches everything below
    /// it too. Naming all of them would read as though several places were searched.
    func testAMatchInsideAnotherMatchIsNotNamedTwice() {
        var inv = inventory([])
        inv.places.append(FundusPlace(id: UUID(), name: "Kellerraum", parentID: nil))
        // "keller" hits Keller, "Keller › Regal links" and "Kellerraum" — but the
        // shelf already lies inside the cellar.
        XCTAssertEqual(Set(inv.places(matching: "keller-").map(\.name)), [],
                       "Ein Bindestrich gehört zu keinem dieser Namen.")
        let matched = inv.places(matching: "kelle")
        XCTAssertEqual(Set(matched.map(\.name)), ["Keller", "Kellerraum"])
    }

    func testAPlaceIsFoundWithoutCapitalsAndAccents() {
        let inv = inventory([])
        XCTAssertEqual(inv.places(matching: "keller").map(\.id), [keller])
    }

    // MARK: Searching

    /// Without this rule a two-word query returns everything matching either word, and
    /// the list stops meaning anything at the third entry.
    func testEveryWordOfTheQueryHasToLand() {
        let inv = inventory([item("USB-C-Kabel", at: regal),
                             item("USB-Stick", at: regal),
                             item("Netzkabel", at: regal)])
        let hits = inv.search("usb kabel").hits.map(\.item.name)
        XCTAssertEqual(hits, ["USB-C-Kabel"])
    }

    func testTheNameOutranksTheNote() {
        let inv = inventory([item("Schublade", at: regal, note: "darin liegt ein Hammer"),
                             item("Hammer", at: werkstatt)])
        XCTAssertEqual(inv.search("hammer").hits.first?.item.name, "Hammer")
        XCTAssertEqual(inv.search("hammer").total, 2, "Die Notiz zählt trotzdem.")
    }

    /// Whoever types a part number wants that part, not something like it.
    func testANumberFindsItsThing() {
        let code = FundusCode(value: "MP1584EN", kind: "manufacturer", scanned: false)
        let inv = inventory([item("Platine", at: regal, code: code),
                             item("Platinen-Sortiment", at: regal)])
        XCTAssertEqual(inv.search("MP1584EN").hits.map(\.item.name), ["Platine"])
    }

    func testTagsAreSearchedToo() {
        let inv = inventory([item("Litze", at: regal, tags: ["kabel", "rot"])])
        XCTAssertEqual(inv.search("kabel").total, 1)
    }

    func testASearchIsRestrictedToAPlaceAndEverythingUnderIt() {
        let inv = inventory([item("Kabel", at: regal), item("Kabel", at: werkstatt)])
        XCTAssertEqual(inv.search("kabel", place: "Keller").total, 1,
                       "Das Regal gehört dazu, die Werkstatt nicht.")
        XCTAssertEqual(inv.search("kabel").total, 2)
    }

    /// "What is in the cellar" is a listing, not a search — and the common case rather
    /// than a degenerate one.
    func testAPlaceAloneListsWhatIsThere() {
        let inv = inventory([item("Kabel", at: regal), item("Farbe", at: keller),
                             item("Hammer", at: werkstatt)])
        let lookup = inv.search("", place: "Keller")
        XCTAssertEqual(lookup.total, 2)
        XCTAssertEqual(lookup.places, ["Keller"])
    }

    func testAPlaceThatDoesNotExistFindsNothingRatherThanEverything() {
        let inv = inventory([item("Kabel", at: regal)])
        XCTAssertEqual(inv.search("kabel", place: "Dachboden").total, 0)
    }

    func testThingsWithoutAPlaceAreStillFound() {
        let inv = inventory([item("Kabel")])
        let hit = inv.search("kabel").hits.first
        XCTAssertNotNil(hit)
        XCTAssertNil(hit?.path)
    }

    func testTheLimitCapsTheListButNotTheCount() {
        let inv = inventory((1...30).map { item("Schraube \($0)", at: regal) })
        let lookup = inv.search("schraube", limit: 10)
        XCTAssertEqual(lookup.hits.count, 10)
        XCTAssertEqual(lookup.total, 30)
    }

    // MARK: Rendering

    func testALineCarriesPlaceAmountNoteAndCode() {
        let code = FundusCode(value: "MP1584EN", kind: "manufacturer", scanned: false)
        let inv = inventory([item("Platine", at: regal, quantity: 3, note: "3-A-Wandler",
                                  code: code, seen: date(2026, 3, 12))])
        let text = FundusInventory.render(inv.search("platine"), query: "platine", place: nil)

        XCTAssertTrue(text.contains("Keller › Regal links — Platine"))
        XCTAssertTrue(text.contains("3×"))
        XCTAssertTrue(text.contains("3-A-Wandler"))
        XCTAssertTrue(text.contains("Herstellernummer MP1584EN (abgelesen)"))
        XCTAssertTrue(text.contains("bestätigt 12.03.26"))
    }

    /// The mark is the difference between a number worth searching for and one worth
    /// checking first. A scanned code carries no caveat, because it needs none.
    func testAScannedCodeCarriesNoCaveat() {
        let code = FundusCode(value: "4006381333931", kind: "ean", scanned: true)
        let inv = inventory([item("Stift", at: regal, code: code)])
        let text = FundusInventory.render(inv.search("stift"), query: "stift", place: nil)
        XCTAssertTrue(text.contains("EAN 4006381333931"))
        XCTAssertFalse(text.contains("abgelesen"))
    }

    /// An invented 1 would be a number that looks like a count.
    func testAMissingQuantityBecomesNothingAtAll() {
        let inv = inventory([item("Schrauben", at: regal, note: "eine Schachtel voll")])
        let text = FundusInventory.render(inv.search("schrauben"), query: "schrauben", place: nil)
        XCTAssertTrue(text.contains("Schrauben · eine Schachtel voll"))
        XCTAssertFalse(text.contains("0"))
        XCTAssertFalse(text.contains("1×"))
    }

    func testAUnitIsKeptWithItsNumber() {
        let inv = inventory([item("Litze", at: regal, quantity: 5, unit: "m")])
        let text = FundusInventory.render(inv.search("litze"), query: "litze", place: nil)
        XCTAssertTrue(text.contains("Litze · 5 m"))
    }

    func testAThingWithoutAPlaceSaysSo() {
        let inv = inventory([item("Kabel")])
        let text = FundusInventory.render(inv.search("kabel"), query: "kabel", place: nil)
        XCTAssertTrue(text.hasSuffix("ohne Ort — Kabel"), text)
    }

    /// Saying how many were cut is what keeps the model from answering "you have ten"
    /// off a list that was capped at ten.
    func testWhatWasCutIsNamed() {
        let inv = inventory((1...30).map { item("Schraube \($0)", at: regal) })
        let text = FundusInventory.render(inv.search("schraube", limit: 10),
                                          query: "schraube", place: nil)
        XCTAssertTrue(text.contains("30 Einträge"))
        XCTAssertTrue(text.contains("20 weitere"))
    }

    func testNothingFoundIsSaidPlainly() {
        let inv = inventory([item("Kabel", at: regal)])
        let text = FundusInventory.render(inv.search("gitarre"), query: "gitarre", place: nil)
        XCTAssertTrue(text.contains("Nichts im Inventar passt auf „gitarre“."), text)
    }

    func testTheHeaderNamesThePlaceThatWasSearched() {
        let inv = inventory([item("Kabel", at: regal)])
        let text = FundusInventory.render(inv.search("kabel", place: "Keller"),
                                          query: "kabel", place: "Keller")
        XCTAssertTrue(text.hasPrefix("1 Eintrag zu „kabel“ in „Keller“:"), text)
    }

    /// A listing has no subject to be "about". One sentence carrying both cases is how
    /// "Einträge zu Dinge in „Keller“" gets written.
    func testAListingDoesNotPretendToBeASearch() {
        let inv = inventory([item("Kabel", at: regal), item("Farbe", at: keller)])
        let listing = FundusInventory.render(inv.search("", place: "Keller"),
                                             query: "", place: "Keller")
        XCTAssertTrue(listing.hasPrefix("2 Einträge in „Keller“:"), listing)

        let all = FundusInventory.render(inv.search(""), query: "", place: nil)
        XCTAssertTrue(all.hasPrefix("2 Einträge im Bestand:"), all)
    }

    /// The place Fundus knows, not the word that was typed — the header is what tells
    /// the reader which shelf was meant.
    func testTheHeaderNamesTheFullPathOfThePlace() {
        var inv = inventory([])
        let kiste = UUID()
        inv.places.append(FundusPlace(id: kiste, name: "Kiste Elektronik", parentID: regal))
        inv.items = [item("Kabel", at: kiste)]

        let text = FundusInventory.render(inv.search("", place: "Kiste"),
                                          query: "", place: "Kiste")
        XCTAssertTrue(text.hasPrefix("1 Eintrag in „Keller › Regal links › Kiste Elektronik“:"),
                      text)
    }

    func testAnEmptyPlaceIsNotAFailedSearch() {
        let inv = inventory([item("Hammer", at: werkstatt)])
        let text = FundusInventory.render(inv.search("", place: "Keller"),
                                          query: "", place: "Keller")
        XCTAssertEqual(text, "Im Bestand steht nichts in „Keller“.")
    }

    /// The counts are the useful half: they tell the model where looking is worth it,
    /// which turns a second call into a narrow one instead of a broad one.
    func testThePlaceListingCountsWhatStandsBelowEachPlace() {
        let inv = inventory([item("Kabel", at: regal), item("Farbe", at: keller),
                             item("Hammer", at: werkstatt), item("Zettel")])
        let text = inv.renderPlaces()
        XCTAssertTrue(text.contains("Keller (2)"), text)
        XCTAssertTrue(text.contains("Keller › Regal links (1)"), text)
        XCTAssertTrue(text.contains("Werkstatt (1)"), text)
        XCTAssertTrue(text.contains("Ohne Ort: 1"), text)
    }

    func testAnInventoryWithoutPlacesSaysThatRatherThanNothing() {
        var inv = FundusInventory()
        inv.items = [item("Kabel"), item("Zange")]
        XCTAssertTrue(inv.renderPlaces().contains("2 Dinge liegen ohne Ort"))
        XCTAssertTrue(FundusInventory().renderPlaces().contains("leer"))
    }

    // MARK: Availability

    /// Without the App Group there is no path, and therefore nothing to read. That is
    /// the state of every fork with a different team ID — the tool is then not offered,
    /// and that has to hold without anybody having to try it.
    func testWithoutTheAppGroupThereIsNothingToRead() {
        if SharedContainer.isAvailable {
            XCTAssertNotNil(SharedContainer.fundusInventoryURL)
        } else {
            XCTAssertNil(SharedContainer.fundusInventoryURL)
            XCTAssertFalse(FundusInventory.isPresent)
        }
    }

    /// The one mistake here that would look like a working app: a folder spelled
    /// differently from the one Fundus writes into. Nothing would fail — the tool would
    /// simply never be offered, on every device, and the reason would be invisible.
    ///
    /// Checked against the path rather than against Fundus: the two apps ship
    /// separately and share no code, so the agreement between them is exactly this
    /// string and nothing enforces it but a test on each side.
    func testThePathIsTheOneFundusWritesTo() throws {
        try XCTSkipUnless(SharedContainer.isAvailable, "Ohne App Group gibt es keinen Pfad.")
        let url = try XCTUnwrap(SharedContainer.fundusInventoryURL)
        XCTAssertEqual(url.lastPathComponent, "inventory.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Fundus")
        // Nothing about the rest of the path: iOS maps a group to an opaque UUID folder,
        // so neither the identifier nor any stable name appears in it. The two
        // components above are the whole of what the two apps agree on.
    }

    /// Faden reads and does not write. A folder created here would mean that "is there
    /// an inventory" answers yes on every device without Fundus, and then hands over
    /// nothing.
    func testAskingForThePathCreatesNothing() throws {
        try XCTSkipUnless(SharedContainer.isAvailable, "Ohne App Group gibt es keinen Pfad.")
        let folder = try XCTUnwrap(SharedContainer.fundusInventoryURL).deletingLastPathComponent()
        let existedBefore = FileManager.default.fileExists(atPath: folder.path)
        _ = FundusInventory.isPresent
        _ = SharedContainer.fundusInventoryURL
        XCTAssertEqual(FileManager.default.fileExists(atPath: folder.path), existedBefore)
    }

    // MARK: Helpers

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 12
        return Calendar.current.date(from: c)!
    }
}
