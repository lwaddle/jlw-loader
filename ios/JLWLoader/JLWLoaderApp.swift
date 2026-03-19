import SwiftUI

@main
struct JLWLoaderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isAuthenticated {
                    MainView(appState: appState)
                } else {
                    AccessCodeView(appState: appState)
                }
            }
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
