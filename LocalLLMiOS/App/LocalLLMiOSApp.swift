import SwiftUI

@main
struct LocalLLMiOSApp: App {
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .onAppear {
                    state.reloadBooks()
                    state.models.refresh()
                }
        }
    }
}
