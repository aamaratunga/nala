import SwiftUI

struct StatusDot: View {
    let session: Session

    private var isStale: Bool {
        guard session.working, let staleness = session.stalenessSeconds else { return false }
        return staleness > 300
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(isStale ? 0.5 : 1.0)
            .accessibilityLabel("Status: \(accessibilityStatus)")
            .overlay {
                if session.working && !isStale && !session.done && !session.stuck && !session.waitingForInput {
                    Circle()
                        .stroke(color.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                        .scaleEffect(pulseScale)
                        .opacity(pulseOpacity)
                        .animation(
                            .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                            value: session.working
                        )
                }
            }
    }

    private var color: Color {
        if session.done {
            return .green
        } else if session.stuck {
            return .red
        } else if session.waitingForInput {
            return .orange
        } else if session.working {
            return .blue
        } else {
            return .gray
        }
    }

    private var pulseScale: CGFloat {
        session.working ? 1.0 : 0.8
    }

    private var pulseOpacity: Double {
        session.working ? 0.0 : 0.5
    }

    private var accessibilityStatus: String {
        if session.done { return "completed" }
        if session.stuck { return "stuck" }
        if session.waitingForInput { return "waiting for input" }
        if session.working { return isStale ? "stale" : "working" }
        return "idle"
    }
}
