import SwiftUI

@main
struct NalaApp: App {
    @State private var sessionStore = SessionStore()

    init() {
        Self.migrateFromCoral()
    }

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
                .tint(NalaTheme.coralPrimary)
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

    // MARK: - Migration from Coral

    /// One-time migration from coral.* UserDefaults keys and ~/.coral/events/ directory.
    private static func migrateFromCoral() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "nala.migrationComplete") else { return }

        // Migrate UserDefaults keys
        let keyMappings: [(old: String, new: String)] = [
            ("coral.displayNames", "nala.displayNames"),
            ("coral.acknowledgedSessions", "nala.acknowledgedSessions"),
            ("coral.folderOrder", "nala.folderOrder"),
            ("coral.sessionOrder", "nala.sessionOrder"),
            ("coral.folderExpansion", "nala.folderExpansion"),
            ("coral.folderStatus", "nala.folderStatus"),
            ("coral.sectionExpansion", "nala.sectionExpansion"),
            ("coral.repoConfigs", "nala.repoConfigs"),
            ("coral.discoveredFolders", "nala.discoveredFolders"),
            ("coral.recentBrowsePaths", "nala.recentBrowsePaths"),
            ("coral.browseRoot", "nala.browseRoot"),
            ("coral.terminalAppPath", "nala.terminalAppPath"),
            ("coral.notifications.needsInput", "nala.notifications.needsInput"),
            ("coral.notifications.done", "nala.notifications.done"),
        ]

        for mapping in keyMappings {
            if let value = defaults.object(forKey: mapping.old),
               defaults.object(forKey: mapping.new) == nil {
                defaults.set(value, forKey: mapping.new)
            }
        }

        // Migrate events directory
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let oldEvents = "\(home)/.coral/events"
        let newParent = "\(home)/.nala"
        let newEvents = "\(newParent)/events"

        if fm.fileExists(atPath: oldEvents) && !fm.fileExists(atPath: newEvents) {
            try? fm.createDirectory(atPath: newParent, withIntermediateDirectories: true)
            try? fm.moveItem(atPath: oldEvents, toPath: newEvents)
            // Symlink for backward compat with coral-hook-* commands
            try? fm.createSymbolicLink(atPath: oldEvents, withDestinationPath: newEvents)
        }

        defaults.set(true, forKey: "nala.migrationComplete")
    }
}
