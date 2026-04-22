import SwiftUI

struct AgentProvider: Identifiable, Equatable {
    let id: String
    let displayName: String
    let sessionPrefix: String
    let badgeColor: Color
    let executableCandidates: [String]
    let defaultCommands: [SessionCommand]
    let supportsEventTracking: Bool
    let fallbackDisplayLabel: String

    static let claude = AgentProvider(
        id: "claude",
        displayName: "Claude",
        sessionPrefix: "claude",
        badgeColor: NalaTheme.textSecondary,
        executableCandidates: ["claude"],
        defaultCommands: [
            SessionCommand(name: "compact", description: "Compress conversation history"),
            SessionCommand(name: "clear", description: "Clear conversation and start fresh"),
            SessionCommand(name: "review", description: "Review code changes"),
            SessionCommand(name: "cost", description: "Show token usage and cost"),
            SessionCommand(name: "diff", description: "View changes made in session"),
        ],
        supportsEventTracking: true,
        fallbackDisplayLabel: "Agent"
    )

    static let codex = AgentProvider(
        id: "codex",
        displayName: "Codex",
        sessionPrefix: "codex",
        badgeColor: NalaTheme.openaiGreen,
        executableCandidates: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "~/.local/bin/codex",
            "codex",
        ],
        defaultCommands: [],
        supportsEventTracking: true,
        fallbackDisplayLabel: "Agent"
    )

    static let terminal = AgentProvider(
        id: "terminal",
        displayName: "Terminal",
        sessionPrefix: "terminal",
        badgeColor: NalaTheme.teal,
        executableCandidates: [],
        defaultCommands: [],
        supportsEventTracking: false,
        fallbackDisplayLabel: "Terminal"
    )

    static let knownProviders = [claude, codex, terminal]

    static func provider(for id: String) -> AgentProvider {
        let normalized = id.lowercased()
        if let provider = knownProviders.first(where: { $0.id == normalized }) {
            return provider
        }

        return AgentProvider(
            id: id,
            displayName: id.isEmpty ? "Agent" : id.capitalized,
            sessionPrefix: id,
            badgeColor: NalaTheme.textSecondary,
            executableCandidates: [],
            defaultCommands: [],
            supportsEventTracking: false,
            fallbackDisplayLabel: "Agent"
        )
    }
}
