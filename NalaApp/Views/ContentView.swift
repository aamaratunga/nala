import SwiftUI
import AppKit

// MARK: - Palette Notification Names

extension Notification.Name {
    static let paletteExecuteSelected = Notification.Name("paletteExecuteSelected")
    static let paletteMoveUp = Notification.Name("paletteMoveUp")
    static let paletteMoveDown = Notification.Name("paletteMoveDown")
    static let paletteSwitchMode = Notification.Name("paletteSwitchMode")
    static let paletteEscapePressed = Notification.Name("paletteEscapePressed")
    static let paletteTabPressed = Notification.Name("paletteTabPressed")
    static let paletteBackspaceEmpty = Notification.Name("paletteBackspaceEmpty")
}

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @State private var visitedSessionIds: [String] = []
    @State private var shortcutMonitor: Any?
    @State private var paletteMode: PaletteMode = .switchSession

    /// Window number of the main app window, used to scope event handlers
    /// so they don't interfere with the Settings window or other auxiliaries.
    static var mainWindowNumber: Int = -1

    var body: some View {
        @Bindable var store = store

        ZStack {
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
                    } else if store.tmuxNotFound {
                        ContentUnavailableView {
                            Label("tmux Not Found", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text("Nala requires tmux to manage agent sessions. Install it via Homebrew, then relaunch the app.")
                        } actions: {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("brew install tmux", forType: .string)
                            } label: {
                                Label("Copy \"brew install tmux\"", systemImage: "doc.on.doc")
                            }
                        }
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
                        visitedSessionIds.removeAll { $0 == id }
                        visitedSessionIds.append(id)
                        // Evict oldest if over limit
                        let maxVisited = 5
                        if visitedSessionIds.count > maxVisited {
                            visitedSessionIds.removeFirst(visitedSessionIds.count - maxVisited)
                        }
                        // Track last focused timestamp for palette recency sort
                        store.lastFocusedTimestamps[id] = Date()
                        store.recordFolderInteractionForSession(id)
                    }
                    let tmuxName = store.sessions
                        .first(where: { $0.id == newId })?.tmuxSession
                    NalaTerminalView.activeSessionName = tmuxName

                    // When a session was selected via mouse click (sidebarFocused
                    // is false), focus its terminal.  The async lets SwiftUI
                    // create the terminal view first on initial visit.
                    if !store.sidebarFocused, let tmuxName {
                        let expectedId = newId
                        DispatchQueue.main.async {
                            guard store.selectedSessionId == expectedId else { return }
                            guard let window = NSApp.keyWindow,
                                  let tv = LocalTerminalView.viewsBySession.object(forKey: tmuxName as NSString)
                            else { return }
                            window.makeFirstResponder(tv)
                        }
                    }
                }
                .onChange(of: store.sessions) { _, newSessions in
                    let currentIds = Set(newSessions.map(\.id))
                    visitedSessionIds = visitedSessionIds.filter { currentIds.contains($0) }
                }
            }

            // MARK: - Command Palette Overlay
            if store.showCommandPalette {
                // Dimmed backdrop
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeIn(duration: 0.1)) {
                            store.showCommandPalette = false
                        }
                        ContentView.restoreFocusAfterPalette(store: store)
                    }

                // Palette positioned in upper third
                VStack {
                    Spacer()
                        .frame(height: 80)
                    CommandPaletteView(initialMode: paletteMode)
                        .environment(store)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .toolbarBackground(NalaTheme.bgSurface, for: .windowToolbar)
        .inspector(isPresented: $store.showingShortcutsPanel) {
            KeyboardShortcutsPanel()
        }
        .alert("Kill Session?", isPresented: $store.showingKillConfirmation) {
            Button("Cancel", role: .cancel) { store.pendingKillSession = nil }
            Button("Kill", role: .destructive) {
                if let session = store.pendingKillSession {
                    let snapshot = session
                    store.pendingKillSession = nil
                    store.killSession(session)
                }
            }
        } message: {
            if let session = store.pendingKillSession {
                Text("'\(session.displayLabel)' is still running. Kill it?")
            }
        }
        .alert("Error", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .onAppear {
            ContentView.mainWindowNumber = NSApp.keyWindow?.windowNumber
                ?? NSApp.windows.first?.windowNumber ?? -1
            installShortcutMonitor()
        }
        .onDisappear { removeShortcutMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === NSApp.keyWindow,
                  window.windowNumber == ContentView.mainWindowNumber else { return }
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
            // Only handle shortcuts in the main app window (not Settings, etc.)
            if let eventWindow = event.window,
               eventWindow.windowNumber != ContentView.mainWindowNumber {
                return event
            }

            let mods = event.modifierFlags.intersection([.shift, .command, .control, .option])

            // --- Command Palette keyboard handling ---
            if store.showCommandPalette {
                return ContentView.handlePaletteKeyEvent(event, mods: mods, store: store)
            }

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
               let tv = firstResponder as? NalaTerminalView,
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

            // ⌘K: Open command palette (global)
            if event.keyCode == 40 && mods == .command {
                openPalette(mode: .switchSession)
                return nil
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

    // MARK: - Command Palette

    private func openPalette(mode: PaletteMode) {
        paletteMode = mode
        store.pendingPaletteMode = mode
        withAnimation(.easeOut(duration: 0.15)) {
            store.showCommandPalette = true
        }
    }

    private func closePalette() {
        withAnimation(.easeIn(duration: 0.1)) {
            store.showCommandPalette = false
        }
    }

    /// Handle key events when the command palette is open.
    /// Returns nil to consume, or the event to pass through.
    private static func handlePaletteKeyEvent(_ event: NSEvent, mods: NSEvent.ModifierFlags, store: SessionStore) -> NSEvent? {
        // Escape: let the palette decide behavior (close, clear, or go back)
        if event.keyCode == 53 {
            NotificationCenter.default.post(name: .paletteEscapePressed, object: nil)
            return nil
        }

        // Tab: drill down in browse mode (intercepted before TextField gets it)
        if event.keyCode == 48 && mods.isEmpty {
            NotificationCenter.default.post(name: .paletteTabPressed, object: nil)
            return nil
        }

        // Enter: execute selected
        if event.keyCode == 36 && mods.isEmpty {
            NotificationCenter.default.post(name: .paletteExecuteSelected, object: nil)
            return nil
        }

        // ↑: Move selection up
        if event.keyCode == 126 && mods.isEmpty {
            NotificationCenter.default.post(name: .paletteMoveUp, object: nil)
            return nil
        }

        // ↓: Move selection down
        if event.keyCode == 125 && mods.isEmpty {
            NotificationCenter.default.post(name: .paletteMoveDown, object: nil)
            return nil
        }

        // ⌘K: Close palette (toggle) and restore focus
        if event.keyCode == 40 && mods == .command {
            withAnimation(.easeIn(duration: 0.1)) {
                store.showCommandPalette = false
            }
            restoreFocusAfterPalette(store: store)
            return nil
        }

        // ⌘N: Switch to New Agent mode
        if event.keyCode == 45 && mods == .command {
            NotificationCenter.default.post(name: .paletteSwitchMode, object: PaletteMode.newAgent)
            return nil
        }

        // ⌘T: Switch to New Terminal mode
        if event.keyCode == 17 && mods == .command {
            NotificationCenter.default.post(name: .paletteSwitchMode, object: PaletteMode.newTerminal)
            return nil
        }

        // ⌥⌘N: Switch to New Worktree mode
        if event.keyCode == 45 && mods == [.command, .option] {
            NotificationCenter.default.post(name: .paletteSwitchMode, object: PaletteMode.newWorktree)
            return nil
        }

        // Backspace on empty: pop mode back to switchSession
        // Skip when branch input is active — backspace must reach the branch TextField
        if event.keyCode == 51 && CommandPaletteView.currentQueryIsEmpty && !CommandPaletteView.currentModeIsSwitchSession && !CommandPaletteView.isBranchInputActive {
            NotificationCenter.default.post(name: .paletteBackspaceEmpty, object: nil)
            return nil
        }

        // All other keys: pass through to TextField (typing, backspace, Cmd+A, etc.)
        return event
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
    static func focusTerminal(session: Session?) {
        guard let window = NSApp.keyWindow,
              let session,
              let tv = LocalTerminalView.viewsBySession.object(forKey: session.tmuxSession as NSString)
        else { return }
        window.makeFirstResponder(tv)
    }

    /// Restore focus after the command palette closes.
    /// Waits for the dismiss animation, then refocuses the terminal or sidebar.
    static func restoreFocusAfterPalette(store: SessionStore) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if store.sidebarFocused {
                NSApp.keyWindow?.makeFirstResponder(nil)
            } else {
                focusTerminal(session: store.selectedSession)
            }
        }
    }
}
