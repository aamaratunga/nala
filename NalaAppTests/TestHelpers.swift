import Foundation
@testable import Nala

/// Shared JSON decoder for tests (Session uses custom CodingKeys, so plain JSONDecoder works)
let nalaJSONDecoder = JSONDecoder()

/// Factory for creating `Session` values with sensible defaults.
/// Only override the fields your test cares about.
func makeSession(
    name: String = "agent-1",
    agentType: String = "claude",
    sessionId: String = "sess-1",
    tmuxSession: String = "tmux-1",
    status: String? = nil,
    summary: String? = nil,
    stalenessSeconds: Double? = nil,
    branch: String? = nil,
    displayName: String? = nil,
    icon: String? = nil,
    workingDirectory: String = "/tmp/project",
    waitingForInput: Bool = false,
    done: Bool = false,
    working: Bool = false,
    stuck: Bool = false,
    sleeping: Bool = false,
    waitingReason: String? = nil,
    waitingSummary: String? = nil,
    latestEventSummary: String? = nil,
    changedFileCount: Int = 0,
    boardProject: String? = nil,
    boardJobTitle: String? = nil,
    boardUnread: Int = 0,
    commands: [SessionCommand] = [],
    logPath: String = "/tmp/log.txt"
) -> Session {
    Session(
        name: name,
        agentType: agentType,
        sessionId: sessionId,
        tmuxSession: tmuxSession,
        status: status,
        summary: summary,
        stalenessSeconds: stalenessSeconds,
        branch: branch,
        displayName: displayName,
        icon: icon,
        workingDirectory: workingDirectory,
        waitingForInput: waitingForInput,
        done: done,
        working: working,
        stuck: stuck,
        sleeping: sleeping,
        waitingReason: waitingReason,
        waitingSummary: waitingSummary,
        latestEventSummary: latestEventSummary,
        changedFileCount: changedFileCount,
        boardProject: boardProject,
        boardJobTitle: boardJobTitle,
        boardUnread: boardUnread,
        commands: commands,
        logPath: logPath
    )
}

// MARK: - Sample JSON

let fullSessionJSON = """
{
    "name": "claude-agent-1",
    "agent_type": "claude",
    "session_id": "abc123",
    "tmux_session": "tmux-claude-1",
    "status": "Implementing feature",
    "summary": "Adding unit tests",
    "staleness_seconds": 42.5,
    "branch": "feature/tests",
    "display_name": "Test Agent",
    "icon": "beaker",
    "working_directory": "/Users/dev/project",
    "waiting_for_input": false,
    "done": false,
    "working": true,
    "stuck": false,
    "waiting_reason": null,
    "waiting_summary": null,
    "changed_file_count": 3,
    "board_project": "myboard",
    "board_job_title": "Backend Dev",
    "board_unread": 2,
    "commands": [
        {"name": "test", "description": "Run tests"}
    ],
    "log_path": "/tmp/claude_test_project.log"
}
"""

let minimalSessionJSON = """
{"name": "bare-agent"}
"""
