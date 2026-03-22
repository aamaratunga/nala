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

            agentBadge
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 5)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            accentBar
        }
    }

    // MARK: - Row Highlight

    @ViewBuilder
    private var rowBackground: some View {
        if let color = rowHighlightColor {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.12))
        }
    }

    @ViewBuilder
    private var accentBar: some View {
        if let color = rowHighlightColor {
            color
                .frame(width: 3)
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 6,
                    bottomLeadingRadius: 6,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                ))
        }
    }

    private var rowHighlightColor: Color? {
        if session.waitingForInput { return .orange }
        if session.stuck { return .red }
        if session.done { return .green }
        return nil
    }

    // MARK: - Agent Badge

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

    private var agentColor: Color { .secondary }
}
