import SwiftUI
import AppKit
import SwiftTerm

/// Coalesces PTY data during bursts so SwiftTerm renders the final
/// state instead of dozens of intermediate scroll positions.
final class CoralTerminalView: LocalProcessTerminalView {
    /// The tmux session name this terminal is attached to.
    var sessionName: String = ""

    /// The tmux session name of the currently selected (visible) terminal.
    /// Only that terminal accepts first-responder status, preventing macOS
    /// from restoring focus to a hidden terminal on app reactivation.
    static var activeSessionName: String?

    /// Whether this terminal is the currently selected (visible) one.
    var isActiveTerminal: Bool { sessionName == Self.activeSessionName }

    private var pendingBytes: [UInt8] = []
    private var coalesceTimer: DispatchWorkItem?
    private var burstStart: TimeInterval = 0

    /// Quiet period — flush when no new data arrives for this long.
    private static let quietPeriod: TimeInterval = 0.004  // 4ms

    /// Max coalesce window — force flush to keep UI responsive during
    /// sustained output (e.g. `cat large_file`).
    private static let maxCoalesceWindow: TimeInterval = 0.050  // 50ms ≈ 3 frames

    override func dataReceived(slice: ArraySlice<UInt8>) {
        pendingBytes.append(contentsOf: slice)

        coalesceTimer?.cancel()

        let now = CACurrentMediaTime()
        if burstStart == 0 { burstStart = now }

        // Force flush if coalescing too long
        if now - burstStart >= Self.maxCoalesceWindow {
            flushPendingData()
            return
        }

        // Wait for quiet period (detects end of burst)
        let item = DispatchWorkItem { [weak self] in
            self?.flushPendingData()
        }
        coalesceTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietPeriod, execute: item)
    }

    private func flushPendingData() {
        coalesceTimer?.cancel()
        coalesceTimer = nil
        burstStart = 0
        guard !pendingBytes.isEmpty else { return }
        let data = pendingBytes
        pendingBytes.removeAll(keepingCapacity: true)
        super.dataReceived(slice: data[...])
    }
}

/// A live PTY terminal that attaches to a tmux session via `tmux attach`.
struct LocalTerminalView: NSViewRepresentable {
    let sessionName: String
    @Binding var isTerminated: Bool

    /// Weak map from tmux session name → terminal view, used by
    /// ContentView.focusTerminal() to find the correct visible terminal.
    static let viewsBySession = NSMapTable<NSString, CoralTerminalView>(
        keyOptions: .strongMemory, valueOptions: .weakMemory
    )

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

    func makeNSView(context: Context) -> CoralTerminalView {
        let tv = CoralTerminalView(frame: .zero)
        tv.sessionName = sessionName
        Self.viewsBySession.setObject(tv, forKey: sessionName as NSString)

        // Font — prefer MesloLGS Nerd Font for icon glyphs
        if let nerdFont = NSFont(name: "MesloLGS Nerd Font Mono", size: 16) {
            tv.font = nerdFont
        } else {
            tv.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
        }

        // GitHub dark theme
        tv.nativeBackgroundColor = NSColor(red: 0.051, green: 0.067, blue: 0.090, alpha: 1.0)
        tv.nativeForegroundColor = NSColor(red: 0.902, green: 0.929, blue: 0.953, alpha: 1.0)
        tv.caretColor = NSColor(red: 0.345, green: 0.651, blue: 1.0, alpha: 1.0)
        tv.installColors(Self.ansiPalette)

        // Disable mouse reporting so SwiftTerm doesn't clear selections on
        // linefeed (its linefeed handler calls selectNone when this is true).
        // The Coordinator's mouse monitor forwards events to tmux instead.
        tv.allowMouseReporting = false

        tv.processDelegate = context.coordinator
        context.coordinator.terminalView = tv
        context.coordinator.installMouseMonitor()
        context.coordinator.installKeyMonitor()

        // Enable mouse mode (so trackpad/scroll wheel works) then attach.
        // Using login shell so tmux is found via PATH.
        tv.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", "tmux set-option -t \(sessionName) mouse on && tmux attach -t \(sessionName)"]
        )

