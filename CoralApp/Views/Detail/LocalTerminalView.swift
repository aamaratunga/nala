import SwiftUI
import AppKit
import SwiftTerm

/// A live PTY terminal that attaches to a tmux session via `tmux attach`.
/// Used for interactive terminal sessions (not agent sessions).
struct LocalTerminalView: NSViewRepresentable {
    let sessionName: String
    @Binding var isTerminated: Bool

    /// Convert a 0–255 byte to SwiftTerm's UInt16 color component (0–65535).
    private static func c(_ byte: UInt16) -> UInt16 { byte * 257 }

    /// GitHub-dark-inspired ANSI palette (16 colors) — shared with TerminalDisplayView.
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

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: .zero)

        // Font — prefer MesloLGS Nerd Font for icon glyphs
        if let nerdFont = NSFont(name: "MesloLGS Nerd Font Mono", size: 14) {
            tv.font = nerdFont
        } else {
            tv.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        }

        // GitHub dark theme
        tv.nativeBackgroundColor = NSColor(red: 0.051, green: 0.067, blue: 0.090, alpha: 1.0)
        tv.nativeForegroundColor = NSColor(red: 0.902, green: 0.929, blue: 0.953, alpha: 1.0)
        tv.caretColor = NSColor(red: 0.345, green: 0.651, blue: 1.0, alpha: 1.0)
        tv.installColors(Self.ansiPalette)

        tv.processDelegate = context.coordinator

        // Launch: /bin/zsh -l -c 'tmux attach -t <session>'
        // Using login shell so tmux is found via PATH
        tv.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", "tmux attach -t \(sessionName)"]
        )

        return tv
    }

    func updateNSView(_ tv: LocalProcessTerminalView, context: Context) {
        // Nothing to update — the PTY session is self-contained
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isTerminated: $isTerminated)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        @Binding var isTerminated: Bool

        init(isTerminated: Binding<Bool>) {
            _isTerminated = isTerminated
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async {
                self.isTerminated = true
            }
        }
    }
}
