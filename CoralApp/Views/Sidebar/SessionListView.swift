import SwiftUI

struct SessionListView: View {
    @Environment(SessionStore.self) private var store

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
                ForEach(store.sessions) { session in
                    SessionRowView(session: session)
                        .tag(session.id)
                        .contextMenu {
                            sessionContextMenu(for: session)
                        }
                }
            }
        }
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
