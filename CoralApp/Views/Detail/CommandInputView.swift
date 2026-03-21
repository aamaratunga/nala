import SwiftUI

struct CommandInputView: View {
    let session: Session
    @Environment(SessionStore.self) private var store
    @State private var command = ""
    @State private var isSending = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)

            TextField("Send command to \(session.displayLabel)…", text: $command)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($isFocused)
                .onSubmit {
                    sendCommand()
                }
                .disabled(isSending)

            if isSending {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    sendCommand()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear {
            isFocused = true
        }
    }

    private func sendCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isSending = true
        let cmd = trimmed
        command = ""

        Task {
            defer { isSending = false }
            try? await store.apiClient.sendCommand(
                sessionName: session.name,
                command: cmd,
                agentType: session.agentType,
                sessionId: session.sessionId
            )
        }
    }
}
