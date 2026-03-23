import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @State private var visitedSessionIds: Set<String> = []

    var body: some View {
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
    }
}
