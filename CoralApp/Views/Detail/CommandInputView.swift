import SwiftUI
import AppKit

// MARK: - Multi-line text view with Enter-to-send, Shift+Enter for newline

private struct CommandTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isDisabled: Bool
    let onSubmit: () -> Void
    let onHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.delegate = context.coordinator
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // Become first responder after a brief delay so the view is in the hierarchy
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
            context.coordinator.reportHeight(for: textView)
        }
        textView.isEditable = !isDisabled
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onHeightChange = onHeightChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onHeightChange: onHeightChange)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onSubmit: () -> Void
        var onHeightChange: (CGFloat) -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onHeightChange: @escaping (CGFloat) -> Void) {
            _text = text
            self.onSubmit = onSubmit
            self.onHeightChange = onHeightChange
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
            reportHeight(for: tv)
        }

        func reportHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let height = layoutManager.usedRect(for: textContainer).height
                + textView.textContainerInset.height * 2
            onHeightChange(height)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                // Plain Enter → send command
                if !NSEvent.modifierFlags.contains(.shift) {
                    onSubmit()
                    return true
                }
                // Shift+Enter → insert newline (default behavior)
            }
            return false
        }
    }
}

// MARK: - Command Input Bar

struct CommandInputView: View {
    let session: Session
    @Environment(SessionStore.self) private var store
    @State private var command = ""
    @State private var isSending = false
    @AppStorage("commandInputHeight") private var inputHeight: Double = 80
    @GestureState private var dragOffset: CGFloat = 0

    private var hasText: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Current height accounting for any in-progress drag.
    private var effectiveHeight: CGFloat {
        min(max(CGFloat(inputHeight) - dragOffset, 36), 300)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Resize handle
            resizeHandle

            HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            ZStack(alignment: .topLeading) {
                // Placeholder
                if command.isEmpty {
                    Text("Send command to \(session.displayLabel)…")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }

                CommandTextView(
                    text: $command,
                    placeholder: "Send command…",
                    isDisabled: isSending,
                    onSubmit: { sendCommand() },
                    onHeightChange: { _ in }
                )
                .frame(height: effectiveHeight)
            }

            if isSending {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 2)
            } else {
                Button {
                    sendCommand()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(hasText ? Color.accentColor : Color.secondary.opacity(0.4))
                .disabled(!hasText)
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        inputHeight = Double(min(max(CGFloat(inputHeight) - value.translation.height, 36), 300))
                    }
            )
    }

    private func sendCommand() {
        guard hasText else { return }

        isSending = true
        let cmd = command
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
