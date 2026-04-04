import Foundation
import os

/// Uses the Claude CLI (`claude --print --model haiku`) to generate short session
/// names from recent tool activity. No API key required — uses the same auth as
/// the user's Claude Code installation.
final class AutoNamer: @unchecked Sendable {
    private let logger = os.Logger(subsystem: "com.nala.app", category: "AutoNamer")

    /// Minimum tool events before triggering auto-naming.
    static let minEventsToTrigger = 5

    /// Cooldown between naming attempts per session (seconds).
    static let cooldownSeconds: TimeInterval = 60

    /// Tracks when each session was last named (or attempted).
    private var lastAttempt: [String: Date] = [:]
    private let lock = NSLock()

    /// Tracks event counts per session for triggering.
    private var eventCounts: [String: Int] = [:]

    /// Resolved path to the claude binary, or nil if not found.
    private let claudePath: String?

    /// Known install locations for `claude` (macOS GUI apps don't inherit shell PATH).
    private static let knownClaudePaths = [
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/claude",
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.claude/local/claude",
    ]

    init() {
        let fm = FileManager.default
        self.claudePath = Self.knownClaudePaths.first(where: { fm.isExecutableFile(atPath: $0) })
    }

    /// Record a tool event for a session. Returns true if auto-naming should be triggered.
    func recordEvent(sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let count = (eventCounts[sessionId] ?? 0) + 1
        eventCounts[sessionId] = count

        // Only trigger at the threshold, then every 20 events after
        guard count == Self.minEventsToTrigger || (count > Self.minEventsToTrigger && count % 20 == 0) else {
            return false
        }

        // Check cooldown
        if let last = lastAttempt[sessionId],
           Date().timeIntervalSince(last) < Self.cooldownSeconds {
            return false
        }

        lastAttempt[sessionId] = Date()
        return true
    }

    /// Reset tracking for a session (e.g., on session removal).
    func reset(sessionId: String) {
        lock.lock()
        lastAttempt.removeValue(forKey: sessionId)
        eventCounts.removeValue(forKey: sessionId)
        lock.unlock()
    }

    /// Generate a session name from the user's initial prompt text.
    /// Returns nil if `claude` CLI is not found, the call fails, or the prompt is too vague.
    func generateNameFromPrompt(_ promptText: String) async -> String? {
        guard let claude = claudePath else {
            logger.info("Claude CLI not found, skipping prompt-based naming")
            return nil
        }

        // Cap input length for Haiku
        let truncated = String(promptText.prefix(500))

        let prompt = """
        You are a naming tool. Read the user's request and output a 2-4 word lowercase name.

        Rules:
        - Output ONLY the name, nothing else
        - 2-4 words, lowercase, no quotes, no markdown, no explanation
        - If the request is too vague to name, output: KEEP

        User request:
        \(truncated)

        Name:
        """

        do {
            let result = try await callClaude(claudePath: claude, prompt: prompt)
            let cleaned = cleanName(result)
            let upper = cleaned.uppercased()
            if upper == "KEEP" || upper.hasPrefix("KEEP ") || upper.hasPrefix("KEEP.") ||
               upper.hasPrefix("KEEP,") || upper.hasPrefix("KEEP-") || upper.hasPrefix("KEEP:") {
                return nil
            }
            let wordCount = cleaned.split(separator: " ").count
            if wordCount > 5 { return nil }
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            logger.warning("Prompt-based naming failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Generate a session name from recent activity summaries.
    /// If `currentName` is provided, only returns a new name if the focus has significantly shifted.
    /// Returns nil if `claude` CLI is not found, the call fails, or the focus hasn't changed enough.
    func generateName(activities: [String], currentName: String? = nil) async -> String? {
        guard let claude = claudePath else {
            logger.info("Claude CLI not found, skipping auto-naming")
            return nil
        }

        let activitiesText = activities.suffix(15).joined(separator: "\n")
        let prompt: String

        if let currentName, !currentName.isEmpty {
            // Re-naming: only change if focus shifted significantly
            prompt = """
            You are a naming tool. The current session name is "\(currentName)".

            Read the activities and decide:
            - If the focus changed, output a new 2-4 word lowercase name
            - If the focus is the same, output: KEEP

            Rules: output ONLY the name or KEEP. Nothing else. No explanation, no quotes, no markdown.

            Activities:
            \(activitiesText)

            Output:
            """
        } else {
            // First naming
            prompt = """
            You are a naming tool. Read the activities and output a 2-4 word lowercase name.

            Rules:
            - Output ONLY the name, nothing else
            - 2-4 words, lowercase, no quotes, no markdown, no explanation
            - If unclear, output: KEEP

            Activities:
            \(activitiesText)

            Name:
            """
        }

        do {
            let result = try await callClaude(claudePath: claude, prompt: prompt)
            let cleaned = cleanName(result)
            // If Haiku says keep, don't change
            let upper = cleaned.uppercased()
            if upper == "KEEP" || upper.hasPrefix("KEEP ") || upper.hasPrefix("KEEP.") ||
               upper.hasPrefix("KEEP,") || upper.hasPrefix("KEEP-") || upper.hasPrefix("KEEP:") {
                return nil
            }
            let wordCount = cleaned.split(separator: " ").count
            if wordCount > 5 { return nil }
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            logger.warning("Auto-naming failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Claude CLI

    private func callClaude(claudePath: String, prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = [
                "--print",
                "--model", "haiku",
                "--no-session-persistence",
                prompt
            ]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""

                if proc.terminationStatus != 0 {
                    let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: AutoNamerError.cliFailed(
                        exitCode: proc.terminationStatus,
                        message: msg.isEmpty ? "Unknown error" : msg
                    ))
                } else {
                    continuation.resume(returning: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Strip quotes, trailing punctuation, and normalize whitespace.
    private func cleanName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown bold/italic markers
        name = name.replacingOccurrences(of: "*", with: "")
        name = name.replacingOccurrences(of: "_", with: "")
        // Remove surrounding quotes
        if (name.hasPrefix("\"") && name.hasSuffix("\"")) ||
           (name.hasPrefix("'") && name.hasSuffix("'")) {
            name = String(name.dropFirst().dropLast())
        }
        // Remove trailing period
        if name.hasSuffix(".") {
            name = String(name.dropLast())
        }
        // Collapse whitespace
        name = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Cap at reasonable length
        if name.count > 40 {
            name = String(name.prefix(40))
        }
        return name
    }
}

enum AutoNamerError: LocalizedError {
    case cliFailed(exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .cliFailed(let code, let msg): return "claude CLI exited \(code): \(msg)"
        }
    }
}
