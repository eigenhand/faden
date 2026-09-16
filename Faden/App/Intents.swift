import AppIntents
import SwiftUI

/// A question handed over from outside the app.
///
/// The intent runs in the app's own process, but it can finish before the first
/// screen is on stage — so it leaves the question here rather than acting on it, and
/// the chat picks it up when it is ready.
@Observable
@MainActor
final class IntentInbox {
    static let shared = IntentInbox()
    private init() {}

    /// Set by an intent, cleared by the chat once it has been sent.
    var question: String?
}

/// "Frag Faden …" — from Siri, Spotlight, the Shortcuts app and the Action button.
///
/// This is the cheapest re-entry point there is: no extension, no app group, no
/// second bundle identifier, nothing to register in the developer portal. It is
/// declared in the app itself, and in return the app appears in the places people
/// reach for when they are not already looking at it — which is the whole problem
/// with an app that only exists once you have found and tapped it.
struct AskFaden: AppIntent {
    static let title: LocalizedStringResource = "Faden fragen"
    static let description = IntentDescription(
        "Stellt Faden eine Frage und öffnet die Antwort in der App.")

    /// The answer belongs in the transcript, where it can be followed up, quoted and
    /// remembered — not in a one-shot dialog that disappears.
    static let openAppWhenRun = true

    @Parameter(title: "Frage", requestValueDialog: "Was möchtest du wissen?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Faden \(\.$question) fragen")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .result() }
        IntentInbox.shared.question = text
        return .result()
    }
}

/// Opens the app on an empty chat, ready to type.
struct NewFadenChat: AppIntent {
    static let title: LocalizedStringResource = "Neue Unterhaltung"
    static let description = IntentDescription("Öffnet Faden mit einem leeren Chat.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentInbox.shared.question = ""     // empty means: just open a fresh chat
        return .result()
    }
}

struct FadenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskFaden(),
            phrases: [
                "Frag \(.applicationName)",
                "\(.applicationName) fragen",
                "Stell \(.applicationName) eine Frage"
            ],
            shortTitle: "Fragen",
            systemImageName: "bubble.left.and.text.bubble.right")

        AppShortcut(
            intent: NewFadenChat(),
            phrases: [
                "Neue Unterhaltung in \(.applicationName)",
                "\(.applicationName) öffnen"
            ],
            shortTitle: "Neue Unterhaltung",
            systemImageName: "square.and.pencil")
    }
}
