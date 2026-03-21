import SwiftUI

struct SessionListView: View {
    @Environment(SessionStore.self) private var store

    private struct SessionGroup: Identifiable {
        let id: String
        let label: String
        let path: String
        let sessions: [Session]
    }

    private var groupedSessions: [SessionGroup] {
        let grouped = Dictionary(grouping: store.sessions) { $0.workingDirectory }
        return grouped.map { (path, sessions) in
            let label = path.isEmpty
                ? "Other"
                : URL(fileURLWithPath: path).lastPathComponent
            return SessionGroup(id: path, label: label, path: path, sessions: sessions)
        }
        .sorted { a, b in
            if a.path.isEmpty { return false }
            if b.path.isEmpty { return true }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selectedSessionId) {
            if store.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Active Sessions", systemImage: "bolt.slash")
                } description: {
                    Text("Launch an agent to get started.")
                }
                .listRowSeparator(.hidden)
            } else {
                ForEach(groupedSessions) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            SessionRowView(session: session)
                                .tag(session.id)
                                .contextMenu {
                                    sessionContextMenu(for: session)
                                }
                        }
                    } header: {
                        Label(group.label, systemImage: "folder")
                            .help(group.path.isEmpty ? "Ungrouped sessions" : group.path)
                    }
                }
            }
        }
        .navigationTitle("Coral")
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.showingLaunchSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Launch new agent")
            }

            ToolbarItem(placement: .status) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(store.isConnected ? .green : .red)
                        .frame(width: 6, height: 6)
                    Text(store.isConnected ? "Connected" : "Disconnected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionContextMenu(for session: Session) -> some View {
        Button("Restart") {
            Task {
                try? await store.apiClient.restartSession(
                    sessionName: session.name,
                    agentType: session.agentType,
                    sessionId: session.sessionId
                )
            }
        }

        Button("Kill", role: .destructive) {
            Task {
                try? await store.apiClient.killSession(
                    sessionName: session.name,
                    agentType: session.agentType,
                    sessionId: session.sessionId
                )
            }
        }
    }
}
