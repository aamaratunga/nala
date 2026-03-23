import SwiftUI
import AppKit
import SwiftTerm

/// Displays terminal output using SwiftTerm's xterm-compatible terminal emulator.
struct TerminalDisplayView: NSViewRepresentable {
    let webSocket: TerminalWebSocket

    /// Convert a 0–255 byte to SwiftTerm's UInt16 color component (0–65535).
    private static func c(_ byte: UInt16) -> UInt16 { byte * 257 }

    /// GitHub-dark-inspired ANSI palette (16 colors).
    private static let ansiPalette: [SwiftTerm.Color] = [
        // Normal colors
        /* 0 black   */ SwiftTerm.Color(red: c(0x48), green: c(0x4f), blue: c(0x58)),
        /* 1 red     */ SwiftTerm.Color(red: c(0xff), green: c(0x7b), blue: c(0x72)),
        /* 2 green   */ SwiftTerm.Color(red: c(0x7e), green: c(0xe7), blue: c(0x87)),
        /* 3 yellow  */ SwiftTerm.Color(red: c(0xd2), green: c(0x99), blue: c(0x22)),
        /* 4 blue    */ SwiftTerm.Color(red: c(0x58), green: c(0xa6), blue: c(0xff)),
        /* 5 magenta */ SwiftTerm.Color(red: c(0xd2), green: c(0xa8), blue: c(0xff)),
        /* 6 cyan    */ SwiftTerm.Color(red: c(0x79), green: c(0xc0), blue: c(0xff)),
        /* 7 white   */ SwiftTerm.Color(red: c(0xb1), green: c(0xba), blue: c(0xc4)),
        // Bright colors
        /* 8  brBlack   */ SwiftTerm.Color(red: c(0x6e), green: c(0x76), blue: c(0x81)),
        /* 9  brRed     */ SwiftTerm.Color(red: c(0xff), green: c(0xa1), blue: c(0x98)),
        /* 10 brGreen   */ SwiftTerm.Color(red: c(0xaf), green: c(0xf5), blue: c(0xb4)),
        /* 11 brYellow  */ SwiftTerm.Color(red: c(0xe3), green: c(0xb3), blue: c(0x41)),
        /* 12 brBlue    */ SwiftTerm.Color(red: c(0x79), green: c(0xc0), blue: c(0xff)),
        /* 13 brMagenta */ SwiftTerm.Color(red: c(0xd2), green: c(0xa8), blue: c(0xff)),
        /* 14 brCyan    */ SwiftTerm.Color(red: c(0xa5), green: c(0xd6), blue: c(0xff)),
        /* 15 brWhite   */ SwiftTerm.Color(red: c(0xf0), green: c(0xf6), blue: c(0xfc)),
    ]

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        let tv = SwiftTerm.TerminalView(frame: .zero, font: font)

        // Cool & modern theme (GitHub dark)
        tv.nativeBackgroundColor = NSColor(red: 0.051, green: 0.067, blue: 0.090, alpha: 1.0) // #0d1117
        tv.nativeForegroundColor = NSColor(red: 0.902, green: 0.929, blue: 0.953, alpha: 1.0) // #e6edf3
        tv.caretColor = NSColor(red: 0.345, green: 0.651, blue: 1.0, alpha: 1.0)              // #58a6ff

        tv.installColors(Self.ansiPalette)

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

        /// Whether the user has scrolled up from the bottom.
        private var isScrolledBack = false
        /// Pending content to apply when the user scrolls back to bottom.
        private var pendingContent: (content: String, cursorX: Int?, cursorY: Int?)?
        /// Debounce timer for terminal resize events.
        private var resizeTimer: Timer?

        /// Wire the WebSocket's onOutput to feed content into the SwiftTerm view.
        func connectWebSocket(_ ws: TerminalWebSocket) {
            guard ws !== currentWebSocket else { return }
            currentWebSocket = ws
            isScrolledBack = false
            pendingContent = nil

            ws.onOutput = { [weak self] content, cursorX, cursorY in
                self?.feedContent(content, cursorX: cursorX, cursorY: cursorY)
            }
        }

        /// Clear the terminal, write new content, and position the cursor.
        func feedContent(_ content: String, cursorX: Int?, cursorY: Int?) {
            guard let tv = terminalView else { return }

            if isScrolledBack {
                // Buffer the latest state; don't disrupt the user's scroll position
                pendingContent = (content, cursorX, cursorY)
                return
            }

            applyContent(content, cursorX: cursorX, cursorY: cursorY, to: tv)
        }

        private func applyContent(_ content: String, cursorX: Int?, cursorY: Int?, to tv: SwiftTerm.TerminalView) {
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

        /// Flush any buffered content when the user returns to the bottom.
        private func flushPending() {
            guard let tv = terminalView, let pending = pendingContent else { return }
            pendingContent = nil
            applyContent(pending.content, cursorX: pending.cursorX, cursorY: pending.cursorY, to: tv)
        }

        // MARK: - TerminalViewDelegate

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let text = String(bytes: data, encoding: .utf8) ?? ""
            currentWebSocket?.sendInput(text)
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            // Debounce resize events to avoid rapid server round-trips (e.g. during drag-resize)
            resizeTimer?.invalidate()
            resizeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.currentWebSocket?.sendResize(cols: newCols, rows: newRows)
            }
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {
            // position 1.0 = at the bottom of the scrollback
            let wasScrolledBack = isScrolledBack
            isScrolledBack = position < 0.999

            if wasScrolledBack && !isScrolledBack {
                flushPending()
            }
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(content, forType: .string)
        }

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
