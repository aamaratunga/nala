import SwiftUI
import AppKit
import SwiftTerm

/// Displays terminal output using SwiftTerm's xterm-compatible terminal emulator.
struct TerminalDisplayView: NSViewRepresentable {
    let webSocket: TerminalWebSocket

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let tv = SwiftTerm.TerminalView(frame: .zero, font: font)

        // Dark theme colors
        tv.nativeBackgroundColor = NSColor(red: 0.102, green: 0.102, blue: 0.118, alpha: 1.0) // #1a1a1e
        tv.nativeForegroundColor = NSColor(red: 0.898, green: 0.898, blue: 0.898, alpha: 1.0) // #e5e5e5
        tv.caretColor = NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1.0)                // green

        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv

        // Hook up WebSocket output to feed content into the terminal
        context.coordinator.connectWebSocket(webSocket)

        return tv
    }

    func updateNSView(_ tv: SwiftTerm.TerminalView, context: Context) {
        // Reconnect if the webSocket instance changed (session switch)
        context.coordinator.connectWebSocket(webSocket)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        weak var terminalView: SwiftTerm.TerminalView?
        private weak var currentWebSocket: TerminalWebSocket?

        /// Wire the WebSocket's onOutput to feed content into the SwiftTerm view.
        func connectWebSocket(_ ws: TerminalWebSocket) {
            guard ws !== currentWebSocket else { return }
            currentWebSocket = ws

            ws.onOutput = { [weak self] content, cursorX, cursorY in
                self?.feedContent(content, cursorX: cursorX, cursorY: cursorY)
            }
        }

        /// Clear the terminal, write new content, and position the cursor.
        func feedContent(_ content: String, cursorX: Int?, cursorY: Int?) {
            guard let tv = terminalView else { return }

            // Clear screen + scrollback, home cursor
            tv.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
            // Convert bare LF to CR+LF so the terminal carriage-returns properly
            let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
                                    .replacingOccurrences(of: "\n", with: "\r\n")
            // Write the new content
            tv.feed(text: normalized)
            // Reposition cursor if coordinates provided
            if let x = cursorX, let y = cursorY {
                tv.feed(text: "\u{1b}[\(y + 1);\(x + 1)H")
            }
        }

        // MARK: - TerminalViewDelegate

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let text = String(bytes: data, encoding: .utf8) ?? ""
            currentWebSocket?.sendInput(text)
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            currentWebSocket?.sendResize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(content, forType: .string)
        }

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
