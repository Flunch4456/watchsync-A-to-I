import SwiftUI

struct ContentView: View {
    @StateObject private var manager = HeartRateManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            LiveView(manager: manager, history: manager.history)
                .tabItem { Label("En direct", systemImage: "heart.fill") }

            HistoryView(history: manager.history)
                .tabItem { Label("Historique", systemImage: "chart.xyaxis.line") }

            SettingsView(manager: manager)
                .tabItem { Label("Réglages", systemImage: "gearshape") }
        }
        .tint(.red)
        .onChange(of: scenePhase) { phase in
            // On enregistre l'historique dès que l'app quitte le premier plan
            if phase != .active { manager.history.save() }
        }
    }
}
