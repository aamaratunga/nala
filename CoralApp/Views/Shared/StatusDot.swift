import SwiftUI

struct StatusDot: View {
    let session: Session

    @State private var glowActive = false

    private var isStale: Bool {
        guard session.working, let staleness = session.stalenessSeconds else { return false }
        return staleness > 300
    }

    private var isActivelyWorking: Bool {
        session.working && !isStale && !session.done && !session.stuck && !session.waitingForInput
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(isStale ? 0.5 : 1.0)
            .shadow(
                color: glowColor.opacity(glowActive ? primaryGlowOpacity : primaryGlowOpacity * 0.5),
                radius: primaryGlowRadius
            )
            .shadow(
                color: glowColor.opacity(glowActive ? secondaryGlowOpacity : secondaryGlowOpacity * 0.5),
                radius: secondaryGlowRadius
            )
            .animation(
                isActivelyWorking
                    ? .easeInOut(duration: 2).repeatForever(autoreverses: true)
                    : .default,
                value: glowActive
            )
            .onChange(of: isActivelyWorking, initial: true) { _, active in
                glowActive = active
            }
            .accessibilityLabel("Status: \(accessibilityStatus)")
    }

    private var color: Color {
        if session.done {
            return CoralTheme.green
        } else if session.stuck {
            return CoralTheme.red
        } else if session.waitingForInput {
            return CoralTheme.amber
        } else if session.working {
            return CoralTheme.teal
        } else {
            return CoralTheme.textTertiary
        }
    }

    private var glowColor: Color { color }

    private var primaryGlowOpacity: Double {
        if session.done { return 0.2 }
        if session.stuck { return 0.2 }
        if session.waitingForInput { return 0.2 }
        if session.working { return 0.4 }
        return 0
    }

    private var primaryGlowRadius: CGFloat {
        if session.done || session.stuck || session.waitingForInput { return 4 }
        if session.working { return 6 }
        return 0
    }

    private var secondaryGlowOpacity: Double {
        if session.working && !session.done && !session.stuck && !session.waitingForInput { return 0.15 }
        return 0
    }

    private var secondaryGlowRadius: CGFloat {
        if session.working && !session.done && !session.stuck && !session.waitingForInput { return 16 }
        return 0
    }

    private var accessibilityStatus: String {
        if session.done { return "completed" }
        if session.stuck { return "stuck" }
        if session.waitingForInput { return "waiting for input" }
        if session.working { return isStale ? "stale" : "working" }
        return "idle"
    }
}
