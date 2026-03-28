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
            .preferredColorScheme(.dark)
            .tint(CoralTheme.coralPrimary)
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

                Button("New Worktree…") {
                    sessionStore.showingCreateWorktreeSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(sessionStore.validRepoConfigs.isEmpty)

                Divider()

                Button("Kill Session") {
                    if let session = sessionStore.selectedSession {
                        if session.agentType != "terminal" && (session.working || session.waitingForInput) {
                            sessionStore.pendingKillSession = session
                            sessionStore.showingKillConfirmation = true
                        } else {
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
                }
                .keyboardShortcut("w")
                .disabled(sessionStore.selectedSession == nil)

                Divider()

                Button("Attach in Terminal") {
                    if let session = sessionStore.selectedSession {
                        TerminalLauncher.attachOrPrompt(sessionName: session.tmuxSession)
                    }
                }
                .keyboardShortcut("o")
                .disabled(sessionStore.selectedSession?.hasTmuxTarget != true)
            }
            CommandGroup(before: .sidebar) {
                Button("Toggle Sidebar") {
                    sessionStore.sidebarVisibility = sessionStore.sidebarVisibility == .all
                        ? .detailOnly : .all
                }
                .keyboardShortcut("s")
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    sessionStore.showingShortcutsPanel.toggle()
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
