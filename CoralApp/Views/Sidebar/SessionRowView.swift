import SwiftUI

struct SessionRowView: View {
    let session: Session
    var isEditing: Bool = false
    var onRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}

    @State private var editText: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(session: session)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let icon = session.icon, !icon.isEmpty {
                        Text(icon)
                            .font(.callout)
                    }

                    if isEditing {
                        TextField("Name", text: $editText)
                            .font(.headline)
                            .textFieldStyle(.plain)
                            .focused($isTextFieldFocused)
                            .onSubmit {
                                let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty || trimmed == session.displayLabel {
                                    onCancelRename()
                                } else {
                                    onRename(trimmed)
                                }
                            }
                            .onExitCommand {
                                onCancelRename()
                            }
                            .onAppear {
                                editText = session.displayLabel
                                DispatchQueue.main.async {
                                    isTextFieldFocused = true
                                }
                            }
                    } else {
                        Text(session.displayLabel)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }

                if let status = session.status, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if let staleness = session.stalenessSeconds, staleness > 300, session.working {
                Text(formatStaleness(staleness))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            agentBadge
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            accentBar
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.displayLabel), \(session.agentType)")
        .accessibilityHint(isEditing ? "Editing name" : "Double-tap to rename")
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

    private var agentColor: Color {
        session.agentType == "terminal" ? .teal : .secondary
    }

    private func formatStaleness(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}
