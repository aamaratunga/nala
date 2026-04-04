import AppKit
import os

enum TerminalLauncher {
    private static let logger = Logger(subsystem: "com.nala.app", category: "TerminalLauncher")
    private static let terminalAppKey = "nala.terminalAppPath"

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

        // Try to use the terminal app's CLI directly so that the new window
        // respects the app's default profile (including window size).
        // Falling back to `open -a <app> <script>` opens the script as a
        // "document" which many apps render in a minimal/non-default window.
        if launchViaCLI(appPath: appPath, sessionName: sessionName) {
            return
        }

        // Fallback: open a temp script as a document
        launchViaOpenScript(appPath: appPath, sessionName: sessionName)
    }

    /// Launch via the terminal app's own CLI (returns true if handled).
    private static func launchViaCLI(appPath: String, sessionName: String) -> Bool {
        let appURL = URL(fileURLWithPath: appPath)
        let appName = appURL.deletingPathExtension().lastPathComponent.lowercased()
        let macosDir = appURL.appendingPathComponent("Contents/MacOS")

        let process = Process()
        let tmuxCmd = "tmux attach -t \(shellEscape(sessionName))"

        switch appName {
        case "wezterm":
            let cli = macosDir.appendingPathComponent("wezterm").path
            guard FileManager.default.isExecutableFile(atPath: cli) else { return false }
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["start", "--", "/bin/zsh", "-l", "-c", tmuxCmd]

        case "kitty":
            let cli = macosDir.appendingPathComponent("kitty").path
            guard FileManager.default.isExecutableFile(atPath: cli) else { return false }
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["/bin/zsh", "-l", "-c", tmuxCmd]

        case "alacritty":
            let cli = macosDir.appendingPathComponent("alacritty").path
            guard FileManager.default.isExecutableFile(atPath: cli) else { return false }
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["-e", "/bin/zsh", "-l", "-c", tmuxCmd]

        default:
            return false
        }

        do {
            try process.run()
            logger.info("Launched \(appName) CLI for session '\(sessionName)'")
            return true
        } catch {
            logger.error("CLI launch failed for \(appName): \(error)")
            return false
        }
    }

    /// Fallback: write a temp script and open it as a document with the terminal app.
    private static func launchViaOpenScript(appPath: String, sessionName: String) {
        let fm = FileManager.default
        let scriptPath = fm.temporaryDirectory
            .appendingPathComponent("nala-attach-\(ProcessInfo.processInfo.processIdentifier)-\(sessionName).sh")
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
