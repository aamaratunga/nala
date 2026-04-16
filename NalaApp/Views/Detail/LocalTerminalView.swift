import SwiftUI
import AppKit
import SwiftTerm
import os
import QuartzCore

/// Coalesces PTY data during bursts so SwiftTerm renders the final
/// state instead of dozens of intermediate scroll positions.
final class NalaTerminalView: LocalProcessTerminalView {
    private static let logger = Logger(subsystem: "com.nala.app", category: "Terminal")

    /// The tmux session name this terminal is attached to.
    var sessionName: String = ""

    deinit {
        // Cancel any pending coalesce timer to prevent stale callbacks.
        coalesceTimer?.cancel()
        // Explicitly terminate the PTY process and close DispatchIO.
        // Without this, LocalProcess survives deallocation (retained by
        // the pending io.read closure) and its drainReceivedData loop
        // continues running on the main queue with a nil delegate —
        // burning CPU and starving the run loop on every session switch.
        process.terminate()
    }

    private var pendingBytes: [UInt8] = []
    private var pendingOSC52: [UInt8] = []
    private var coalesceTimer: DispatchWorkItem?
    private var burstStart: TimeInterval = 0

    /// True while chunks are being drained to SwiftTerm.
    /// Prevents re-entrant flush from coalesce timer.
    private var isDraining = false

    /// Quiet period — flush when no new data arrives for this long.
    private static let quietPeriod: TimeInterval = 0.004  // 4ms

    /// Max coalesce window — force flush to keep UI responsive during
    /// sustained output (e.g. `cat large_file`).
    private static let maxCoalesceWindow: TimeInterval = 0.050  // 50ms ≈ 3 frames

    /// Max bytes per flush to SwiftTerm. 16KB keeps each parse under ~15ms
    /// based on observed throughput (10KB → 10ms, 19KB → 18ms).
    private static let chunkSize = 16_384

    override func dataReceived(slice: ArraySlice<UInt8>) {
        pendingBytes.append(contentsOf: slice)

        // While draining, just accumulate — the drain loop picks up new data.
        guard !isDraining else { return }

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
        guard !isDraining else { return }
        guard !pendingBytes.isEmpty else { return }
        let data = pendingBytes
        pendingBytes.removeAll(keepingCapacity: true)
        handleOSC52(in: data)

        // Small buffers: flush directly (common case, no overhead)
        if data.count <= Self.chunkSize {
            let flushStart = CACurrentMediaTime()
            super.dataReceived(slice: data[...])
            let elapsed = CACurrentMediaTime() - flushStart
            if elapsed > 0.01 {
                Self.logger.warning("flushPendingData took \(String(format: "%.1f", elapsed * 1000))ms (\(data.count) bytes) for '\(self.sessionName)'")
            }
            if elapsed > 0.05 {
                PersistentLog.shared.write(
                    "FLUSH_SLOW \(String(format: "%.0f", elapsed * 1000))ms \(data.count)B session=\(self.sessionName)",
                    category: "Terminal"
                )
            }
            return
        }

        // Large buffers: drain in chunks, yielding to the run loop between each
        isDraining = true
        drainChunks(data: data, offset: 0, totalBytes: data.count, flushStart: CACurrentMediaTime())
    }

    private func drainChunks(data: [UInt8], offset: Int, totalBytes: Int, flushStart: TimeInterval) {
        guard window != nil else {
            isDraining = false
            return
        }

        let end = min(offset + Self.chunkSize, data.count)
        super.dataReceived(slice: data[offset..<end])

        if end < data.count {
            // Yield to run loop, then process next chunk
            DispatchQueue.main.async { [weak self] in
                self?.drainChunks(data: data, offset: end, totalBytes: totalBytes, flushStart: flushStart)
            }
            return
        }

        // Batch done — log total time
        let elapsed = CACurrentMediaTime() - flushStart
        if elapsed > 0.01 {
            let chunks = Int(ceil(Double(totalBytes) / Double(Self.chunkSize)))
            Self.logger.warning("flushPendingData took \(String(format: "%.1f", elapsed * 1000))ms (\(totalBytes) bytes, \(chunks) chunks) for '\(self.sessionName)'")
            if elapsed > 0.05 {
                PersistentLog.shared.write(
                    "FLUSH_SLOW \(String(format: "%.0f", elapsed * 1000))ms \(totalBytes)B \(chunks)chunks session=\(self.sessionName)",
                    category: "Terminal"
                )
            }
        }

        // Check if new data arrived during draining
        if !pendingBytes.isEmpty {
            let newData = pendingBytes
            pendingBytes.removeAll(keepingCapacity: true)
            handleOSC52(in: newData)
            drainChunks(data: newData, offset: 0, totalBytes: newData.count, flushStart: CACurrentMediaTime())
        } else {
            isDraining = false
        }
    }

