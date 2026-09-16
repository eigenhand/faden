import SwiftUI

@main
struct FadenApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.load() }
                .tint(EH.navy)
                // Zwei Zeilen, und beide werden gebraucht.
                //
                // `apply` leitet das Nachschlagen auf die gewaehlte Sprache um — das
                // ist die Umstellung selbst. Die Locale darunter macht nicht die
                // Uebersetzung, sondern zweierlei anderes: Zahlen und Daten sehen
                // aus wie in dieser Sprache, und ihre Aenderung ist der Anstoss, auf
                // den SwiftUI die Ansichten neu baut. Ohne sie bliebe die alte
                // Sprache stehen, bis der Nutzer irgendwohin tippt.
                .onChange(of: model.settings.language, initial: true) { _, language in
                    AppLanguage.apply(language)
                }
                .environment(\.locale, model.settings.language.locale ?? .autoupdatingCurrent)
                // `nil` heisst: das Geraet entscheidet — und wechselt zur Daemmerung
                // von selbst mit.
                .preferredColorScheme(model.settings.appearance.scheme)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false
    @State private var showHistory = false

    var body: some View {
        ZStack {
            EH.scene
            BrandWatermark()
            ChatView(showSettings: $showSettings, showHistory: $showHistory)
        }
        // Settings is a sustained task and takes the whole screen. The history is a
        // brief one — picking another conversation — and NN/g's guidance for partial
        // overlays applies: keeping the current chat visible behind it shows what you
        // are switching away from, and a half-height sheet is quicker to dismiss.
        .onOpenURL { url in
            // A .perbu file from Files, AirDrop or Messages.
            model.importConversation(from: url)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHistory) {
            HistoryView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }
}
