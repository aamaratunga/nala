import Foundation
import SwiftUI

// MARK: - FolderStatus

enum FolderStatus: String, CaseIterable, Codable, Equatable {
    case done       = "done"
    case inReview   = "in_review"
    case inProgress = "in_progress"
    case backlog    = "backlog"
    case canceled   = "canceled"

    var displayName: String {
        switch self {
        case .done:       return "Done"
        case .inReview:   return "In Review"
        case .inProgress: return "In Progress"
        case .backlog:    return "Backlog"
        case .canceled:   return "Canceled"
        }
    }

    var icon: String {
        switch self {
        case .done:       return "✅"
        case .inReview:   return "👀"
        case .inProgress: return "🔥"
        case .backlog:    return "📋"
        case .canceled:   return "❌"
        }
    }

    var color: Color {
        switch self {
        case .done:       return NalaTheme.green
        case .inReview:   return NalaTheme.magenta
        case .inProgress: return NalaTheme.coralPrimary
        case .backlog:    return NalaTheme.textTertiary
        case .canceled:   return NalaTheme.textTertiary
        }
    }

    /// Display order from top to bottom in the sidebar.
    static var displayOrder: [FolderStatus] { allCases }
}

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
    var sleeping: Bool
    var waitingReason: String?
    var waitingSummary: String?
    var latestEventSummary: String?
    var changedFileCount: Int
    var boardProject: String?
    var boardJobTitle: String?
    var boardUnread: Int
    var commands: [SessionCommand]
    var logPath: String
    var isPlaceholder: Bool = false

    var id: String { sessionId.isEmpty ? name : sessionId }
    var hasTmuxTarget: Bool { !tmuxSession.isEmpty }

    /// Memberwise initializer for programmatic creation (e.g. placeholders, tests).
    init(
        name: String,
        agentType: String = "claude",
        sessionId: String = "",
        tmuxSession: String = "",
        status: String? = nil,
        summary: String? = nil,
        stalenessSeconds: Double? = nil,
        branch: String? = nil,
        displayName: String? = nil,
        icon: String? = nil,
        workingDirectory: String = "",
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
        logPath: String = ""
    ) {
        self.name = name
        self.agentType = agentType
        self.sessionId = sessionId
        self.tmuxSession = tmuxSession
        self.status = status
        self.summary = summary
        self.stalenessSeconds = stalenessSeconds
        self.branch = branch
        self.displayName = displayName
        self.icon = icon
        self.workingDirectory = workingDirectory
        self.waitingForInput = waitingForInput
        self.done = done
        self.working = working
        self.stuck = stuck
        self.sleeping = sleeping
        self.waitingReason = waitingReason
        self.waitingSummary = waitingSummary
        self.latestEventSummary = latestEventSummary
        self.changedFileCount = changedFileCount
        self.boardProject = boardProject
        self.boardJobTitle = boardJobTitle
        self.boardUnread = boardUnread
        self.commands = commands
        self.logPath = logPath
        self.isPlaceholder = false
    }

    /// The label to show in the sidebar (matches web app fallback chain).
    var displayLabel: String {
        if let dn = displayName, !dn.isEmpty { return dn }
        if let s = summary, !s.isEmpty { return s }
        if let job = boardJobTitle, !job.isEmpty { return job }
        return agentType == "terminal" ? "Terminal" : "Agent"
    }

    /// Activity subtitle shown below the name, with state-aware priority.
    var effectiveSubtitle: String? {
        if done { return "Completed" }
        if stuck {
            if let wr = waitingReason, !wr.isEmpty { return wr }
            return "Stuck"
        }
        if waitingForInput {
            if let ws = waitingSummary, !ws.isEmpty { return ws }
            return "Waiting for input"
        }
        if sleeping { return "Sleeping" }
        if let s = status, !s.isEmpty { return s }
        if let event = latestEventSummary, !event.isEmpty { return event }
        return nil
    }

    /// Color for the subtitle text, based on agent state.
    var subtitleColor: Color {
        if done { return NalaTheme.green }
        if stuck { return NalaTheme.red }
        if waitingForInput { return NalaTheme.amber }
        if sleeping { return NalaTheme.textTertiary }
        return NalaTheme.textSecondary
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
        case sleeping
        case waitingReason = "waiting_reason"
        case waitingSummary = "waiting_summary"
        case latestEventSummary = "latest_event_summary"
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
        sleeping = try c.decodeIfPresent(Bool.self, forKey: .sleeping) ?? false
        waitingReason = try c.decodeIfPresent(String.self, forKey: .waitingReason)
        waitingSummary = try c.decodeIfPresent(String.self, forKey: .waitingSummary)
        latestEventSummary = try c.decodeIfPresent(String.self, forKey: .latestEventSummary)
        changedFileCount = try c.decodeIfPresent(Int.self, forKey: .changedFileCount) ?? 0
        boardProject = try c.decodeIfPresent(String.self, forKey: .boardProject)
        boardJobTitle = try c.decodeIfPresent(String.self, forKey: .boardJobTitle)
        boardUnread = try c.decodeIfPresent(Int.self, forKey: .boardUnread) ?? 0
        commands = try c.decodeIfPresent([SessionCommand].self, forKey: .commands) ?? []
        logPath = try c.decodeIfPresent(String.self, forKey: .logPath) ?? ""
        isPlaceholder = false
    }
}
