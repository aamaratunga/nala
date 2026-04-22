import Foundation
import QuartzCore
import os

// MARK: - Data Types

struct TmuxSessionInfo: Equatable {
    let sessionName: String
    let agentType: String
    let sessionId: String
    let workingDirectory: String
    let paneTarget: String
}

struct TmuxUpdate: Equatable {
    let added: [TmuxSessionInfo]
    let removed: [String] // session names
    let current: [TmuxSessionInfo]
}

// MARK: - TmuxService

final class TmuxService: @unchecked Sendable {
    private let logger = os.Logger(subsystem: "com.nala.app", category: "TmuxService")

    typealias ExecutableResolver = @Sendable (AgentProvider) -> String?
    typealias TmuxRunner = @Sendable ([String]) async -> CommandResult
    typealias LaunchFlagsReader = (AgentProvider) -> String

    /// Resolved path to the tmux binary. Checked once at init from known install locations.
    private let tmuxPath: String
    private let executableResolver: ExecutableResolver
    private let tmuxRunner: TmuxRunner?
    private let launchFlagsReader: LaunchFlagsReader

    /// Whether tmux was found at a known install path.
    let tmuxAvailable: Bool

    static let claudeAdditionalLaunchFlagsKey = "nala.claude.additionalLaunchFlags"
    static let codexAdditionalLaunchFlagsKey = "nala.codex.additionalLaunchFlags"

    /// Regex for Nala-managed session names: {agentType}-{uuid}
    static let sessionNamePattern = try! NSRegularExpression(
        pattern: #"^(claude|codex|terminal)-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"#,
        options: .caseInsensitive
    )

    /// Bracket paste mode escape sequences (ESC [ 200 ~ and ESC [ 201 ~)
    static let bracketPasteStart = ["-H", "1b", "-H", "5b", "-H", "32", "-H", "30", "-H", "30", "-H", "7e"]
    static let bracketPasteEnd = ["-H", "1b", "-H", "5b", "-H", "32", "-H", "30", "-H", "31", "-H", "7e"]

    /// Grace period: how many consecutive empty polls before treating as real empty
    private var emptyPollCount = 0
    private static let emptyPollGraceThreshold = 3

    /// Track first poll so we can signal connectivity even with no sessions
    private var isFirstPoll = true

    /// Previous snapshot for diffing
    private var previousSessions: [String: TmuxSessionInfo] = [:]

    /// Known tmux install paths, checked in order.
    /// macOS GUI apps don't inherit the user's shell PATH, so we check common locations directly.
    private static let knownTmuxPaths = [
        Bundle.main.path(forAuxiliaryExecutable: "tmux"),  // Bundled in Contents/MacOS/
        "/opt/homebrew/bin/tmux",    // Homebrew on Apple Silicon
        "/usr/local/bin/tmux",       // Homebrew on Intel / manual installs
        "/usr/bin/tmux",             // unlikely, but check anyway
    ].compactMap { $0 }

    init(
        executableResolver: ExecutableResolver? = nil,
        tmuxRunner: TmuxRunner? = nil,
        launchFlagsReader: LaunchFlagsReader? = nil,
        launchFlagsDefaults: UserDefaults = .standard
    ) {
        self.executableResolver = executableResolver ?? { provider in
            Self.resolveExecutable(for: provider)
        }
        self.tmuxRunner = tmuxRunner
        self.launchFlagsReader = launchFlagsReader ?? { provider in
            guard let key = Self.additionalLaunchFlagsKey(for: provider) else { return "" }
            return launchFlagsDefaults.string(forKey: key) ?? ""
        }

        let fm = FileManager.default
        if let found = Self.knownTmuxPaths.first(where: { fm.isExecutableFile(atPath: $0) }) {
            self.tmuxPath = found
            self.tmuxAvailable = true
        } else {
            self.tmuxPath = "/opt/homebrew/bin/tmux"
            self.tmuxAvailable = false
            os.Logger(subsystem: "com.nala.app", category: "TmuxService")
                .error("tmux not found at any known path: \(Self.knownTmuxPaths)")
        }
    }

