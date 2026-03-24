import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @State private var visitedSessionIds: Set<String> = []
    @State private var shortcutMonitor: Any?

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
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
            }
            .onChange(of: store.sessions) { _, newSessions in
                let currentIds = Set(newSessions.map(\.id))
                visitedSessionIds = visitedSessionIds.intersection(currentIds)
            }
        }
        .inspector(isPresented: $store.showingShortcutsPanel) {
            KeyboardShortcutsPanel()
        }
        .onAppear { installShortcutMonitor() }
        .onDisappear { removeShortcutMonitor() }
    }

    // MARK: - Bare ? key monitor

    /// Installs a local event monitor for the `?` key (Shift+/) that toggles
    /// the shortcuts panel when no text input field has focus.
    private func installShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [store] event in
            // ? is Shift + / (keyCode 44)
            let mods = event.modifierFlags.intersection([.shift, .command, .control, .option])
            guard event.keyCode == 44 && mods == .shift else { return event }

            // Don't intercept when a text field or terminal has focus
            guard let window = NSApp.keyWindow,
                  let firstResponder = window.firstResponder else {
                return event
            }

            let responderClass = String(describing: type(of: firstResponder))
            if firstResponder is NSTextView || firstResponder is NSTextField
                || responderClass.contains("Terminal") {
                return event
            }

            withAnimation { store.showingShortcutsPanel.toggle() }
            return nil
        }
    }

    private func removeShortcutMonitor() {
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
    }
}
