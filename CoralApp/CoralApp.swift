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
                            NotificationManager.shared.requestPermission()
                        }
                        .onReceive(NotificationCenter.default.publisher(
                            for: NSApplication.didBecomeActiveNotification
                        )) { _ in
                            sessionStore.scanParentFolder()
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

                Button("New Terminal…") {
                    sessionStore.showingTerminalLaunchSheet = true
                }
                .keyboardShortcut("t")

                Divider()

                Button("New Agent in Current Folder") {
                    if let session = sessionStore.selectedSession {
                        sessionStore.launchSession(agentType: "claude", in: session.workingDirectory)
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(sessionStore.selectedSession == nil)

                Button("New Terminal in Current Folder") {
                    if let session = sessionStore.selectedSession {
                        sessionStore.launchTerminal(in: session.workingDirectory)
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(sessionStore.selectedSession == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(sessionStore)
        }
    }
}
