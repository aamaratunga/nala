import SwiftUI

struct SessionRowView: View {
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(session: session)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let icon = session.icon, !icon.isEmpty {
                        Text(icon)
                            .font(.callout)
                    }

                    Text(session.displayLabel)
                        .font(.headline)
                        .lineLimit(1)
                }

                if let status = session.status, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Right-side indicators
            VStack(alignment: .trailing, spacing: 2) {
                agentBadge

                if session.changedFileCount > 0 {
                    Label("\(session.changedFileCount)", systemImage: "doc.badge.plus")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var agentBadge: some View {
        Text(session.agentType.capitalized)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(agentColor.opacity(0.15))
            .foregroundStyle(agentColor)
            .clipShape(Capsule())
    }

    private var agentColor: Color {
        switch session.agentType {
        case "claude": .orange
        case "gemini": .blue
        default: .gray
        }
    }
}
