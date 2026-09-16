import SwiftUI

/// Hell oder dunkel.
///
/// Die Vorgabe folgt dem Gerät, und das ist mehr als Bequemlichkeit: iOS schaltet
/// zur Dämmerung um, und wer das eingestellt hat, will es überall. Die beiden festen
/// Werte sind für die Fälle, in denen jemand es besser weiß — ein heller Bildschirm
/// in der Sonne, ein dunkler im Bett neben jemandem, der schläft.
enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// `nil` heißt: das Gerät entscheidet.
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
