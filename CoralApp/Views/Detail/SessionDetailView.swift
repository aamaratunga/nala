import SwiftUI

struct SessionDetailView: View {
    let session: Session
    @Environment(SessionStore.self) private var store
    /// Tracks whether the local PTY process has exited.
    @State private var isLocalTerminated = false
    /// Incremented to force-recreate the LocalTerminalView (reattach).
    @State private var localTerminalGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            sessionHeader

            // Accent gradient line
            CoralTheme.accentGradient(.accentColor)
                .frame(height: 1)

            // Terminal area
            ZStack {
                if session.hasTmuxTarget {
                    LocalTerminalView(
                        sessionName: session.tmuxSession,
                        isTerminated: $isLocalTerminated
                    )
                    .id(localTerminalGeneration)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CoralTheme.terminalBackground
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Overlays driven by /ws/coral metadata
                if session.sleeping {
                    sleepingOverlay
                } else if session.done && isLocalTerminated {
                    sessionEndedOverlay
                } else if isLocalTerminated {
                    detachedOverlay
                }
            }
            .background(CoralTheme.terminalBackground)
        }
        .onChange(of: session.tmuxSession) { _, newTarget in
            // Session restarted — force recreate PTY to attach to new tmux target
            guard !newTarget.isEmpty else { return }
            isLocalTerminated = false
            localTerminalGeneration += 1
        }
        .onChange(of: session.hasTmuxTarget) { _, hasTmux in
            if hasTmux {
                isLocalTerminated = false
            }
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

    private var sleepingOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Session Sleeping")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(6)
    }

    private var sessionEndedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
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

    private var detachedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.badge.xmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Session Detached")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button("Reattach") {
                isLocalTerminated = false
                localTerminalGeneration += 1
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(6)
    }
}
