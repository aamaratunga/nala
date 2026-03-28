import SwiftUI

struct ProgressHeader: View {
    let title: String
    var subtitle: String? = nil
    var agentLabel: String? = nil
    var accentColor: Color = CoralTheme.coralPrimary
    var showSpinner: Bool = true
    var statusDotSession: Session? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if showSpinner {
                    ProgressView()
                        .controlSize(.small)
                } else if let session = statusDotSession {
                    StatusDot(session: session)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(CoralTheme.textSecondary)
                    }
                }

                Spacer()

                if let agentLabel {
                    Text(agentLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CoralTheme.textSecondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(CoralTheme.bgSurface.opacity(0.65))
            .background(.ultraThinMaterial)

            CoralTheme.accentDivider
        }
    }
}
