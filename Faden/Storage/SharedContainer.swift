import Foundation

/// The shared folder of the eigenhand apps — from Faden's side, for reading only.
///
/// `group.dev.eigenhand.shared` is the place where Spind, Faden and Fundus meet. Fundus
/// keeps its inventory there as ordinary JSON; this is the door Faden reads it through.
///
/// Nothing here creates anything. Fundus's own `SharedContainer` makes its folder on
/// first use because it is going to write into it — were Faden to do the same, an empty
/// `Fundus/` folder would stand on every device without Fundus, and the question "is
/// there an inventory" would answer yes and then hand over nothing.
///
/// That the group is missing is more common than one would think: it only applies when
/// the provisioning profile carries it. In the simulator with automatic signing, and in
/// a fork with somebody else's team ID, `containerURL(…)` simply returns `nil`. That is
/// not an error but the normal case for a build without Fundus beside it — the tool is
/// then not offered in the first place.
enum SharedContainer {
    static let groupIdentifier = "group.dev.eigenhand.shared"

    static let groupURL: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)

    static var isAvailable: Bool { groupURL != nil }

    /// Fundus's inventory. Not created — see above.
    static var fundusInventoryURL: URL? {
        groupURL?
            .appendingPathComponent("Fundus", isDirectory: true)
            .appendingPathComponent("inventory.json")
    }
}
