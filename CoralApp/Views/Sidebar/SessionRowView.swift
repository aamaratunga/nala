import SwiftUI

struct SessionRowView: View {
    let session: Session
    var isSelected: Bool = false
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
                        .foregroundStyle(CoralTheme.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if let staleness = session.stalenessSeconds, staleness > 300, session.working {
                Text(formatStaleness(staleness))
                    .font(.caption2)
                    .foregroundStyle(CoralTheme.textTertiary)
            }

            agentBadge
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.displayLabel), \(session.agentType)")
        .accessibilityHint(isEditing ? "Editing name" : "Double-tap to rename")
    }

    // MARK: - Agent Badge

    private var agentBadge: some View {
        Text(session.agentType.capitalized)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(agentColor.opacity(0.12))
            .foregroundStyle(agentColor)
            .clipShape(Capsule())
    }

    private var agentColor: Color {
        switch session.agentType {
        case "terminal": return CoralTheme.teal
        case "gemini": return CoralTheme.magenta
        default: return CoralTheme.textSecondary
        }
    }

    private func formatStaleness(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}
