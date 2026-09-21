import XCTest
@testable import Faden

/// Which tools the model is handed, and when.
///
/// The rule is one sentence: a tool reaches the model only once the service behind it
/// has been connected in the settings. It is worth a test of its own because it is the
/// kind of rule that is undone by a single character — a default flipped from `false`
/// to `true` in a struct nobody reads twice — and nothing else in the suite would go
/// red. What the user would notice is a chat that quotes their cellar to an endpoint
/// they never pointed it at.
final class ToolReleaseTests: XCTestCase {

    /// Everything that can be read or searched is off in a fresh install.
    func testAFreshInstallReleasesNothing() {
        let fresh = AppSettings()
        XCTAssertNil(fresh.activeRecipe, "Ohne Suchanbieter keine Suche.")
        XCTAssertFalse(fresh.memory.isReady, "Ohne Einbettungsmodell kein Gedächtnis.")
        XCTAssertFalse(fresh.inventoryEnabled, "Fundus ist nicht verbunden.")
        XCTAssertFalse(fresh.folder.isSet, "Kein Ordner freigegeben.")
    }

    /// `remember` is the exception, and it is one because it reaches nothing: it writes
    /// a note into the conversation it already belongs to. There is no service behind
    /// it to connect.
    func testOnlyRememberIsOfferedWithoutAnyService() {
        let tools = Tools.available(searchEnabled: false, memoryEnabled: false,
                                    inventoryEnabled: false, folderEnabled: false)
        XCTAssertEqual(tools.map(\.name), ["remember"])
    }

    func testEachServiceReleasesItsOwnToolAndNoOther() {
        XCTAssertEqual(names(search: true), ["web_search", "fetch_page", "remember"])
        XCTAssertEqual(names(memory: true), ["remember", "memory"])
        XCTAssertEqual(names(inventory: true), ["remember", "inventory"])
        XCTAssertEqual(names(folder: true), ["remember", "files"])
    }

    func testEverythingConnectedReleasesEverything() {
        XCTAssertEqual(Set(names(search: true, memory: true, inventory: true, folder: true)),
                       ["web_search", "fetch_page", "remember", "memory", "inventory", "files"])
    }

    // MARK: The prompt follows the tools

    /// A paragraph about a tool the model does not have is worse than none: it describes
    /// somebody else's situation, and the room it takes is paid for on every turn.
    func testTheSystemPromptOnlyDescribesWhatIsThere() {
        let bare = prompt()
        XCTAssertFalse(bare.contains("inventory"), bare)
        XCTAssertFalse(bare.contains("files"), bare)
        XCTAssertFalse(bare.contains("<<<fremd:"), "Ohne fremden Text keine Einfassungsregel.")

        XCTAssertTrue(prompt(inventory: true).contains("inventory"))
        XCTAssertTrue(prompt(folder: true).contains("files"))
    }

    /// The fencing rule used to hang on the search branch. With a folder connected and
    /// no search provider, the marks would have arrived with nothing explaining them.
    func testTheFencingRuleAppearsForTheFolderAlone() {
        let folderOnly = prompt(folder: true)
        XCTAssertTrue(folderOnly.contains("<<<fremd:"), folderOnly)
        XCTAssertTrue(folderOnly.contains("files"))
        XCTAssertFalse(folderOnly.contains("web_search"),
                       "Und sie nennt nicht, was gar nicht da ist.")
    }

    /// The inventory is not fenced, so it must not drag the rule in by itself.
    func testTheInventoryAloneBringsNoFencingRule() {
        XCTAssertFalse(prompt(inventory: true).contains("<<<fremd:"))
    }

    // MARK: Helpers

    private func names(search: Bool = false, memory: Bool = false,
                       inventory: Bool = false, folder: Bool = false) -> [String] {
        Tools.available(searchEnabled: search, memoryEnabled: memory,
                        inventoryEnabled: inventory, folderEnabled: folder).map(\.name)
    }

    private func prompt(search: Bool = false, inventory: Bool = false,
                        folder: Bool = false) -> String {
        AgentRunner.systemPrompt(settings: AppSettings(), searchAvailable: search,
                                 providerName: search ? "Brave" : nil,
                                 inventoryAvailable: inventory, folderAvailable: folder)
    }
}