    // MARK: - Process Execution

    func runTmux(args: [String]) async -> CommandResult {
        if let tmuxRunner {
            return await tmuxRunner(args)
        }
        return await runProcess(executablePath: tmuxPath, args: args, environment: nil, label: "tmux")
    }

    private func runProcess(
        executablePath: String,
        args: [String],
        environment: [String: String]?,
        label: String
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = args

            if let environment {
                var env = ProcessInfo.processInfo.environment
                for (key, value) in environment { env[key] = value }
                process.environment = env
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Read pipe data incrementally to prevent deadlock when the child
            // process fills the 64KB pipe buffer. Collect data before termination.
            let stdoutBuf = LockedBuffer()
            let stderrBuf = LockedBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stdoutBuf.append(data) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stderrBuf.append(data) }
            }

            process.terminationHandler = { process in
                // Stop reading and drain remaining data
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutBuf.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderrBuf.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

                let stdout = String(data: stdoutBuf.data, encoding: .utf8) ?? ""
                let stderr = String(data: stderrBuf.data, encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                ))
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: CommandResult(
                    exitCode: -1, stdout: "", stderr: error.localizedDescription
                ))
            }
        }
    }

    /// Thread-safe mutable data buffer for incremental pipe reads.
    private final class LockedBuffer: @unchecked Sendable {
        private var _data = Data()
        private let lock = NSLock()

        func append(_ new: Data) {
            guard !new.isEmpty else { return }
            lock.lock()
            _data.append(new)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return _data
        }
    }

    // MARK: - Session Discovery

    /// Parse a tmux session name into agent type and UUID if it matches Nala format.
    static func parseSessionName(_ name: String) -> (agentType: String, uuid: String)? {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = sessionNamePattern.firstMatch(in: name, range: range) else {
            return nil
        }
        let agentType = String(name[Range(match.range(at: 1), in: name)!])
        let uuid = String(name[Range(match.range(at: 2), in: name)!])
        return (agentType, uuid)
    }

    /// Lists all Nala-managed tmux sessions.
    func listSessions() async -> [TmuxSessionInfo] {
        let result = await runTmux(args: [
            "list-panes", "-a",
            "-F", "#{pane_title}|#{session_name}|#S:#I.#P|#{pane_current_path}"
        ])

        guard result.succeeded else { return [] }

        var sessions: [TmuxSessionInfo] = []
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 3)
            guard parts.count == 4 else { continue }

            let sessionName = String(parts[1])
            guard let parsed = Self.parseSessionName(sessionName) else { continue }

            sessions.append(TmuxSessionInfo(
                sessionName: sessionName,
                agentType: parsed.agentType,
                sessionId: parsed.uuid,
                workingDirectory: String(parts[3]),
                paneTarget: String(parts[2])
            ))
        }
        return sessions
    }

    // MARK: - Session Creation

    /// Create a new Nala-managed tmux session and return the session name.
    func createSession(
        agentType: String,
        workingDirectory: String,
        prompt: String? = nil,
        displayName: String? = nil
    ) async throws -> String {
        let provider = AgentProvider.provider(for: agentType)
        let sessionId = UUID().uuidString.lowercased()
        let sessionName = "\(provider.sessionPrefix)-\(sessionId)"

        try preflightLaunch(provider: provider)
        let additionalLaunchArgs = try additionalLaunchArgs(for: provider)

        // Create the tmux session
        let tmuxStart = CACurrentMediaTime()
        let createResult = await runTmux(args: [
            "new-session", "-d", "-s", sessionName, "-x", "220", "-y", "50",
            "-c", workingDirectory
        ])
        let tmuxElapsed = CACurrentMediaTime() - tmuxStart
        logger.info("createSession: tmux new-session took \(String(format: "%.0f", tmuxElapsed * 1000))ms")
        guard createResult.succeeded else {
            throw TmuxError.sessionCreationFailed(createResult.errorMessage)
        }

        // Launch the agent
        let launchCommand = try buildLaunchCommand(
            provider: provider,
            sessionId: sessionId,
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            prompt: prompt,
            additionalArgs: additionalLaunchArgs
        )
        if let launchCommand {
            let sendResult = await runTmux(args: [
                "send-keys", "-t", sessionName, launchCommand, "Enter"
            ])
            if !sendResult.succeeded {
                logger.warning("Failed to send launch command: \(sendResult.errorMessage)")
            }
        }
        // For terminal type, just leave the shell running

        return sessionName
    }

    // MARK: - Session Management

    func killSession(name: String) async {
        let result = await runTmux(args: ["kill-session", "-t", name])
        if !result.succeeded {
            logger.warning("kill-session failed for \(name): \(result.errorMessage)")
        }

        // Remove settings temp file
        if let parsed = Self.parseSessionName(name) {
            let settingsPath = "/tmp/nala_settings_\(parsed.uuid).json"
            try? FileManager.default.removeItem(atPath: settingsPath)
            let promptPath = "/tmp/nala_prompt_\(parsed.uuid).txt"
            try? FileManager.default.removeItem(atPath: promptPath)
        }
    }

    func sendKeys(session: String, keys: [String]) async {
        for key in keys {
            let result = await runTmux(args: ["send-keys", "-t", session, key])
            if !result.succeeded {
                logger.warning("send-keys '\(key)' failed for \(session): \(result.errorMessage)")
                break
            }
            // Small delay between keys for reliable delivery
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
    }

    func sendCommand(session: String, command: String) async {
        if command.contains("\n") {
            // Multi-line: use bracketed paste
            await sendBracketPasted(session: session, text: command)
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            let _ = await runTmux(args: ["send-keys", "-t", session, "Enter"])
        } else {
            // Single-line: send as literal text + Enter
            let _ = await runTmux(args: ["send-keys", "-t", session, "-l", command])
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            let _ = await runTmux(args: ["send-keys", "-t", session, "Enter"])
        }
    }

    func capturePane(session: String, lines: Int = 200) async -> String? {
        let result = await runTmux(args: [
            "capture-pane", "-t", session, "-p", "-S-\(lines)"
        ])
        return result.succeeded ? result.stdout : nil
    }

    // MARK: - Bracketed Paste

    private func sendBracketPasted(session: String, text: String) async {
        // Send bracket paste start
        let _ = await runTmux(args: ["send-keys", "-t", session] + Self.bracketPasteStart)
        // Send literal text
        let _ = await runTmux(args: ["send-keys", "-t", session, "-l", text])
        // Send bracket paste end
        let _ = await runTmux(args: ["send-keys", "-t", session] + Self.bracketPasteEnd)
    }

    // MARK: - Claude Settings Injection

    /// Build merged Claude settings with Nala hooks injected.
    /// The sessionId is used to generate file-based hook commands that write
    /// raw hook JSON to ~/.nala/events/{sessionId}.jsonl for EventFileWatcher.
    static func buildMergedSettings(workingDirectory: String, sessionId: String) -> [String: Any] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        // Read settings hierarchy
        let globalSettings = readSettingsFile(atPath: "\(homeDir)/.claude/settings.json")
        let projectSettings = readSettingsFile(atPath: "\(workingDirectory)/.claude/settings.json")
        let localSettings = readSettingsFile(atPath: "\(workingDirectory)/.claude/settings.local.json")

        // Shallow merge: local > project > global
        var merged: [String: Any] = [:]
        for (key, value) in globalSettings { merged[key] = value }
        for (key, value) in projectSettings { merged[key] = value }
        for (key, value) in localSettings { merged[key] = value }

        // Deep-merge hooks: combine arrays per event key
        var mergedHooks: [String: [[String: Any]]] = [:]
        for source in [globalSettings, projectSettings, localSettings] {
            if let hooks = source["hooks"] as? [String: [[String: Any]]] {
                for (event, groups) in hooks {
                    mergedHooks[event, default: []].append(contentsOf: groups)
                }
            }
        }

        // File-based hook command: appends raw hook JSON from stdin to the
        // session's JSONL event file. EventFileWatcher picks up new lines via
        // kqueue and derives agent state (working/done/waiting).
        // NOTE: Claude Code pipes hook JSON to stdin WITHOUT a trailing newline.
        // Using { cat; echo; } ensures each event ends with \n so the file is
        // valid JSONL (one JSON object per line).
        let eventsDir = EventFileWatcher.eventsDirectory
        let eventFileCmd = "mkdir -p '\(eventsDir)' && { cat; echo; } >> '\(eventsDir)/\(sessionId).jsonl'"

        // Nala hooks to inject
        let nalaHooks: [(String, [String: Any])] = [
            ("PreToolUse", [
                "hooks": [["type": "command", "command": eventFileCmd]]
            ]),
            ("PermissionRequest", [
                "hooks": [["type": "command", "command": eventFileCmd]]
            ]),
            ("PostToolUse", [
                "hooks": [["type": "command", "command": eventFileCmd]]
            ]),
            ("Stop", [
                "hooks": [["type": "command", "command": eventFileCmd]]
            ]),
            ("UserPromptSubmit", [
                "hooks": [["type": "command", "command": eventFileCmd]]
            ]),
            ("SessionStart", [
                "matcher": "clear",
                "hooks": [["type": "command", "command": eventFileCmd]]
            ]),
        ]

        for (event, group) in nalaHooks {
            var eventList = mergedHooks[event] ?? []
            // Check if hook command already exists
            let command = ((group["hooks"] as? [[String: Any]])?.first?["command"] as? String) ?? ""
            let exists = eventList.contains { group in
                guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
                return hooks.contains { $0["command"] as? String == command }
            }
            if !exists {
                eventList.append(group)
            }
            mergedHooks[event] = eventList
        }

        merged["hooks"] = mergedHooks
        return merged
    }

    static func readSettingsFile(atPath path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func additionalLaunchFlagsKey(for provider: AgentProvider) -> String? {
        switch provider.id {
        case AgentProvider.claude.id:
            return claudeAdditionalLaunchFlagsKey
        case AgentProvider.codex.id:
            return codexAdditionalLaunchFlagsKey
        default:
            return nil
        }
    }

    static func parseAdditionalLaunchFlags(_ rawValue: String) throws -> [String] {
        var args: [String] = []
        var current = ""
        var tokenStarted = false
        var quote: Character?
        var isEscaping = false

        for character in rawValue {
            if isEscaping {
                current.append(character)
                tokenStarted = true
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                tokenStarted = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                tokenStarted = true
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                tokenStarted = true
                continue
            }

            if character.isWhitespace {
                if tokenStarted {
                    args.append(current)
                    current = ""
                    tokenStarted = false
                }
                continue
            }

            current.append(character)
            tokenStarted = true
        }

        if isEscaping {
            throw TmuxError.invalidLaunchFlags("Trailing backslash in additional launch flags.")
        }
        if let quote {
            let quoteName = quote == "'" ? "single quote" : "double quote"
            throw TmuxError.invalidLaunchFlags("Unclosed \(quoteName) in additional launch flags.")
        }
        if tokenStarted {
            args.append(current)
        }

        return args
    }

    static func resolveExecutable(for provider: AgentProvider) -> String? {
        let fm = FileManager.default

        for candidate in provider.executableCandidates {
            let expanded = expandTilde(in: candidate)

            if expanded.contains("/") {
                if fm.isExecutableFile(atPath: expanded) {
                    return expanded
                }
                continue
            }

            let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .map(String.init)
            for dir in pathDirs {
                let path = URL(fileURLWithPath: dir).appendingPathComponent(expanded).path
                if fm.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }

        return nil
    }

    private static func expandTilde(in path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        return home + String(path.dropFirst())
    }

    private func preflightLaunch(provider: AgentProvider) throws {
        guard provider.id == AgentProvider.codex.id else { return }
        guard executableResolver(provider) != nil else {
            throw TmuxError.executableNotFound(provider: provider.displayName)
        }
    }

    private func additionalLaunchArgs(for provider: AgentProvider) throws -> [String] {
        guard Self.additionalLaunchFlagsKey(for: provider) != nil else { return [] }
        return try Self.parseAdditionalLaunchFlags(launchFlagsReader(provider))
    }

    private func buildLaunchCommand(
        provider: AgentProvider,
        sessionId: String,
        sessionName: String,
        workingDirectory: String,
        prompt: String?,
        additionalArgs: [String]
    ) throws -> String? {
        switch provider.id {
        case AgentProvider.claude.id:
            let settingsStart = CACurrentMediaTime()
            let command = try buildClaudeLaunchCommand(
                sessionId: sessionId,
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                prompt: prompt,
                additionalArgs: additionalArgs
            )
            let settingsElapsed = CACurrentMediaTime() - settingsStart
            if settingsElapsed > 0.05 {
                logger.warning("createSession: buildClaudeLaunchCommand took \(String(format: "%.1f", settingsElapsed * 1000))ms (settings merge + file write)")
            }
            return command
        case AgentProvider.codex.id:
            return try buildCodexLaunchCommand(
                sessionId: sessionId,
                workingDirectory: workingDirectory,
                prompt: prompt,
                additionalArgs: additionalArgs
            )
        default:
            return nil
        }
    }

    /// Build the Claude launch command with merged settings written to a temp file.
    func buildClaudeLaunchCommand(
        sessionId: String,
        sessionName: String,
        workingDirectory: String,
        prompt: String?,
        additionalArgs: [String] = []
    ) throws -> String {
        let merged = Self.buildMergedSettings(workingDirectory: workingDirectory, sessionId: sessionId)

        // Write merged settings to temp file
        let settingsPath = "/tmp/nala_settings_\(sessionId).json"
        if let data = try? JSONSerialization.data(withJSONObject: merged, options: .prettyPrinted) {
            FileManager.default.createFile(atPath: settingsPath, contents: data, attributes: [
                .posixPermissions: 0o600
            ])
        }

        var parts = ["env", "-u", "CLAUDECODE", "claude", "--session-id", sessionId, "--settings", Self.shellQuote(settingsPath)]
        parts.append(contentsOf: additionalArgs.map(Self.shellQuote))

        // If there's a prompt, write it to a file and pass via cat
        if let prompt, !prompt.isEmpty {
            let promptPath = "/tmp/nala_prompt_\(sessionId).txt"
            FileManager.default.createFile(
                atPath: promptPath,
                contents: prompt.data(using: .utf8),
                attributes: [.posixPermissions: 0o600]
            )
            parts.append("\"$(cat \(Self.shellQuote(promptPath)))\"")
        }

        return parts.joined(separator: " ")
    }

    func buildClaudeLaunchCommand(
        sessionId: String,
        sessionName: String,
        workingDirectory: String,
        prompt: String?,
        additionalLaunchFlags: String
    ) throws -> String {
        let additionalArgs = try Self.parseAdditionalLaunchFlags(additionalLaunchFlags)
        return try buildClaudeLaunchCommand(
            sessionId: sessionId,
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            prompt: prompt,
            additionalArgs: additionalArgs
        )
    }

    func buildCodexLaunchCommand(
        sessionId: String,
        workingDirectory: String,
        prompt: String?,
        additionalArgs: [String] = []
    ) throws -> String {
        guard let executable = executableResolver(AgentProvider.codex) else {
            throw TmuxError.executableNotFound(provider: AgentProvider.codex.displayName)
        }

        var parts = [
            "NALA_SESSION_ID=\(Self.shellQuote(sessionId))",
            Self.shellQuote(executable),
            "-C",
            Self.shellQuote(workingDirectory),
            "--enable",
            "codex_hooks",
        ]
        parts.append(contentsOf: additionalArgs.map(Self.shellQuote))

        if let prompt, !prompt.isEmpty {
            parts.append(Self.shellQuote(prompt))
        }

        return parts.joined(separator: " ")
    }

    func buildCodexLaunchCommand(
        sessionId: String,
        workingDirectory: String,
        prompt: String?,
        additionalLaunchFlags: String
    ) throws -> String {
        let additionalArgs = try Self.parseAdditionalLaunchFlags(additionalLaunchFlags)
        return try buildCodexLaunchCommand(
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            prompt: prompt,
            additionalArgs: additionalArgs
        )
    }

    // MARK: - Polling

    /// Poll tmux for session changes and emit diffs.
    func pollOnce() async -> TmuxUpdate? {
        let currentList = await listSessions()

        // Grace period: if tmux returns empty and we previously had sessions, wait
        if currentList.isEmpty && !previousSessions.isEmpty {
            emptyPollCount += 1
            if emptyPollCount < Self.emptyPollGraceThreshold {
                logger.debug("Empty tmux response (\(self.emptyPollCount)/\(Self.emptyPollGraceThreshold)), grace period")
                return nil
            }
            // Grace period exhausted — treat as real empty
        } else {
            emptyPollCount = 0
        }

        let currentMap = Dictionary(currentList.map { ($0.sessionName, $0) }, uniquingKeysWith: { first, _ in first })
        let previousNames = Set(previousSessions.keys)
        let currentNames = Set(currentMap.keys)

        let addedNames = currentNames.subtracting(previousNames)
        let removedNames = previousNames.subtracting(currentNames)

        let added = addedNames.compactMap { currentMap[$0] }
        let removed = Array(removedNames)

        // Detect any changes in existing sessions (e.g., working directory changed)
        // For simplicity, we only track add/remove for now

        previousSessions = currentMap

        // On the first successful poll, always return an update so SessionStore can set isConnected
        let firstPoll = isFirstPoll
        if isFirstPoll { isFirstPoll = false }

        if added.isEmpty && removed.isEmpty && !firstPoll {
            return nil // No changes
        }

        return TmuxUpdate(added: added, removed: removed, current: currentList)
    }

    private let continuationsLock = NSLock()
    private var continuations: [Int: AsyncStream<TmuxUpdate>.Continuation] = [:]
    private var nextContinuationId = 0

    /// Start a polling loop that yields updates via an AsyncStream.
    func updates(interval: TimeInterval = 1.0) -> AsyncStream<TmuxUpdate> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            continuationsLock.lock()
            let id = nextContinuationId
            nextContinuationId += 1
            continuations[id] = continuation
            continuationsLock.unlock()

            let task = Task { [weak self] in
                while !Task.isCancelled {
                    if let self, let update = await self.pollOnce() {
                        continuation.yield(update)
                    }
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                guard let self else { return }
                self.continuationsLock.lock()
                self.continuations.removeValue(forKey: id)
                self.continuationsLock.unlock()
            }
        }
    }

    /// Stop all active polling streams.
    func stop() {
        continuationsLock.lock()
        let conts = continuations
        continuations.removeAll()
        continuationsLock.unlock()
        for (_, c) in conts {
            c.finish()
        }
    }
}

// MARK: - Errors

enum TmuxError: LocalizedError {
    case sessionCreationFailed(String)
    case executableNotFound(provider: String)
    case invalidLaunchFlags(String)

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let msg): return "Session creation failed: \(msg)"
        case .executableNotFound(let provider):
            return "\(provider) executable not found. Install \(provider) CLI or add it to a standard executable path."
        case .invalidLaunchFlags(let msg):
            return "Invalid additional launch flags: \(msg)"
        }
    }
}
