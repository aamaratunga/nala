import SwiftUI

@main
struct CoralApp: App {
    @State private var serverManager = ServerManager()
    @State private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if serverManager.isReady {
                    ContentView()
                        .environment(sessionStore)
                        .onAppear {
                            sessionStore.connect(port: serverManager.port)
                        }
                } else {
                    LoadingView(serverManager: serverManager)
                }
            }
            .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Agent…") {
                    sessionStore.showingLaunchSheet = true
                }
                .keyboardShortcut("n")
            }
        }
    }
}
