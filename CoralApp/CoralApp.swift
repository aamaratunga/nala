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
                            sessionStore.scanWorktreeFolders()
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

                Divider()

                Button("New Worktree…") {
                    sessionStore.showingCreateWorktreeSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(sessionStore.validRepoConfigs.isEmpty)

                Divider()

                Button("Kill Session") {
                    if let session = sessionStore.selectedSession {
                        sessionStore.removeSessionOptimistically(session)
                        Task {
                            try? await sessionStore.apiClient.killSession(
                                sessionName: session.name,
                                agentType: session.agentType,
                                sessionId: session.sessionId
                            )
                        }
                    }
                }
                .keyboardShortcut("w")
                .disabled(sessionStore.selectedSession == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    withAnimation { sessionStore.showingShortcutsPanel.toggle() }
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(sessionStore)
        }
    }
}
