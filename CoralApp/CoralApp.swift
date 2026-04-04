import SwiftUI

@main
struct CoralApp: App {
    @State private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(sessionStore)
                .onAppear {
                    sessionStore.startServices()
                    NotificationManager.shared.requestPermission()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    sessionStore.scanWorktreeFolders()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )) { _ in
                    sessionStore.stopServices()
                }
                .preferredColorScheme(.dark)
                .tint(CoralTheme.coralPrimary)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Command Palette") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        sessionStore.showCommandPalette = true
                    }
                }
                .keyboardShortcut("k")

                Divider()

                Button("New Agent…") {
                    sessionStore.pendingPaletteMode = .newAgent
                    withAnimation(.easeOut(duration: 0.15)) {
                        sessionStore.showCommandPalette = true
                    }
                }
                .keyboardShortcut("n")

                Button("New Terminal…") {
                    sessionStore.pendingPaletteMode = .newTerminal
                    withAnimation(.easeOut(duration: 0.15)) {
                        sessionStore.showCommandPalette = true
                    }
                }
                .keyboardShortcut("t")

                Divider()

                Button("New Worktree…") {
                    sessionStore.pendingPaletteMode = .newWorktree
                    withAnimation(.easeOut(duration: 0.15)) {
                        sessionStore.showCommandPalette = true
                    }
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
                            sessionStore.killSession(session)
                        }
                    }
                }
                .keyboardShortcut("w")
                .disabled(sessionStore.selectedSession == nil)

                Divider()

                Button("Attach in Terminal") {
                    if let session = sessionStore.selectedSession {
                        TerminalLauncher.attachOrPrompt(sessionName: session.name)
                    }
                }
                .keyboardShortcut("o")
                .disabled(sessionStore.selectedSession == nil)
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
