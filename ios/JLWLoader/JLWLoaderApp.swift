import SwiftUI

@main
struct JLWLoaderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            if appState.isAuthenticated {
                MainView(appState: appState)
            } else {
                AccessCodeView(appState: appState)
            }
        }
    }
}
