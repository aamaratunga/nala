import SwiftUI

struct ProgressHeader: View {
    let title: String
    var subtitle: String? = nil
    var agentLabel: String? = nil
    var accentColor: Color = .accentColor
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
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let agentLabel {
                    Text(agentLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            CoralTheme.accentGradient(accentColor)
                .frame(height: 1)
        }
    }
}
