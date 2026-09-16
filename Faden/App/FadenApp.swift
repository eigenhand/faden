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
