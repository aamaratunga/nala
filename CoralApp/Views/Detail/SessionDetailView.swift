import SwiftUI

struct SessionDetailView: View {
    let session: Session
    @Environment(SessionStore.self) private var store
    @State private var terminalWS = TerminalWebSocket()
    @State private var isClosed = false

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            sessionHeader

            Divider()

            // Terminal area
            ZStack {
                TerminalDisplayView(webSocket: terminalWS)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isClosed {
                    closedOverlay
                }
            }

            Divider()

            // Command input
            CommandInputView(session: session)
        }
        .onChange(of: session.id) { _, newId in
            connectTerminal()
        }
        .onAppear {
            connectTerminal()
        }
        .onDisappear {
            terminalWS.disconnect()
        }
    }

    private var sessionHeader: some View {
        HStack {
            StatusDot(session: session)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if let icon = session.icon, !icon.isEmpty {
                        Text(icon)
                    }
                    Text(session.displayLabel)
                        .font(.headline)
                }

                if let summary = session.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let branch = session.branch, !branch.isEmpty {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(session.agentType.capitalized)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var closedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Session Ended")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func connectTerminal() {
        isClosed = false

        terminalWS.disconnect()
        terminalWS = TerminalWebSocket(port: store.apiClient.baseURL.port ?? 8420)

        // onOutput is wired by TerminalDisplayView's coordinator

        terminalWS.onClosed = {
            isClosed = true
        }

        terminalWS.onDisconnect = {
            // Could show a reconnecting indicator
        }

        terminalWS.connect(
            sessionName: session.name,
            agentType: session.agentType,
            sessionId: session.sessionId
        )
    }
}
