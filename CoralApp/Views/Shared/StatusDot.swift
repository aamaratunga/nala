import SwiftUI

struct StatusDot: View {
    let session: Session

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if session.working {
                    Circle()
                        .stroke(color.opacity(0.5), lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .scaleEffect(pulseScale)
                        .opacity(pulseOpacity)
                        .animation(
                            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
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
}
