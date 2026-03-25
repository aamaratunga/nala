import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @State private var visitedSessionIds: Set<String> = []
    @State private var shortcutMonitor: Any?

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $store.sidebarVisibility) {
            SessionListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } detail: {
            ZStack {
                // Keep visited session views alive so terminal state persists
                ForEach(store.sessions.filter { visitedSessionIds.contains($0.id) && !$0.isPlaceholder }) { session in
                    let isSelected = session.id == store.selectedSessionId
                    SessionDetailView(session: session)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                }

                // Overlay creation/deletion/launch/restart progress or empty state on top
                if let deletionState = store.selectedDeletionState {
                    WorktreeDeletionProgressView(state: deletionState)
                } else if let creationState = store.selectedCreationState {
                    WorktreeCreationProgressView(state: creationState)
                } else if let restartState = store.selectedRestartState {
                    SessionRestartProgressView(state: restartState)
                } else if let launchState = store.selectedLaunchState {
                    SessionLaunchProgressView(state: launchState)
                } else if store.selectedSession == nil {
                    ContentUnavailableView {
                        Label("No Session Selected", systemImage: "terminal")
                    } description: {
                        Text("Select an agent session from the sidebar, or launch a new one.")
                    }
                }
            }
            .onChange(of: store.selectedSessionId) { _, newId in
                if let id = newId {
                    visitedSessionIds.insert(id)
                }
                let tmuxName = store.sessions
                    .first(where: { $0.id == newId })?.tmuxSession
                CoralTerminalView.activeSessionName = tmuxName

                // When a session was selected via mouse click (sidebarFocused
                // is false), focus its terminal.  The async lets SwiftUI
                // create the terminal view first on initial visit.
                if !store.sidebarFocused, let tmuxName {
                    DispatchQueue.main.async {
                        guard let window = NSApp.keyWindow,
                              let tv = LocalTerminalView.viewsBySession.object(forKey: tmuxName as NSString)
                        else { return }
                        window.makeFirstResponder(tv)
                    }
                }
            }
            .onChange(of: store.sessions) { _, newSessions in
                let currentIds = Set(newSessions.map(\.id))
                visitedSessionIds = visitedSessionIds.intersection(currentIds)
            }
        }
        .inspector(isPresented: $store.showingShortcutsPanel) {
            KeyboardShortcutsPanel()
        }
        .alert("Kill Session?", isPresented: $store.showingKillConfirmation) {
            Button("Cancel", role: .cancel) { store.pendingKillSession = nil }
            Button("Kill", role: .destructive) {
                if let session = store.pendingKillSession {
                    store.pendingKillSession = nil
                    store.removeSessionOptimistically(session)
                    Task {
                        try? await store.apiClient.killSession(
                            sessionName: session.name,
                            agentType: session.agentType,
                            sessionId: session.sessionId
                        )
                    }
                }
            }
        } message: {
            if let session = store.pendingKillSession {
                Text("'\(session.displayLabel)' is still running. Kill it?")
            }
        }
        .onAppear { installShortcutMonitor() }
        .onDisappear { removeShortcutMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === NSApp.keyWindow else { return }
            // Small delay so this runs AFTER AppKit finishes its own
            // first-responder restoration, overriding it reliably.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard window.isKeyWindow else { return }
                if store.sidebarFocused {
                    window.makeFirstResponder(nil)
                } else if let session = store.selectedSession,
                          let tv = LocalTerminalView.viewsBySession.object(forKey: session.tmuxSession as NSString) {
                    window.makeFirstResponder(tv)
                } else {
                    store.sidebarFocused = true
                    window.makeFirstResponder(nil)
                }
            }
        }
    }

    // MARK: - Keyboard Shortcut Monitor

    /// Installs a consolidated local event monitor for all custom keyboard shortcuts.
    private func installShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [store] event in
            let mods = event.modifierFlags.intersection([.shift, .command, .control, .option])

            // Determine focus context from the responder chain
            let window = NSApp.keyWindow
            let firstResponder = window?.firstResponder
            let responderClass = firstResponder.map { String(describing: type(of: $0)) } ?? ""
            let isTerminalFocused = responderClass.contains("Terminal")
            let isTextFieldFocused = firstResponder is NSTextView || firstResponder is NSTextField

            // Guard: if a hidden (non-active) terminal has focus, redirect
            // immediately and swallow this keystroke.  This catches any case
            // where macOS restored focus to the wrong terminal on app
            // reactivation before the notification handler could fix it.
            if isTerminalFocused,
               let tv = firstResponder as? CoralTerminalView,
               !tv.isActiveTerminal {
                if let session = store.selectedSession {
                    ContentView.focusTerminal(session: session)
                } else {
                    store.sidebarFocused = true
                    ContentView.resignTerminalFocus()
                }
                return nil
            }

            // Sync sidebar focus: if the terminal just gained focus (e.g. user
            // clicked on it), clear the sidebar-focused flag.
            if isTerminalFocused || isTextFieldFocused {
                store.sidebarFocused = false
            }

            // ⌘0: Focus sidebar (global — works even from terminal)
            if event.keyCode == 29 && mods == .command {
                store.sidebarVisibility = .all
                store.sidebarFocused = true
                ContentView.resignTerminalFocus()
                return nil
            }

            // ⌘1-9: Jump to folder (global)
            if mods == .command, let chars = event.characters, let digit = Int(chars), (1...9).contains(digit) {
                store.jumpToFolder(at: digit - 1)
                store.sidebarFocused = true
                ContentView.resignTerminalFocus()
                return nil
            }

            // --- Sidebar-only shortcuts (require sidebarFocused) ---

            guard store.sidebarFocused else { return event }

            // Tab: Focus terminal (sidebar → terminal)
            if event.keyCode == 48 && mods.isEmpty {
                store.sidebarFocused = false
                ContentView.focusTerminal(session: store.selectedSession)
                return nil
            }

            // Enter: Start rename (session selected, not already renaming)
            if event.keyCode == 36 && mods.isEmpty
               && store.selectedSessionId != nil && store.renamingSessionId == nil {
                store.renamingSessionId = store.selectedSessionId
                return nil
            }

            // ↑: Navigate to previous session
            if event.keyCode == 126 && mods.isEmpty {
                let ids = store.navigableSessionIds
                if let current = store.selectedSessionId,
                   let idx = ids.firstIndex(of: current), idx > 0 {
                    store.selectedSessionId = ids[idx - 1]
                } else if store.selectedSessionId == nil, let last = ids.last {
                    store.selectedSessionId = last
                }
                return nil
            }

            // ↓: Navigate to next session
            if event.keyCode == 125 && mods.isEmpty {
                let ids = store.navigableSessionIds
                if let current = store.selectedSessionId,
                   let idx = ids.firstIndex(of: current), idx < ids.count - 1 {
                    store.selectedSessionId = ids[idx + 1]
                } else if store.selectedSessionId == nil, let first = ids.first {
                    store.selectedSessionId = first
                }
                return nil
            }

            // ←: Collapse folder
            if event.keyCode == 123 && mods.isEmpty {
                if let folderPath = store.focusedFolderPath {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        store.folderExpansion[folderPath] = false
                    }
                }
                return nil
            }

            // →: Expand folder
            if event.keyCode == 124 && mods.isEmpty {
                if let folderPath = store.focusedFolderPath {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        store.folderExpansion[folderPath] = true
                    }
                }
                return nil
            }

            return event
        }
    }

    private func removeShortcutMonitor() {
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
    }

    // MARK: - Focus Helpers

    /// Resign terminal focus so keyboard input stops going to the PTY.
    /// Makes the window itself the first responder.
    private static func resignTerminalFocus() {
        guard let window = NSApp.keyWindow else { return }
        window.makeFirstResponder(nil)
    }

    /// Focus the terminal view for the given session using the stored
    /// weak reference map, avoiding unreliable view-hierarchy searches.
    private static func focusTerminal(session: Session?) {
        guard let window = NSApp.keyWindow,
              let session,
              let tv = LocalTerminalView.viewsBySession.object(forKey: session.tmuxSession as NSString)
        else { return }
        window.makeFirstResponder(tv)
    }
}
