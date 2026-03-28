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

            // Coral-tinted divider (matches sidebar header divider)
            Rectangle()
                .fill(CoralTheme.coralPrimary.opacity(0.2))
                .frame(height: 1)

            // Waiting-for-input banner
            if session.waitingForInput {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .foregroundStyle(CoralTheme.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.waitingSummary ?? "Waiting for input")
                            .font(.callout)
                            .fontWeight(.medium)
                        if let reason = session.waitingReason, !reason.isEmpty {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(CoralTheme.amber.opacity(0.1))
            }

            // Terminal area
            ZStack {
                if session.hasTmuxTarget {
                    LocalTerminalView(
                        sessionName: session.tmuxSession,
                        isTerminated: $isLocalTerminated
                    )
                    .id(localTerminalGeneration)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 3)
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

    private var agentBadgeColor: Color {
        switch session.agentType {
        case "terminal": return CoralTheme.teal
        case "gemini": return CoralTheme.magenta
        default: return CoralTheme.textSecondary
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
                        .foregroundStyle(CoralTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let branch = session.branch, !branch.isEmpty {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(CoralTheme.blueAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(CoralTheme.blueAccent.opacity(0.12), in: Capsule())
            }

            Text(session.agentType.capitalized)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(agentBadgeColor.opacity(0.12))
                .foregroundStyle(agentBadgeColor)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .background(CoralTheme.bgSurface.opacity(0.65))
        .background(.ultraThinMaterial)
    }

    private var sleepingOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill")
                .font(.largeTitle)
                .foregroundStyle(CoralTheme.blueAccent.opacity(0.6))
            Text("Session Sleeping")
                .font(.headline)
                .foregroundStyle(CoralTheme.textSecondary)
            Text("Will resume when needed")
                .font(.caption)
                .foregroundStyle(CoralTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(6)
        .accessibilityLabel("Session is sleeping, will resume when needed")
    }

    private var sessionEndedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(CoralTheme.green.opacity(0.8))
            Text("Task Complete")
                .font(.headline)
                .foregroundStyle(CoralTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(6)
        .accessibilityLabel("Task complete, session has ended")
    }

    private var detachedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.badge.xmark")
                .font(.largeTitle)
                .foregroundStyle(CoralTheme.amber)
            Text("Terminal Disconnected")
                .font(.headline)
                .foregroundStyle(CoralTheme.textSecondary)
            Button("Reattach") {
                isLocalTerminated = false
                localTerminalGeneration += 1
            }
            .buttonStyle(.borderedProminent)
            .tint(CoralTheme.coralPrimary)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(6)
        .accessibilityLabel("Terminal disconnected")
        .accessibilityHint("Activate to reattach")
    }
}
