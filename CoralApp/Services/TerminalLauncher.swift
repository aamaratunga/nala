import AppKit
import os

enum TerminalLauncher {
    private static let logger = Logger(subsystem: "com.coral.app", category: "TerminalLauncher")
    private static let terminalAppKey = "coral.terminalAppPath"

    static var terminalAppPath: String? {
        let path = UserDefaults.standard.string(forKey: terminalAppKey)
        return (path?.isEmpty == false) ? path : nil
    }

    /// Attach to a tmux session in the user's chosen external terminal app.
    static func attachInExternalTerminal(sessionName: String) {
        guard let appPath = terminalAppPath else {
            logger.warning("No terminal app configured")
            return
        }

        let fm = FileManager.default
        let scriptPath = fm.temporaryDirectory
            .appendingPathComponent("coral-attach-\(ProcessInfo.processInfo.processIdentifier)-\(sessionName).sh")
            .path

        // Login shell so Homebrew tmux is on PATH
        let script = """
        #!/bin/zsh -l
        exec tmux attach -t \(shellEscape(sessionName))
        """

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            logger.error("Failed to write attach script: \(error)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appPath, scriptPath]

        do {
            try process.run()
            logger.info("Launched external terminal for session '\(sessionName)'")
        } catch {
            logger.error("Failed to open terminal app: \(error)")
        }

        // Clean up the temp script after a delay
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            try? fm.removeItem(atPath: scriptPath)
        }
    }

    /// Attach in external terminal, or show a prompt to configure one in Settings.
    @MainActor
    static func attachOrPrompt(sessionName: String) {
        if terminalAppPath != nil {
            attachInExternalTerminal(sessionName: sessionName)
        } else {
            let alert = NSAlert()
            alert.messageText = "No Terminal App Configured"
            alert.informativeText = "Choose a terminal app in Settings to use \"Attach in Terminal\"."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
