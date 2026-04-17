import SwiftUI

struct StatusDot: View {
    let session: Session

    @State private var glowActive = false

    private var isStale: Bool {
        guard session.status == .working, let staleness = session.stalenessSeconds else { return false }
        return staleness > 300
    }

    private var isActivelyWorking: Bool {
        session.status == .working && !isStale
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
        switch session.status {
        case .done:             return NalaTheme.green
        case .waitingForInput:  return NalaTheme.amber
        case .working:          return NalaTheme.teal
        case .sleeping:         return NalaTheme.textTertiary
        case .idle:             return NalaTheme.textTertiary
        }
    }

    private var glowColor: Color { color }

    private var primaryGlowOpacity: Double {
        switch session.status {
        case .done, .waitingForInput: return 0.2
        case .working:                return 0.4
        case .sleeping, .idle:                return 0
        }
    }

    private var primaryGlowRadius: CGFloat {
        switch session.status {
        case .done, .waitingForInput: return 4
        case .working:                return 6
        case .sleeping, .idle:                return 0
        }
    }

    private var secondaryGlowOpacity: Double {
        switch session.status {
        case .working: return 0.15
        default:       return 0
        }
    }

    private var secondaryGlowRadius: CGFloat {
        switch session.status {
        case .working: return 16
        default:       return 0
        }
    }

    private var accessibilityStatus: String {
        switch session.status {
        case .done:             return "completed"
        case .waitingForInput:  return "waiting for input"
        case .working:          return isStale ? "stale" : "working"
        case .sleeping:         return "sleeping"
        case .idle:             return "idle"
        }
    }
}
