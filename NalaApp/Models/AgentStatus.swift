import Foundation

// MARK: - AgentStatus

/// Single-enum representation of agent state.
/// Replaces the previous boolean-bag (working, done, waitingForInput, sleeping).
enum AgentStatus: String, Equatable, CaseIterable {
    case idle
    case working
    case waitingForInput
    case sleeping
    case done
}

// MARK: - StateEvent

/// Events that can trigger a state transition.
/// All state sources (EventFileWatcher, TmuxService polling, user actions) feed through these.
enum StateEvent: Equatable {
    case toolUse(tool: String, summary: String, timestamp: Date)
    case preToolUse(tool: String, summary: String, timestamp: Date)
    case promptSubmit(summary: String, timestamp: Date)
    case stop(reason: String, timestamp: Date)
    case permissionRequest(tool: String, summary: String, waitingReason: String?, waitingSummary: String?, timestamp: Date)
    case sessionReset
    case userAcknowledged
    case userCancelled
    case permissionAccepted
    case sleepDetected(summary: String, timestamp: Date)
    case polledState(status: AgentStatus)
}

// MARK: - StateSource

/// Identifies which subsystem originated a state event.
enum StateSource: String, Equatable {
    case eventWatcher
    case tmuxPolling
    case userAction
}

// MARK: - StateTransition

/// The result of running a state event through the reducer.
struct StateTransition: Equatable {
    let from: AgentStatus
    let to: AgentStatus
    let didChange: Bool
    let source: StateSource
    let timestamp: Date
}

// MARK: - StateReducer

/// Pure function that computes the next agent status from the current status and an incoming event.
/// All transition logic lives here. The reducer has no side effects -- it doesn't know about
/// notifications, sessions, or UI.
struct StateReducer {

    /// Compute the next state given the current status and an incoming event.
    static func reduce(current: AgentStatus, event: StateEvent, source: StateSource) -> StateTransition {
        let next: AgentStatus
        let timestamp: Date

        switch event {
        case .toolUse(_, _, let ts):
            timestamp = ts
            // Guard: don't revert waitingForInput from late PostToolUse events.
            // When Claude Code runs parallel tools, hook shell commands write to
            // the JSONL file as separate processes — write order is non-deterministic.
            // A PostToolUse from a previously-completed tool can arrive after a
            // PermissionRequest, which would incorrectly revert the waiting state.
            // waitingForInput exits only via permissionAccepted, promptSubmit, or stop.
            next = current == .waitingForInput ? current : .working

        case .preToolUse(let tool, _, let ts):
            timestamp = ts
            if tool == "AskUserQuestion" {
                next = .waitingForInput
            } else {
                // Same guard as toolUse: a PreToolUse from a concurrent tool can
                // arrive out of order relative to PermissionRequest events.
                next = current == .waitingForInput ? current : .working
            }

        case .promptSubmit(_, let ts):
            timestamp = ts
            next = .working

        case .stop(_, let ts):
            timestamp = ts
            // Only transition to done if the agent was actually running.
            // If the session was already auto-acknowledged back to idle,
            // a late stop event must not re-trigger done.
            switch current {
            case .working, .sleeping, .waitingForInput:
                next = .done
            case .idle, .done:
                next = current
            }

        case .permissionRequest(_, _, _, _, let ts):
            timestamp = ts
            next = .waitingForInput

        case .sessionReset:
            timestamp = Date()
            next = .idle

        case .userAcknowledged:
            timestamp = Date()
            next = current == .done ? .idle : current

        case .userCancelled:
            timestamp = Date()
            next = .idle

        case .permissionAccepted:
            timestamp = Date()
            next = current == .waitingForInput ? .working : current

        case .sleepDetected(_, let ts):
            timestamp = ts
            next = .sleeping

        case .polledState(let polledStatus):
            timestamp = Date()
            next = polledStatus
        }

        return StateTransition(
            from: current,
            to: next,
            didChange: current != next,
            source: source,
            timestamp: timestamp
        )
    }
}

// MARK: - TransitionLog

/// In-memory ring buffer of recent state transitions for debugging.
/// Capped at `capacity` entries; oldest entries are evicted when full.
struct TransitionLog {
    private var entries: [StateTransition] = []
    private let capacity: Int

    init(capacity: Int = 50) {
        self.capacity = capacity
    }

    /// Append a transition to the log, evicting the oldest if at capacity.
    mutating func append(_ transition: StateTransition) {
        if entries.count >= capacity {
            entries.removeFirst()
        }
        entries.append(transition)
    }

    /// All logged transitions, oldest first.
    var recent: [StateTransition] {
        entries
    }

    /// Number of transitions currently in the log.
    var count: Int {
        entries.count
    }
}