    /// Scans data for OSC 52 clipboard sequences and copies decoded
    /// content to NSPasteboard.  Works around a missing bridge in
    /// SwiftTerm's macOS TerminalView — see iOSTerminalView.swift:2646
    /// for the equivalent iOS bridge that macOS is missing.
    ///
    /// Accepts any selection parameter (c, p, s, empty, etc.) since tmux
    /// may vary which it uses depending on configuration.
    private func handleOSC52(in data: [UInt8]) {
        // OSC 52 starts with: ESC ] 5 2 ;
        let osc52Start: [UInt8] = [0x1b, 0x5d, 0x35, 0x32, 0x3b]

        // Drop oversized buffer to prevent unbounded growth
        if pendingOSC52.count > 1_048_576 {
            pendingOSC52.removeAll()
            return
        }

        // Prepend any leftover partial from the previous flush
        let scanData: [UInt8]
        if !pendingOSC52.isEmpty {
            scanData = pendingOSC52 + data
            pendingOSC52.removeAll()
        } else {
            scanData = data
        }

        var i = 0
        while i <= scanData.count - osc52Start.count {
            guard scanData[i...].starts(with: osc52Start) else {
                i += 1
                continue
            }

            // Skip past "ESC ] 5 2 ;" to find the selection param and semicolon
            // Format: ESC ] 52 ; <Pc> ; <base64> BEL/ST
            // <Pc> can be empty, "c", "p", "s", etc.
            var semicolonIndex: Int?
            for j in (i + osc52Start.count)..<min(i + osc52Start.count + 10, scanData.count) {
                if scanData[j] == 0x3b { // ';'
                    semicolonIndex = j
                    break
                }
            }
            guard let payloadStart = semicolonIndex.map({ $0 + 1 }) else {
                // Incomplete — no second semicolon yet
                pendingOSC52 = Array(scanData[i...])
                break
            }

            // Look for BEL (\x07) or ST (ESC \)
            var end: Int?
            for j in payloadStart..<scanData.count {
                if scanData[j] == 0x07 {
                    end = j
                    break
                }
                if scanData[j] == 0x1b, j + 1 < scanData.count, scanData[j + 1] == 0x5c {
                    end = j
                    break
                }
            }
            guard let terminatorIndex = end else {
                // Incomplete sequence — save for next flush
                pendingOSC52 = Array(scanData[i...])
                break
            }
            let base64Bytes = Array(scanData[payloadStart..<terminatorIndex])
            if let base64String = String(bytes: base64Bytes, encoding: .ascii),
               let decoded = Data(base64Encoded: base64String),
               let text = String(data: decoded, encoding: .utf8) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([text as NSString])
            }
            i = terminatorIndex + 1
        }
    }
}

/// A live PTY terminal that attaches to a tmux session via `tmux attach`.
struct LocalTerminalView: NSViewRepresentable {
    let sessionName: String
    @Binding var isTerminated: Bool
    /// Called when the user presses Esc or Ctrl+C (cancel keys).
    var onCancel: (() -> Void)?
    /// Called when the user presses Enter (plain, no modifiers) — used for
    /// optimistic permission-accept detection.
    var onPermissionAccepted: (() -> Void)?

    /// Weak map from tmux session name → terminal view, used by
    /// ContentView.focusTerminal() to find the correct visible terminal.
    static let viewsBySession = NSMapTable<NSString, NalaTerminalView>(
        keyOptions: .strongMemory, valueOptions: .weakMemory
    )

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func makeNSView(context: Context) -> NalaTerminalView {
        let tv = NalaTerminalView(frame: .zero)
        tv.sessionName = sessionName
        Self.viewsBySession.setObject(tv, forKey: sessionName as NSString)

        // Auto-focus: only one terminal view exists at a time, so it
        // should always accept keyboard input. The async lets SwiftUI
        // finish layout before we request first-responder status.
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow else { return }
            window.makeFirstResponder(tv)
        }

        // Font — prefer JetBrains Mono per DESIGN.md, fall back to MesloLGS Nerd Font (icon glyphs)
        if let jbMono = NSFont(name: "JetBrains Mono", size: 16) {
            tv.font = jbMono
        } else if let nerdFont = NSFont(name: "MesloLGS Nerd Font Mono", size: 16) {
            tv.font = nerdFont
        } else {
            tv.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
        }

        // GitHub dark theme
        tv.nativeBackgroundColor = NalaTheme.terminalNSBackground
        tv.nativeForegroundColor = NalaTheme.terminalNSForeground
        tv.caretColor = NalaTheme.terminalNSCaret
        tv.installColors(NalaTheme.ansiPalette)

        // Disable mouse reporting so SwiftTerm doesn't clear selections on
        // linefeed (its linefeed handler calls selectNone when this is true).
        // The Coordinator's mouse monitor forwards events to tmux instead.
        tv.allowMouseReporting = false

        tv.processDelegate = context.coordinator
        context.coordinator.terminalView = tv
        context.coordinator.installMouseMonitor()
        context.coordinator.installKeyMonitor()

