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
                // Two lines, and both are needed.
                //
                // `apply` redirects the lookup to the chosen language — that is the
                // switch itself. The locale below it does not do the translating but two
                // other things: numbers and dates look the way they do in that language,
                // and its change is the nudge on which SwiftUI rebuilds the views.
                // Without it the old language would stand until the user tapped
                // somewhere.
                .onChange(of: model.settings.language, initial: true) { _, language in
                    AppLanguage.apply(language)
                }
                .environment(\.locale, model.settings.language.locale ?? .autoupdatingCurrent)
                // `nil` means: the device decides — and switches at dusk by itself.
                .preferredColorScheme(model.settings.appearance.scheme)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false
    @State private var showHistory = false

    var body: some View {
        @Bindable var model = model

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
        // While the settings are open they present it themselves: one view can only
        // show one sheet, and this one is already showing the settings. The history
        // gives way — it is a glance, and the question is the thing to answer now.
        .dataSharingConsent(Binding(
            get: { showSettings || showHistory ? nil : model.consentRequest },
            set: { model.consentRequest = $0 }), model: model)
        .onChange(of: model.consentRequest?.id) { _, id in
            if id != nil, !showSettings { showHistory = false }
        }
    }
}
