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
    var stalenessSeconds: Double?
    var branch: String?
    var displayName: String?
    var icon: String?
    var workingDirectory: String
    var status: AgentStatus
    var waitingReason: String?
    var waitingSummary: String?
    var latestEventSummary: String?
    var changedFileCount: Int
    var boardProject: String?
    var boardJobTitle: String?
    var boardUnread: Int
    var commands: [SessionCommand]
    var isPlaceholder: Bool = false

    var id: String { sessionId.isEmpty ? name : sessionId }
    var hasTmuxTarget: Bool { !tmuxSession.isEmpty }

    /// Memberwise initializer for programmatic creation (e.g. placeholders, tests).
    init(
        name: String,
        agentType: String = "claude",
        sessionId: String = "",
        tmuxSession: String = "",
        stalenessSeconds: Double? = nil,
        branch: String? = nil,
        displayName: String? = nil,
        icon: String? = nil,
        workingDirectory: String = "",
        status: AgentStatus = .idle,
        waitingReason: String? = nil,
        waitingSummary: String? = nil,
        latestEventSummary: String? = nil,
        changedFileCount: Int = 0,
        boardProject: String? = nil,
        boardJobTitle: String? = nil,
        boardUnread: Int = 0,
        commands: [SessionCommand] = []
    ) {
        self.name = name
        self.agentType = agentType
        self.sessionId = sessionId
        self.tmuxSession = tmuxSession
        self.stalenessSeconds = stalenessSeconds
        self.branch = branch
        self.displayName = displayName
        self.icon = icon
        self.workingDirectory = workingDirectory
        self.status = status
        self.waitingReason = waitingReason
        self.waitingSummary = waitingSummary
        self.latestEventSummary = latestEventSummary
        self.changedFileCount = changedFileCount
        self.boardProject = boardProject
        self.boardJobTitle = boardJobTitle
        self.boardUnread = boardUnread
        self.commands = commands
        self.isPlaceholder = false
    }

    /// The label to show in the sidebar (matches web app fallback chain).
    var displayLabel: String {
        if let dn = displayName, !dn.isEmpty { return dn }
        if let job = boardJobTitle, !job.isEmpty { return job }
        return agentType == "terminal" ? "Terminal" : "Agent"
    }

    /// Activity subtitle shown below the name, with state-aware priority.
    var effectiveSubtitle: String? {
        switch status {
        case .done:
            return "Completed"
        case .stuck:
            if let wr = waitingReason, !wr.isEmpty { return wr }
            return "Stuck"
        case .waitingForInput:
            if let ws = waitingSummary, !ws.isEmpty { return ws }
            return "Waiting for input"
        case .sleeping:
            return "Sleeping"
        case .working, .idle:
            if let event = latestEventSummary, !event.isEmpty { return event }
            return nil
        }
    }

    /// Color for the subtitle text, based on agent state.
    var subtitleColor: Color {
        switch status {
        case .done:             return NalaTheme.green
        case .stuck:            return NalaTheme.red
        case .waitingForInput:  return NalaTheme.amber
        case .sleeping:         return NalaTheme.textTertiary
        case .working, .idle:   return NalaTheme.textSecondary
        }
    }
}

struct SessionCommand: Codable, Equatable {
    let name: String
    let description: String
}

