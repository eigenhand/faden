import SwiftUI

/// Light or dark.
///
/// The default follows the device, and that is more than convenience: iOS switches at
/// dusk, and whoever set that up wants it everywhere. The two fixed values are for the
/// cases where somebody knows better — a light screen in the sun, a dark one in bed
/// beside somebody who is asleep.
enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// `nil` means: the device decides.
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return String(localized: "Wie das Gerät")
        case .light:  return String(localized: "Hell")
        case .dark:   return String(localized: "Dunkel")
        }
    }
}
