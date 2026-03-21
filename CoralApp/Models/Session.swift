import Foundation

struct Session: Identifiable, Equatable {
    let name: String
    let agentType: String
    let sessionId: String
    let tmuxSession: String
    var status: String?
    var summary: String?
    var stalenessSeconds: Double?
    var branch: String?
    var displayName: String?
    var icon: String?
    var workingDirectory: String
    var waitingForInput: Bool
    var done: Bool
    var working: Bool
    var stuck: Bool
    var waitingReason: String?
    var waitingSummary: String?
    var changedFileCount: Int
    var boardProject: String?
    var boardJobTitle: String?
    var boardUnread: Int
    var commands: [SessionCommand]
    var logPath: String

    var id: String { sessionId.isEmpty ? name : sessionId }

    /// The label to show in the sidebar (matches web app fallback chain).
    var displayLabel: String {
        if let dn = displayName, !dn.isEmpty { return dn }
        if let job = boardJobTitle, !job.isEmpty { return job }
        return agentType == "terminal" ? "Terminal" : "Agent"
    }
}

struct SessionCommand: Codable, Equatable {
    let name: String
    let description: String
}

// MARK: - JSON Decoding

extension Session: Decodable {
    enum CodingKeys: String, CodingKey {
        case name
        case agentType = "agent_type"
        case sessionId = "session_id"
        case tmuxSession = "tmux_session"
        case status
        case summary
        case stalenessSeconds = "staleness_seconds"
        case branch
        case displayName = "display_name"
        case icon
        case workingDirectory = "working_directory"
        case waitingForInput = "waiting_for_input"
        case done
        case working
        case stuck
        case waitingReason = "waiting_reason"
        case waitingSummary = "waiting_summary"
        case changedFileCount = "changed_file_count"
        case boardProject = "board_project"
        case boardJobTitle = "board_job_title"
        case boardUnread = "board_unread"
        case commands
        case logPath = "log_path"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        agentType = try c.decodeIfPresent(String.self, forKey: .agentType) ?? "claude"
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        tmuxSession = try c.decodeIfPresent(String.self, forKey: .tmuxSession) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        stalenessSeconds = try c.decodeIfPresent(Double.self, forKey: .stalenessSeconds)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        waitingForInput = try c.decodeIfPresent(Bool.self, forKey: .waitingForInput) ?? false
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        working = try c.decodeIfPresent(Bool.self, forKey: .working) ?? false
        stuck = try c.decodeIfPresent(Bool.self, forKey: .stuck) ?? false
        waitingReason = try c.decodeIfPresent(String.self, forKey: .waitingReason)
        waitingSummary = try c.decodeIfPresent(String.self, forKey: .waitingSummary)
        changedFileCount = try c.decodeIfPresent(Int.self, forKey: .changedFileCount) ?? 0
        boardProject = try c.decodeIfPresent(String.self, forKey: .boardProject)
        boardJobTitle = try c.decodeIfPresent(String.self, forKey: .boardJobTitle)
        boardUnread = try c.decodeIfPresent(Int.self, forKey: .boardUnread) ?? 0
        commands = try c.decodeIfPresent([SessionCommand].self, forKey: .commands) ?? []
        logPath = try c.decodeIfPresent(String.self, forKey: .logPath) ?? ""
    }
}