        // Enable OSC 52 clipboard bridge and mouse mode, then attach.
        // - set-clipboard on: tmux generates OSC 52 on every copy operation
        // - terminal-features: tells tmux that xterm-256color supports clipboard
        //   (the system terminfo lacks the Ms capability)
        // All other copy-mode bindings come from the user's tmux.conf.
        let escaped = Self.shellEscape(sessionName)
        tv.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", """
                tmux set -s set-clipboard on \\; \
                set -as terminal-features 'xterm-256color:clipboard' \\; \
                set -t \(escaped) mouse on \
                && tmux attach -t \(escaped)
                """]
        )

        return tv
    }

    func updateNSView(_ tv: NalaTerminalView, context: Context) {
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionName: sessionName, isTerminated: $isTerminated, onCancel: onCancel, onPermissionAccepted: onPermissionAccepted)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let sessionName: String
        @Binding var isTerminated: Bool
        weak var terminalView: NalaTerminalView?
        private var mouseMonitor: Any?
        private var keyMonitor: Any?
        private var forwardedMouseDown = false
        private var cmdClickPending = false
        private var didDrag = false
        private var scrollAccumulator: CGFloat = 0
        private var lastRepeatForward: TimeInterval = 0
        private let onCancel: (() -> Void)?
        private let onPermissionAccepted: (() -> Void)?

        init(sessionName: String, isTerminated: Binding<Bool>, onCancel: (() -> Void)? = nil, onPermissionAccepted: (() -> Void)? = nil) {
            self.sessionName = sessionName
            _isTerminated = isTerminated
            self.onCancel = onCancel
            self.onPermissionAccepted = onPermissionAccepted
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
        private func gridPosition(for event: NSEvent, tv: NalaTerminalView, terminal: SwiftTerm.Terminal) -> (col: Int, row: Int) {
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

                // Only process events from our terminal's window — prevents
                // consuming clicks in the Settings window or other auxiliaries.
                guard event.window === tv.window else { return event }

                switch event.type {
                case .leftMouseDown:
                    // Only intercept events targeting our terminal view
                    guard let window = tv.window,
                          let hitView = window.contentView?.hitTest(event.locationInWindow),
                          hitView === tv || hitView.isDescendant(of: tv) else {
                        return event
                    }
                    // Reset stale Cmd+Click state from any abandoned gesture
                    // (e.g. mouseUp never delivered after app backgrounded)
                    self.cmdClickPending = false
                    // Cmd+Click: intercept for link detection instead of forwarding to tmux
                    if event.modifierFlags.contains(.command) {
                        if let window = tv.window, window.firstResponder !== tv {
                            window.makeFirstResponder(tv)
                        }
                        self.cmdClickPending = true
                        return nil
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
                    // Cancel pending Cmd+Click if user drags (selecting text, not clicking)
                    self.cmdClickPending = false
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
                    // Cmd+Click: detect URL at click position and open in browser
                    if self.cmdClickPending {
                        self.cmdClickPending = false
                        // Only open link if mouse is still over our terminal view
                        guard let window = tv.window,
                              let hitView = window.contentView?.hitTest(event.locationInWindow),
                              hitView === tv || hitView.isDescendant(of: tv) else {
                            return nil
                        }
                        let pos = self.gridPosition(for: event, tv: tv, terminal: terminal)
                        if let link = terminal.link(at: .screen(Position(col: pos.col, row: pos.row)), mode: .explicitAndImplicit),
                           let url = URL(string: link) {
                            NSWorkspace.shared.open(url)
                        }
                        return nil
                    }
                    guard self.forwardedMouseDown else { return event }
                    self.forwardedMouseDown = false
                    let flags = self.encodeMouseFlags(for: event, terminal: terminal, release: true)
                    let pos = self.gridPosition(for: event, tv: tv, terminal: terminal)
                    terminal.sendEvent(buttonFlags: flags, x: pos.col, y: pos.row)
                    self.didDrag = false
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

                // Only process events from our terminal's window
                guard event.window === tv.window else { return event }

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

                let mods = event.modifierFlags.intersection([.shift, .command, .control, .option])

                // Cmd+C: copy tmux selection to macOS clipboard.
                if event.keyCode == 8 && mods == .command {
                    let session = self.sessionName
                    DispatchQueue.global(qos: .userInitiated).async {
                        let proc = Process()
                        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                        proc.arguments = ["tmux", "send-keys", "-X", "-t", session,
                                          "copy-pipe-and-cancel", "pbcopy"]
                        proc.standardOutput = FileHandle.nullDevice
                        proc.standardError = FileHandle.nullDevice
                        try? proc.run()
                        proc.waitUntilExit()
                    }
                    return nil
                }

                // Cmd+V: paste macOS clipboard into terminal.
                // SwiftTerm's paste(_:) handles bracketed paste mode.
                if event.keyCode == 9 && mods == .command {
                    tv.paste(self)
                    return nil
                }

                // Esc (keyCode 53) or Ctrl+C (keyCode 8 + .control): notify cancel.
                // Let the key pass through to tmux so Claude Code receives the interrupt.
                if event.keyCode == 53 || (event.keyCode == 8 && mods == .control) {
                    self.onCancel?()
                    return event
                }

                // Plain Enter (keyCode 36, no modifiers): notify permission acceptance.
                // Let the key pass through to tmux.
                if event.keyCode == 36 && mods.isEmpty {
                    self.onPermissionAccepted?()
                    return event
                }

                // keyCode 36 = Return; check only Shift is held
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
