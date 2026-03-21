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

            // Accent gradient line
            LinearGradient(
                colors: [.accentColor.opacity(0.6), .accentColor.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)

            // Terminal area
            ZStack {
                TerminalDisplayView(webSocket: terminalWS)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isClosed {
                    closedOverlay
                }
            }
            .background(Color(red: 0.031, green: 0.043, blue: 0.063))

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
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(6)
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
