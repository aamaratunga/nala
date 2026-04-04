import Foundation
import os

/// Uses the Claude CLI (`claude --print --model haiku`) to generate short session
/// names from recent tool activity. No API key required — uses the same auth as
/// the user's Claude Code installation.
final class AutoNamer: @unchecked Sendable {
    private let logger = os.Logger(subsystem: "com.coral.app", category: "AutoNamer")

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
            An AI agent coding session is currently named "\(currentName)".

            Based on the recent activities below, decide: has the agent's focus significantly \
            shifted to a different task? If YES, return a new short name (3-6 words, lowercase). \
            If the focus is roughly the same, return exactly "KEEP".

            Activities:
            \(activitiesText)
            """
        } else {
            // First naming
            prompt = """
            Based on these recent coding activities from an AI agent session, generate a short name \
            (3-6 words) that captures what the agent is working on. Return ONLY the name, nothing else. \
            Use lowercase. Examples: "fix auth token refresh", "add user settings page", "refactor test helpers".

            Activities:
            \(activitiesText)
            """
        }

        do {
            let result = try await callClaude(claudePath: claude, prompt: prompt)
            let cleaned = cleanName(result)
            // If Haiku says keep, don't change
            if cleaned.uppercased() == "KEEP" { return nil }
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
        if name.count > 60 {
            name = String(name.prefix(60))
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