        return tv
    }

    func updateNSView(_ tv: CoralTerminalView, context: Context) {
        // Nothing to update — the PTY session is self-contained
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionName: sessionName, isTerminated: $isTerminated)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let sessionName: String
        @Binding var isTerminated: Bool
        weak var terminalView: CoralTerminalView?
        private var mouseMonitor: Any?
        private var keyMonitor: Any?
        private var forwardedMouseDown = false
        private var didDrag = false
        private var scrollAccumulator: CGFloat = 0
        private var lastRepeatForward: TimeInterval = 0

        init(sessionName: String, isTerminated: Binding<Bool>) {
            self.sessionName = sessionName
            _isTerminated = isTerminated
        }

        deinit {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
            }
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }

        // MARK: - Mouse & scroll forwarding

        /// Converts an NSEvent location to terminal grid coordinates.
        private func gridPosition(for event: NSEvent, tv: CoralTerminalView, terminal: SwiftTerm.Terminal) -> (col: Int, row: Int) {
            let point = tv.convert(event.locationInWindow, from: nil)
            let cols = CGFloat(terminal.cols)
            let rows = CGFloat(terminal.rows)
            let col = max(0, min(Int(point.x / (tv.bounds.width / cols)), terminal.cols - 1))
            let row = max(0, min(Int((tv.bounds.height - point.y) / (tv.bounds.height / rows)), terminal.rows - 1))
            return (col, row)
        }

        /// Encodes mouse button and modifier flags for the terminal mouse protocol.
        /// Remaps NSEvent button numbers (0=left, 1=right, 2=middle) to terminal
        /// protocol numbers (0=left, 1=middle, 2=right).
        private func encodeMouseFlags(for event: NSEvent, terminal: SwiftTerm.Terminal, release: Bool = false) -> Int {
            let flags = event.modifierFlags
            let button: Int
            switch event.buttonNumber {
            case 1:  button = 2  // NSEvent right → terminal right
            case 2:  button = 1  // NSEvent middle → terminal middle
            default: button = event.buttonNumber
            }
            return terminal.encodeButton(
                button: button, release: release,
                shift: flags.contains(.shift),
                meta: flags.contains(.option),
                control: flags.contains(.control)
            )
        }

        /// Copies tmux's most recent paste buffer to the macOS clipboard.
        private func syncTmuxPasteBufferToClipboard() {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                proc.arguments = ["tmux", "show-buffer"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard proc.terminationStatus == 0,
                          let text = String(data: data, encoding: .utf8),
                          !text.isEmpty else { return }
                    DispatchQueue.main.async {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                } catch { }
            }
        }

        /// Installs a local event monitor that intercepts mouse and scroll events
        /// targeting our terminal view.  When tmux has mouse mode enabled, mouse
        /// events (click, drag, release) are forwarded to tmux via the terminal's
        /// mouse protocol, giving tmux full control of text selection with
        /// auto-scroll.  Scroll wheel events are translated into mouse-protocol
        /// escape sequences.  When mouse mode is off, all events pass through to
        /// SwiftTerm for native selection and scrollback.
        ///
        /// This works around two SwiftTerm issues:
        /// 1. `mouseDragged` silently swallows drag events when mouseMode is
        ///    `.buttonEventTracking` (tmux's mode), preventing both forwarding
        ///    and native selection.
        /// 2. `scrollWheel` only scrolls SwiftTerm's own buffer, which is empty
        ///    when tmux uses the alternate screen.
        func installMouseMonitor() {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
            ) { [weak self] event in
                guard let self,
                      let tv = self.terminalView,
                      let terminal = tv.terminal else {
                    return event
                }

                switch event.type {
                case .leftMouseDown:
                    // Only intercept events targeting our terminal view
                    guard let window = tv.window,
                          let hitView = window.contentView?.hitTest(event.locationInWindow),
                          hitView === tv || hitView.isDescendant(of: tv) else {
                        return event
                    }
                    let mode = terminal.mouseMode
                    // sendButtonPress() (internal): true for .vt200, .buttonEventTracking, .anyEvent
                    guard mode == .vt200 || mode == .buttonEventTracking || mode == .anyEvent else {
                        return event  // let SwiftTerm handle native selection
                    }
                    // Ensure the terminal becomes first responder on click
                    if let window = tv.window, window.firstResponder !== tv {
                        window.makeFirstResponder(tv)
                    }
                    self.forwardedMouseDown = true
                    self.didDrag = false
                    let flags = self.encodeMouseFlags(for: event, terminal: terminal)
                    let pos = self.gridPosition(for: event, tv: tv, terminal: terminal)
                    terminal.sendEvent(buttonFlags: flags, x: pos.col, y: pos.row)
                    return nil  // consume — prevent SwiftTerm's native selection

                case .leftMouseDragged:
                    guard self.forwardedMouseDown else { return event }
                    let mode = terminal.mouseMode
                    // sendButtonTracking() (internal): true for .buttonEventTracking, .anyEvent
                    guard mode == .buttonEventTracking || mode == .anyEvent else { return nil }
                    self.didDrag = true
                    let flags = self.encodeMouseFlags(for: event, terminal: terminal)
                    let pos = self.gridPosition(for: event, tv: tv, terminal: terminal)
                    terminal.sendMotion(buttonFlags: flags, x: pos.col, y: pos.row, pixelX: 0, pixelY: 0)
                    return nil

                case .leftMouseUp:
                    guard self.forwardedMouseDown else { return event }
                    self.forwardedMouseDown = false
                    let flags = self.encodeMouseFlags(for: event, terminal: terminal, release: true)
                    let pos = self.gridPosition(for: event, tv: tv, terminal: terminal)
                    terminal.sendEvent(buttonFlags: flags, x: pos.col, y: pos.row)
                    if self.didDrag {
                        self.syncTmuxPasteBufferToClipboard()
                        self.didDrag = false
                    }
                    return nil

                case .scrollWheel:
                    // Only intercept events targeting our terminal view
                    guard let window = tv.window,
                          let hitView = window.contentView?.hitTest(event.locationInWindow),
                          hitView === tv || hitView.isDescendant(of: tv) else {
                        return event
                    }
                    // When mouse mode is off, let SwiftTerm handle native scrollback
                    guard terminal.mouseMode != .off else { return event }

                    // Ignore momentum/inertia events (trackpad lift-off)
                    guard event.momentumPhase == [] else {
                        if event.momentumPhase == .ended {
                            self.scrollAccumulator = 0
                        }
                        return nil
                    }

                    let buttonFlags: Int
                    if event.hasPreciseScrollingDeltas {
                        // Trackpad: accumulate pixel deltas until we reach one line
                        let delta = event.scrollingDeltaY / 20.0
                        if delta == 0 { return nil }
                        if (delta > 0) != (self.scrollAccumulator > 0) {
                            self.scrollAccumulator = 0
                        }
                        self.scrollAccumulator += delta
                        guard abs(self.scrollAccumulator) >= 1.0 else { return nil }
                        buttonFlags = self.scrollAccumulator > 0 ? 64 : 65
                        self.scrollAccumulator -= self.scrollAccumulator > 0 ? 1.0 : -1.0
                    } else {
                        // Mouse wheel: each notch fires one scroll event
                        let delta = event.deltaY
                        if delta == 0 { return nil }
                        buttonFlags = delta > 0 ? 64 : 65
                    }

                    let pos = self.gridPosition(for: event, tv: tv, terminal: terminal)
                    terminal.sendEvent(buttonFlags: buttonFlags, x: pos.col, y: pos.row)
                    return nil  // consume — don't let SwiftTerm's no-op scrollback run

                default:
                    return event
                }
            }
        }

        /// Intercepts key-down events targeting our terminal view for two
        /// purposes:
        ///
        /// 1. **Key-repeat throttle** — TUI apps (Claude Code) redraw the full
        ///    screen for each arrow-key press.  At the OS's max repeat rate
        ///    (~120/s) events pile up in the tmux PTY buffer faster than the
        ///    app can render, causing a backlog that keeps replaying after the
        ///    key is released.  We cap repeats at ~16/s — smooth for list
        ///    navigation while leaving headroom for the redraw round-trip.
        ///
        /// 2. **Shift+Enter** — sends the CSI u escape sequence so apps can
        ///    distinguish it from plain Enter and insert a newline.  Uses
        ///    `tmux send-keys -H` to inject the raw bytes directly into the
        ///    pane's PTY, bypassing tmux's own key input parser.
        func installKeyMonitor() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let tv = self.terminalView else {
                    return event
                }

                // Only intercept events targeting our terminal view
                guard let window = tv.window,
                      let firstResponder = window.firstResponder as? NSView,
                      firstResponder === tv || firstResponder.isDescendant(of: tv) else {
                    return event
                }

                // Throttle key repeats to prevent PTY buffer backlog
                if event.isARepeat {
                    let now = CACurrentMediaTime()
                    guard now - self.lastRepeatForward >= 0.06 else { return nil }
                    self.lastRepeatForward = now
                }

                // keyCode 36 = Return; check only Shift is held
                let mods = event.modifierFlags.intersection([.shift, .command, .control, .option])
                guard event.keyCode == 36 && mods == .shift else { return event }

                // Send CSI u for Shift+Enter (\e[13;2u) directly to the tmux
                // pane via send-keys -H, bypassing tmux's key input parser.
                let session = self.sessionName
                DispatchQueue.global(qos: .userInteractive).async {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    // \e[13;2u = ESC [ 1 3 ; 2 u = 1b 5b 31 33 3b 32 75
                    proc.arguments = ["tmux", "send-keys", "-t", session, "-H", "1b", "5b", "31", "33", "3b", "32", "75"]
                    try? proc.run()
                    proc.waitUntilExit()
                }
                return nil  // consume the event
            }
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
