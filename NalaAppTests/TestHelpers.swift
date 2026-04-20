import Foundation
@testable import Nala

/// Factory for creating `Session` values with sensible defaults.
/// Only override the fields your test cares about.
func makeSession(
    name: String = "agent-1",
    agentType: String = "claude",
    sessionId: String = "sess-1",
    tmuxSession: String = "tmux-1",
    stalenessSeconds: Double? = nil,
    branch: String? = nil,
    displayName: String? = nil,
    icon: String? = nil,
    workingDirectory: String = "/tmp/project",
    status: AgentStatus = .idle,
    waitingReason: String? = nil,
    waitingSummary: String? = nil,
    latestEventSummary: String? = nil,
    changedFileCount: Int = 0,
    boardProject: String? = nil,
    boardJobTitle: String? = nil,
    boardUnread: Int = 0,
    commands: [SessionCommand] = []
) -> Session {
    Session(
        name: name,
        agentType: agentType,
        sessionId: sessionId,
        tmuxSession: tmuxSession,
        stalenessSeconds: stalenessSeconds,
        branch: branch,
        displayName: displayName,
        icon: icon,
        workingDirectory: workingDirectory,
        status: status,
        waitingReason: waitingReason,
        waitingSummary: waitingSummary,
        latestEventSummary: latestEventSummary,
        changedFileCount: changedFileCount,
        boardProject: boardProject,
        boardJobTitle: boardJobTitle,
        boardUnread: boardUnread,
        commands: commands
    )
}
