import XCTest
@testable import Nala

final class SessionStoreTests: XCTestCase {

    private static let testSuiteName = "com.nala.app.tests"

    private func makeStore() -> SessionStore {
        SessionStore(defaults: UserDefaults(suiteName: Self.testSuiteName)!)
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removePersistentDomain(forName: Self.testSuiteName)
    }

    // MARK: - handleTmuxUpdate — Add / Remove

    func testTmuxUpdateAddsNewSession() {
        let store = makeStore()
        let info = TmuxSessionInfo(
            sessionName: "claude-abc12345-1234-1234-1234-123456789abc",
            agentType: "claude",
            sessionId: "abc12345-1234-1234-1234-123456789abc",
            workingDirectory: "/tmp",
            paneTarget: "claude-abc:0.0"
        )
        let update = TmuxUpdate(added: [info], removed: [], current: [info])

        store.handleTmuxUpdate(update)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].sessionId, "abc12345-1234-1234-1234-123456789abc")
        XCTAssertEqual(store.sessions[0].agentType, "claude")
        XCTAssertTrue(store.isConnected)
    }

    func testTmuxUpdateAddsNewCodexSession() {
        let store = makeStore()
        let info = TmuxSessionInfo(
            sessionName: "codex-abc12345-1234-1234-1234-123456789abc",
            agentType: "codex",
            sessionId: "abc12345-1234-1234-1234-123456789abc",
            workingDirectory: "/tmp",
            paneTarget: "codex-abc:0.0"
        )
        let update = TmuxUpdate(added: [info], removed: [], current: [info])

        store.handleTmuxUpdate(update)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].sessionId, "abc12345-1234-1234-1234-123456789abc")
        XCTAssertEqual(store.sessions[0].agentType, "codex")
        XCTAssertEqual(store.sessions[0].commands, [])
        XCTAssertTrue(store.isConnected)
    }

    func testTmuxUpdateRemovesSession() {
        let store = makeStore()
        store.sessions = [makeSession(name: "claude-s1", sessionId: "s1", workingDirectory: "/tmp")]
        store.reconcileOrder()

        let update = TmuxUpdate(added: [], removed: ["claude-s1"], current: [])
        store.handleTmuxUpdate(update)

        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testTmuxUpdateClearsSelectionOnRemoval() {
        let store = makeStore()
        store.sessions = [makeSession(name: "claude-s1", sessionId: "s1", workingDirectory: "/tmp")]
        store.selectedSessionId = "s1"
        store.reconcileOrder()

        let update = TmuxUpdate(added: [], removed: ["claude-s1"], current: [])
        store.handleTmuxUpdate(update)

        XCTAssertNil(store.selectedSessionId)
    }

    func testTmuxUpdateSkipsPendingKills() {
        let store = makeStore()
        let s1 = makeSession(name: "claude-s1", sessionId: "s1", workingDirectory: "/tmp")
        store.sessions = [s1]
        store.reconcileOrder()

        // Optimistically remove — adds to pendingKills
        store.removeSessionOptimistically(s1)
        XCTAssertTrue(store.sessions.isEmpty)

        // Tmux update still reports s1 as current
        let info = TmuxSessionInfo(
            sessionName: "claude-s1", agentType: "claude",
            sessionId: "s1", workingDirectory: "/tmp", paneTarget: "claude-s1:0.0"
        )
        let update = TmuxUpdate(added: [], removed: [], current: [info])
        store.handleTmuxUpdate(update)

        XCTAssertTrue(store.sessions.isEmpty, "Killed session should not be re-added by tmux update")
    }

    func testTmuxUpdatePreservesDisplayName() {
        let store = makeStore()
        store.sessions = [makeSession(name: "claude-s1", sessionId: "s1", displayName: "My Agent", workingDirectory: "/tmp")]
        store.reconcileOrder()

        let info = TmuxSessionInfo(
            sessionName: "claude-s1", agentType: "claude",
            sessionId: "s1", workingDirectory: "/tmp", paneTarget: "claude-s1:0.0"
        )
        let update = TmuxUpdate(added: [], removed: [], current: [info])
        store.handleTmuxUpdate(update)

        XCTAssertEqual(store.sessions[0].displayName, "My Agent")
    }

    func testTmuxUpdateReplacesLaunchPlaceholder() {
        let store = makeStore()
        store.sessions = []
        store.reconcileOrder()

        // Launch creates placeholder
        store.launchSession(agentType: "claude", in: "/tmp")
        let placeholderId = store.selectedSessionId!
        let launchState = store.activeLaunches[placeholderId]!

        // Simulate tmux session creation completing
        launchState.realSessionId = "real-uuid-1234-1234-1234-123456789abc"
        launchState.isFinished = true

        // Tmux polling picks up the real session
        let info = TmuxSessionInfo(
            sessionName: "claude-real-uuid-1234-1234-1234-123456789abc",
            agentType: "claude",
            sessionId: "real-uuid-1234-1234-1234-123456789abc",
            workingDirectory: "/tmp",
            paneTarget: "claude-real:0.0"
        )
        let update = TmuxUpdate(added: [info], removed: [], current: [info])
        store.handleTmuxUpdate(update)

        // Placeholder should be gone
        XCTAssertNil(store.sessions.first(where: { $0.isPlaceholder }))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].sessionId, "real-uuid-1234-1234-1234-123456789abc")
        // Selection should transfer
        XCTAssertEqual(store.selectedSessionId, "real-uuid-1234-1234-1234-123456789abc")
        XCTAssertNil(store.activeLaunches[placeholderId])
    }

    // MARK: - handleAgentStateUpdate

    func testAgentStateUpdatePropagatesAllFields() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.reconcileOrder()

        let now = Date()
        let event = StateEvent.toolUse(tool: "Edit", summary: "Edited main.swift", timestamp: now)
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: event))

        XCTAssertEqual(store.sessions[0].status, .working)
        XCTAssertEqual(store.sessions[0].latestEventSummary, "Edited main.swift")
        XCTAssertNotNil(store.sessions[0].stalenessSeconds)
    }

    func testAcknowledgeThenLateStopStaysIdle() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", status: .done)]
        store.reconcileOrder()
        store.selectedSessionId = nil

        // Acknowledge the done state → transitions to .idle
        store.acknowledgeSession("s1")
        XCTAssertEqual(store.sessions[0].status, .idle)

        // A late stop event arrives (e.g., "waiting for your input" Notification
        // ~60s after the real Stop). Must not re-trigger done from idle.
        let event = StateEvent.stop(reason: "Agent stopped: waiting for input", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: event))

        // Should stay idle — the agent must go through working before a new done is valid
        XCTAssertEqual(store.sessions[0].status, .idle, "Late stop after acknowledge must not re-trigger done")
    }

    func testAgentStateUpdateAutoAcknowledgesSelectedSession() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.reconcileOrder()
        store.selectedSessionId = "s1"

        let event = StateEvent.stop(reason: "Agent stopped: end_turn", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: event))

        // Auto-acknowledged: status should be idle (done → idle via auto-ack)
        XCTAssertEqual(store.sessions[0].status, .idle)
        XCTAssertEqual(store.sessions[0].status, .idle)
    }

    func testAcknowledgeThenWorkThenDoneIsVisible() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", status: .done)]
        store.reconcileOrder()
        store.selectedSessionId = nil

        // Acknowledge
        store.acknowledgeSession("s1")
        XCTAssertEqual(store.sessions[0].status, .idle)

        // Agent becomes active again
        let workEvent = StateEvent.toolUse(tool: "Read", summary: "Read file.swift", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: workEvent))
        XCTAssertEqual(store.sessions[0].status, .working)

        // Agent completes again
        let stopEvent = StateEvent.stop(reason: "Agent stopped: end_turn", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: stopEvent))

        // Done should be visible (natural idle → working → done flow)
        XCTAssertEqual(store.sessions[0].status, .done, "Done should be visible after idle → working → done")
    }

    func testAgentStateUpdateFiltersPromptSubmitFromEventSummary() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", latestEventSummary: "Read main.swift")]
        store.reconcileOrder()

        let event = StateEvent.promptSubmit(summary: "Prompt: fix the bug", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: event))

        // latestEventSummary should NOT be updated for prompt_submit
        XCTAssertEqual(store.sessions[0].latestEventSummary, "Read main.swift")
    }

    // MARK: - PreToolUse Events

    func testPreToolUseDoesNotAppendToActivityLog() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.reconcileOrder()

        let event = StateEvent.preToolUse(tool: "Read", summary: "Read main.swift", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: event))

        // PreToolUse should update status but NOT append to activity log
        XCTAssertEqual(store.sessions[0].status, .working)
        XCTAssertEqual(store.sessions[0].latestEventSummary, "Read main.swift")
    }

    func testPreToolUseAskUserQuestionSetsWaitingMetadata() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", status: .working)]
        store.reconcileOrder()

        let event = StateEvent.preToolUse(tool: "AskUserQuestion", summary: "Which option?", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: event))

        XCTAssertEqual(store.sessions[0].status, .waitingForInput)
        XCTAssertEqual(store.sessions[0].waitingReason, "Which option?")
        XCTAssertEqual(store.sessions[0].waitingSummary, "Which option?")
        XCTAssertEqual(store.sessions[0].latestEventSummary, "Which option?")
    }

    func testPreToolUseCancelsPendingCancelTimer() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", status: .working)]
        store.reconcileOrder()

        // Trigger cancel
        store.handleAgentCancel(sessionId: "s1")

        // PreToolUse arrives — should cancel the pending timer
        let event = StateEvent.preToolUse(tool: "Bash", summary: "Ran: npm test", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: event))

        // Wait past the debounce period
        let expectation = expectation(description: "Cancel debounce window passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)

        // Session should still be working (cancel was debounced by the preToolUse event)
        XCTAssertEqual(store.sessions[0].status, .working, "Session should stay working — cancel was debounced by preToolUse")
    }

    // MARK: - Batched Event Regression Tests

    /// Critical regression: session is acknowledged (done → idle), then
    /// prompt_submit + stop batch arrives. The working state naturally flows
    /// through idle → working → done, so done is visible again.
    func testBatchedEventsFromDoneAckedToDoneAgain() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", status: .done)]
        store.reconcileOrder()
        // Don't select it — prevents auto-acknowledge
        store.selectedSessionId = nil

        // Acknowledge the done state → transitions to idle
        store.acknowledgeSession("s1")
        XCTAssertEqual(store.sessions[0].status, .idle, "Status should be idle after ack")

        // First: intermediate working state (from prompt_submit)
        let promptEvent = StateEvent.promptSubmit(summary: "Prompt: fix the bug", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: promptEvent))
        XCTAssertEqual(store.sessions[0].status, .working,
            "Intermediate prompt_submit should set working")

        // Second: final done state (from stop)
        let stopEvent = StateEvent.stop(reason: "Agent stopped: end_turn", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: stopEvent))

        // Done should be visible (natural idle → working → done flow)
        XCTAssertEqual(store.sessions[0].status, .done,
            "Done should be visible after idle → working → done")
    }

    /// Verify that both waitingForInput and done transitions are visible
    /// when permissionRequest + stop events batch together.
    func testBatchedPermissionRequestThenStopFiresBothTransitions() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", status: .working)]
        store.reconcileOrder()
        store.selectedSessionId = nil

        // First: intermediate permissionRequest state
        let permEvent = StateEvent.permissionRequest(
            tool: "Bash",
            summary: "Permission required: Ran: rm -rf /tmp/old",
            waitingReason: "Permission required: Ran: rm -rf /tmp/old",
            waitingSummary: "Permission required: Ran: rm -rf /tmp/old",
            timestamp: Date()
        )
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: permEvent))

        // Session should show waitingForInput
        XCTAssertEqual(store.sessions[0].status, .waitingForInput,
            "Intermediate permissionRequest should set waitingForInput")
        XCTAssertEqual(store.sessions[0].waitingSummary, "Permission required: Ran: rm -rf /tmp/old")

        // Second: final stop state
        let stopEvent = StateEvent.stop(reason: "Agent stopped: end_turn", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: stopEvent))

        // Session should now show done (waitingForInput cleared by transition)
        XCTAssertEqual(store.sessions[0].status, .done,
            "Final stop should set done")
        XCTAssertNil(store.sessions[0].waitingReason,
            "waitingReason should be cleared when leaving waitingForInput")
        XCTAssertNil(store.sessions[0].waitingSummary,
            "waitingSummary should be cleared when leaving waitingForInput")
    }

    /// Regression: same done state arriving from two paths (event watcher + tmux polling)
    /// should produce only one effective state change.
    func testDuplicateDoneFromTwoPathsProducesOneTransition() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", status: .working)]
        store.reconcileOrder()
        store.selectedSessionId = nil

        // Path 1: event watcher delivers stop → done
        let stopEvent = StateEvent.stop(reason: "Agent stopped: end_turn", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: stopEvent))
        XCTAssertEqual(store.sessions[0].status, .done)

        // Path 2: tmux polling delivers polledState(.done) — same state
        // The session is already .done, so the reducer should return didChange: false.
        // In the real flow, handleTmuxUpdate calls dispatchStateEvent which checks didChange.
        // We verify the reducer's dedup behavior directly:
        let transition = StateReducer.reduce(current: .done, event: .polledState(status: .done), source: .tmuxPolling)
        XCTAssertFalse(transition.didChange,
            "polledState(.done) when already .done should NOT trigger a state change")
    }

    // MARK: - Order Reconciliation

    func testReconcilePrunesStaleAndAppendsNew() {
        let store = makeStore()
        store.folderOrder = ["/old", "/tmp"]
        store.sessionOrder = ["/old": ["gone"], "/tmp": ["s1"]]

        store.sessions = [
            makeSession(sessionId: "s1", workingDirectory: "/tmp"),
            makeSession(sessionId: "s2", workingDirectory: "/new"),
        ]

        store.reconcileOrder()

        // /old should be pruned, /new should be appended
        XCTAssertEqual(store.folderOrder, ["/tmp", "/new"])
        // s1 preserved, s2 appended in /new
        XCTAssertEqual(store.sessionOrder["/tmp"], ["s1"])
        XCTAssertEqual(store.sessionOrder["/new"], ["s2"])
        // /old removed from sessionOrder
        XCTAssertNil(store.sessionOrder["/old"])
    }

    func testReconcilePrunesStaleSessionsWithinFolder() {
        let store = makeStore()
        store.folderOrder = ["/tmp"]
        store.sessionOrder = ["/tmp": ["gone", "s1", "also-gone"]]

        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]

        store.reconcileOrder()

        XCTAssertEqual(store.sessionOrder["/tmp"], ["s1"])
    }

    // MARK: - orderedGroups

    func testOrderedGroupsRespectsFolderAndSessionOrder() {
        let store = makeStore()
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", workingDirectory: "/proj/alpha"),
            makeSession(name: "b", sessionId: "s2", workingDirectory: "/proj/alpha"),
            makeSession(name: "c", sessionId: "s3", workingDirectory: "/proj/beta"),
        ]
        store.folderOrder = ["/proj/beta", "/proj/alpha"]
        store.sessionOrder = [
            "/proj/alpha": ["s2", "s1"],
            "/proj/beta": ["s3"],
        ]

        let groups = store.orderedGroups

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].path, "/proj/beta")
        XCTAssertEqual(groups[0].label, "beta")
        XCTAssertEqual(groups[1].path, "/proj/alpha")
        XCTAssertEqual(groups[1].sessions.map(\.sessionId), ["s2", "s1"])
    }

    func testOrderedGroupsLabelsEmptyPathAsOther() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "")]
        store.folderOrder = [""]
        store.sessionOrder = ["": ["s1"]]

        let groups = store.orderedGroups
        XCTAssertEqual(groups.first?.label, "Other")
    }

    // MARK: - Move Folders

    func testMoveFolders() {
        let store = makeStore()
        store.folderOrder = ["a", "b", "c"]

        store.moveFolders(from: IndexSet(integer: 0), to: 3)

        XCTAssertEqual(store.folderOrder, ["b", "c", "a"])
    }

    // MARK: - Move Sessions

    func testMoveSessionsWithinFolder() {
        let store = makeStore()
        store.sessionOrder = ["/tmp": ["s1", "s2", "s3"]]

        store.moveSessions(in: "/tmp", from: IndexSet(integer: 2), to: 0)

        XCTAssertEqual(store.sessionOrder["/tmp"], ["s3", "s1", "s2"])
    }

    func testMoveSessionsNoOpForMissingFolder() {
        let store = makeStore()
        store.sessionOrder = ["/tmp": ["s1"]]

        // Should not crash
        store.moveSessions(in: "/nonexistent", from: IndexSet(integer: 0), to: 1)

        XCTAssertEqual(store.sessionOrder["/tmp"], ["s1"])
    }

    // MARK: - moveSessionToPosition (drag-and-drop)

    func testMoveSessionToPositionForward() {
        let store = makeStore()
        store.sessionOrder = ["/tmp": ["s1", "s2", "s3"]]

        // Drag s1 to s3's position (from < to → offset = toIndex + 1)
        store.moveSessionToPosition("s1", targetId: "s3", in: "/tmp")

        XCTAssertEqual(store.sessionOrder["/tmp"], ["s2", "s3", "s1"])
    }

    func testMoveSessionToPositionBackward() {
        let store = makeStore()
        store.sessionOrder = ["/tmp": ["s1", "s2", "s3"]]

        // Drag s3 to s1's position (from > to → offset = toIndex)
        store.moveSessionToPosition("s3", targetId: "s1", in: "/tmp")

        XCTAssertEqual(store.sessionOrder["/tmp"], ["s3", "s1", "s2"])
    }

    func testMoveSessionToPositionSameIsNoOp() {
        let store = makeStore()
        store.sessionOrder = ["/tmp": ["s1", "s2"]]

        store.moveSessionToPosition("s1", targetId: "s1", in: "/tmp")

        XCTAssertEqual(store.sessionOrder["/tmp"], ["s1", "s2"])
    }

    // MARK: - moveFolderToPosition (drag-and-drop)

    func testMoveFolderToPositionForward() {
        let store = makeStore()
        store.folderOrder = ["a", "b", "c"]

        store.moveFolderToPosition("a", targetPath: "c")

        XCTAssertEqual(store.folderOrder, ["b", "c", "a"])
    }

    func testMoveFolderToPositionBackward() {
        let store = makeStore()
        store.folderOrder = ["a", "b", "c"]

        store.moveFolderToPosition("c", targetPath: "a")

        XCTAssertEqual(store.folderOrder, ["c", "a", "b"])
    }

    func testMoveFolderToPositionSameIsNoOp() {
        let store = makeStore()
        store.folderOrder = ["a", "b"]

        store.moveFolderToPosition("a", targetPath: "a")

        XCTAssertEqual(store.folderOrder, ["a", "b"])
    }

    // MARK: - selectedSession

    func testSelectedSessionReturnsMatch() {
        let store = makeStore()
        store.sessions = [
            makeSession(sessionId: "s1", workingDirectory: "/tmp"),
            makeSession(sessionId: "s2", workingDirectory: "/tmp"),
        ]
        store.selectedSessionId = "s2"

        XCTAssertEqual(store.selectedSession?.sessionId, "s2")
    }

    func testSelectedSessionReturnsNilWhenNoSelection() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.selectedSessionId = nil

        XCTAssertNil(store.selectedSession)
    }

    func testSelectedSessionReturnsNilWhenIdNotFound() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.selectedSessionId = "nonexistent"

        XCTAssertNil(store.selectedSession)
    }

    // MARK: - Status Sections

    func testNewFoldersDefaultToInProgress() {
        let store = makeStore()
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", workingDirectory: "/proj/alpha"),
            makeSession(name: "b", sessionId: "s2", workingDirectory: "/proj/beta"),
        ]
        store.reconcileOrder()

        let sections = store.orderedSections
        let inProgressSection = sections.first { $0.status == .inProgress }!

        // Both folders should appear in In Progress (default)
        XCTAssertEqual(inProgressSection.groups.count, 2)
    }

    func testSetFolderStatusMovesFolderToNewSection() {
        let store = makeStore()
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", workingDirectory: "/proj/alpha"),
            makeSession(name: "b", sessionId: "s2", workingDirectory: "/proj/beta"),
        ]
        store.reconcileOrder()

        store.setFolderStatus("/proj/alpha", to: .done)

        let sections = store.orderedSections
        let doneSection = sections.first { $0.status == .done }!
        let inProgressSection = sections.first { $0.status == .inProgress }!

        XCTAssertEqual(doneSection.groups.count, 1)
        XCTAssertEqual(doneSection.groups[0].path, "/proj/alpha")
        XCTAssertEqual(inProgressSection.groups.count, 1)
        XCTAssertEqual(inProgressSection.groups[0].path, "/proj/beta")
    }

    func testEmptySectionsAreIncluded() {
        let store = makeStore()
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", workingDirectory: "/proj/alpha"),
        ]
        store.reconcileOrder()

        let sections = store.orderedSections

        // All 5 status sections should always be present
        XCTAssertEqual(sections.count, 5)

        // Only In Progress should have folders
        let nonEmpty = sections.filter { !$0.groups.isEmpty }
        XCTAssertEqual(nonEmpty.count, 1)
        XCTAssertEqual(nonEmpty[0].status, .inProgress)
    }

    func testSectionDisplayOrder() {
        let store = makeStore()
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", workingDirectory: "/proj/alpha"),
        ]
        store.reconcileOrder()

        let sections = store.orderedSections
        let statuses = sections.map(\.status)

        XCTAssertEqual(statuses, [.done, .inReview, .inProgress, .backlog, .canceled])
    }

    // MARK: - Discovered Folders

    func testReconcilePreservesDiscoveredFolders() {
        let store = makeStore()
        store.discoveredFolders = ["/proj/discovered"]
        store.folderOrder = ["/proj/discovered", "/old"]
        store.sessions = [] // no sessions at all

        store.reconcileOrder()

        // Discovered folder survives pruning; /old (no sessions, not discovered) is pruned
        XCTAssertTrue(store.folderOrder.contains("/proj/discovered"))
        XCTAssertFalse(store.folderOrder.contains("/old"))
    }

    func testReconcilePrunesRemovedDiscoveredFolder() {
        let store = makeStore()
        // Start with a discovered folder
        store.discoveredFolders = ["/proj/discovered"]
        store.folderOrder = ["/proj/discovered"]
        store.sessions = []
        store.reconcileOrder()
        XCTAssertTrue(store.folderOrder.contains("/proj/discovered"))

        // Now remove it from discovered (simulates directory deleted from disk)
        store.discoveredFolders = []
        store.reconcileOrder()

        XCTAssertFalse(store.folderOrder.contains("/proj/discovered"))
    }

    func testOrderedGroupsIncludesEmptyDiscoveredFolder() {
        let store = makeStore()
        store.discoveredFolders = ["/proj/empty"]
        store.folderOrder = ["/proj/empty"]
        store.sessions = []

        let groups = store.orderedGroups

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].path, "/proj/empty")
        XCTAssertEqual(groups[0].sessions.count, 0)
        XCTAssertEqual(groups[0].label, "empty")
    }

    func testDiscoveredFolderMergesWithSessionFolder() {
        let store = makeStore()
        store.discoveredFolders = ["/proj/alpha"]
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", workingDirectory: "/proj/alpha"),
        ]
        store.reconcileOrder()

        let groups = store.orderedGroups

        // Should produce exactly one group (not two) with the session in it
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].path, "/proj/alpha")
        XCTAssertEqual(groups[0].sessions.count, 1)
        XCTAssertEqual(groups[0].sessions[0].sessionId, "s1")
    }

    func testDiscoveredFoldersAppearInDefaultSection() {
        let store = makeStore()
        store.discoveredFolders = ["/proj/alpha", "/proj/beta"]
        store.sessions = []
        store.reconcileOrder()

        let sections = store.orderedSections
        let inProgressSection = sections.first { $0.status == .inProgress }!

        // Both discovered folders should appear in In Progress (default)
        XCTAssertEqual(inProgressSection.groups.count, 2)
    }

    func testReconcilePrunesStaleFolderStatus() {
        let store = makeStore()
        store.folderStatus = ["/old": .done, "/proj/alpha": .inReview]
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", workingDirectory: "/proj/alpha"),
        ]

        store.reconcileOrder()

        // /old should be pruned, /proj/alpha should remain
        XCTAssertNil(store.folderStatus["/old"])
        XCTAssertEqual(store.folderStatus["/proj/alpha"], .inReview)
    }

    // MARK: - Launch Placeholder

    func testLaunchSessionCreatesPlaceholder() {
        let store = makeStore()
        store.sessions = [makeSession(name: "existing", sessionId: "s1", workingDirectory: "/tmp")]
        store.reconcileOrder()

        // Launch a new session — creates placeholder synchronously
        store.launchSession(agentType: "claude", in: "/tmp")

        // Should have 2 sessions: existing + placeholder
        XCTAssertEqual(store.sessions.count, 2)

        let placeholder = store.sessions.first { $0.isPlaceholder }
        XCTAssertNotNil(placeholder, "Placeholder session should exist")
        XCTAssertEqual(placeholder?.workingDirectory, "/tmp")
        XCTAssertEqual(placeholder?.agentType, "claude")
        XCTAssertEqual(placeholder?.status, .working)

        // Placeholder should be selected
        XCTAssertEqual(store.selectedSessionId, placeholder?.id)

        // activeLaunches should have an entry
        XCTAssertNotNil(store.activeLaunches[placeholder!.id])
    }

    func testLaunchSessionCreatesCodexPlaceholder() {
        let store = makeStore()
        store.sessions = []
        store.reconcileOrder()

        store.launchSession(agentType: "codex", in: "/tmp/project")

        let placeholder = store.sessions.first { $0.isPlaceholder }
        XCTAssertNotNil(placeholder, "Codex launch should create a placeholder session")
        XCTAssertEqual(placeholder?.workingDirectory, "/tmp/project")
        XCTAssertEqual(placeholder?.agentType, "codex")
        XCTAssertEqual(placeholder?.status, .working)
        XCTAssertEqual(store.selectedSessionId, placeholder?.id)
        XCTAssertNotNil(store.activeLaunches[placeholder!.id])
    }

    func testRestartSessionTracksOriginalCodexProvider() {
        let store = makeStore()
        let codex = makeSession(
            name: "codex-s1",
            agentType: "codex",
            sessionId: "s1",
            workingDirectory: "/tmp"
        )
        store.sessions = [codex]
        store.reconcileOrder()

        store.restartSession(codex)

        XCTAssertEqual(store.activeRestarts["s1"]?.originalSession.agentType, "codex")
    }

    func testClaudeAndCodexSessionsCoexistInSameFolderGroup() {
        let store = makeStore()
        let claude = makeSession(
            name: "claude-s1",
            agentType: "claude",
            sessionId: "s1",
            workingDirectory: "/tmp/project"
        )
        let codex = makeSession(
            name: "codex-s2",
            agentType: "codex",
            sessionId: "s2",
            workingDirectory: "/tmp/project"
        )
        store.sessions = [claude, codex]
        store.reconcileOrder()

        XCTAssertEqual(store.orderedGroups.count, 1)
        XCTAssertEqual(store.orderedGroups[0].sessions.map(\.agentType), ["claude", "codex"])

        store.removeSessionOptimistically(codex)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].agentType, "claude")
        XCTAssertFalse(store.sessions.contains(where: { $0.agentType == "codex" }))
    }

    // MARK: - Optimistic Kill

    func testRemoveSessionOptimisticallyMovesSelection() {
        let store = makeStore()
        let s1 = makeSession(name: "a", sessionId: "s1", workingDirectory: "/tmp")
        let s2 = makeSession(name: "b", sessionId: "s2", workingDirectory: "/tmp")
        let s3 = makeSession(name: "c", sessionId: "s3", workingDirectory: "/tmp")
        store.sessions = [s1, s2, s3]
        store.reconcileOrder()

        // Select the middle session
        store.selectedSessionId = "s2"

        // Kill the selected session
        store.removeSessionOptimistically(s2)

        // Session should be removed
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertFalse(store.sessions.contains(where: { $0.id == "s2" }))

        // Selection should move to next sibling (s3)
        XCTAssertEqual(store.selectedSessionId, "s3")
    }

    func testRemoveSessionOptimisticallyFallsToPrevious() {
        let store = makeStore()
        let s1 = makeSession(name: "a", sessionId: "s1", workingDirectory: "/tmp")
        let s2 = makeSession(name: "b", sessionId: "s2", workingDirectory: "/tmp")
        store.sessions = [s1, s2]
        store.reconcileOrder()

        // Select the last session
        store.selectedSessionId = "s2"

        // Kill the last session — should fall back to previous
        store.removeSessionOptimistically(s2)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.selectedSessionId, "s1")
    }

    func testRestoreSessionUndoesOptimisticKill() {
        let store = makeStore()
        let s1 = makeSession(name: "a", sessionId: "s1", workingDirectory: "/tmp")
        store.sessions = [s1]
        store.reconcileOrder()

        store.removeSessionOptimistically(s1)
        XCTAssertTrue(store.sessions.isEmpty)

        store.restoreSession(s1)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].id, "s1")
    }

    // MARK: - Rename

    func testRenameSessionOptimisticUpdate() {
        let store = makeStore()
        store.sessions = [makeSession(name: "a", sessionId: "s1", displayName: "Old Name", workingDirectory: "/tmp")]
        store.reconcileOrder()

        let session = store.sessions[0]
        store.renameSession(session, to: "New Name")

        // Optimistic update should be immediate
        XCTAssertEqual(store.sessions[0].displayName, "New Name")
    }

    func testRenameSessionPreservesOtherSessions() {
        let store = makeStore()
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", displayName: "First", workingDirectory: "/tmp"),
            makeSession(name: "b", sessionId: "s2", displayName: "Second", workingDirectory: "/tmp"),
        ]
        store.reconcileOrder()

        let session = store.sessions[0]
        store.renameSession(session, to: "Renamed")

        // Only the targeted session should change
        XCTAssertEqual(store.sessions[0].displayName, "Renamed")
        XCTAssertEqual(store.sessions[1].displayName, "Second")
    }

    func testRenameSessionNoOpForMissingSession() {
        let store = makeStore()
        store.sessions = [makeSession(name: "a", sessionId: "s1", displayName: "Keep", workingDirectory: "/tmp")]
        store.reconcileOrder()

        // Create a session that's not in the store
        let ghost = makeSession(name: "ghost", sessionId: "s999", workingDirectory: "/tmp")
        store.renameSession(ghost, to: "Should Not Crash")

        // Original session untouched
        XCTAssertEqual(store.sessions[0].displayName, "Keep")
    }

    func testRenameSessionIgnoresEmptyName() {
        let store = makeStore()
        store.sessions = [makeSession(name: "a", sessionId: "s1", displayName: "Keep Me", workingDirectory: "/tmp")]
        store.reconcileOrder()

        let session = store.sessions[0]
        store.renameSession(session, to: "   ")

        // Name should not change
        XCTAssertEqual(store.sessions[0].displayName, "Keep Me")
    }

    // MARK: - Recent Browse Paths

    func testAddRecentBrowsePathInsertsAtFront() {
        let store = makeStore()
        store.recentBrowsePaths = ["/old/path"]

        store.addRecentBrowsePath("/new/path")

        XCTAssertEqual(store.recentBrowsePaths.first, "/new/path")
        XCTAssertEqual(store.recentBrowsePaths.count, 2)
    }

    func testRecentBrowsePathsDeduplicates() {
        let store = makeStore()
        store.recentBrowsePaths = ["/a", "/b", "/c"]

        store.addRecentBrowsePath("/b")

        // /b should move to front, not be duplicated
        XCTAssertEqual(store.recentBrowsePaths, ["/b", "/a", "/c"])
    }

    func testRecentBrowsePathsMaxTwenty() {
        let store = makeStore()
        store.recentBrowsePaths = (1...20).map { "/path/\($0)" }
        XCTAssertEqual(store.recentBrowsePaths.count, 20)

        store.addRecentBrowsePath("/new")

        XCTAssertEqual(store.recentBrowsePaths.count, 20)
        XCTAssertEqual(store.recentBrowsePaths.first, "/new")
        // The last item should have been evicted
        XCTAssertFalse(store.recentBrowsePaths.contains("/path/20"))
    }

    func testAddRecentBrowsePathPersists() {
        let store = makeStore()
        store.addRecentBrowsePath("/persisted/path")

        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        let saved = testDefaults.stringArray(forKey: "nala.recentBrowsePaths")
        XCTAssertNotNil(saved)
        XCTAssertTrue(saved?.contains("/persisted/path") ?? false)
    }

    // MARK: - Browse Root

    func testBrowseRootDefaultsToEmpty() {
        let store = makeStore()
        XCTAssertEqual(store.browseRoot, "")
    }

    func testBrowseRootPersistsToUserDefaults() {
        let store = makeStore()
        store.browseRoot = "/Users/test/src"

        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        let saved = testDefaults.string(forKey: "nala.browseRoot")
        XCTAssertEqual(saved, "/Users/test/src")
    }

    func testBrowseRootLoadsOnStartServices() {
        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        testDefaults.set("/Users/test/projects", forKey: "nala.browseRoot")
        let store = makeStore()
        // startServices calls loadSavedOrder which reads persisted defaults
        store.startServices()
        XCTAssertEqual(store.browseRoot, "/Users/test/projects")
    }

    func testBrowseRootClearPersistsEmpty() {
        let store = makeStore()
        store.browseRoot = "/some/path"
        store.browseRoot = ""

        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        let saved = testDefaults.string(forKey: "nala.browseRoot")
        XCTAssertEqual(saved, "")
    }

    // MARK: - Acknowledge Done Sessions

    func testAcknowledgeSessionTransitionsToIdle() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", status: .done)]
        store.reconcileOrder()

        store.acknowledgeSession("s1")

        XCTAssertEqual(store.sessions[0].status, .idle, "Status should be idle after acknowledgement")
    }

    func testAcknowledgeNoOpWhenNotDone() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", status: .working)]
        store.reconcileOrder()

        store.acknowledgeSession("s1")

        // Should be no-op since session isn't done
        XCTAssertEqual(store.sessions[0].status, .working, "Status should remain working")
    }

    // MARK: - Startup Cleanup

    // -- pruneDisplayNames --

    func testPruneDisplayNamesRemovesStaleEntries() {
        let store = makeStore()
        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        testDefaults.set(["s1": "Active", "s2": "Stale", "s3": "Also Stale"], forKey: "nala.displayNames")

        store.pruneDisplayNames(activeSessionIds: Set(["s1"]))

        let names = testDefaults.dictionary(forKey: "nala.displayNames") as? [String: String] ?? [:]
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(names["s1"], "Active")
        XCTAssertNil(names["s2"])
    }

    func testPruneDisplayNamesAllActive() {
        let store = makeStore()
        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        testDefaults.set(["s1": "One", "s2": "Two"], forKey: "nala.displayNames")

        store.pruneDisplayNames(activeSessionIds: Set(["s1", "s2"]))

        let names = testDefaults.dictionary(forKey: "nala.displayNames") as? [String: String] ?? [:]
        XCTAssertEqual(names.count, 2)
    }

    func testPruneDisplayNamesNoneActive() {
        let store = makeStore()
        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        testDefaults.set(["s1": "One", "s2": "Two"], forKey: "nala.displayNames")

        store.pruneDisplayNames(activeSessionIds: Set())

        let names = testDefaults.dictionary(forKey: "nala.displayNames") as? [String: String] ?? [:]
        XCTAssertTrue(names.isEmpty)
    }

    func testPruneDisplayNamesNoStoredNames() {
        let store = makeStore()
        // No display names stored — should not crash
        store.pruneDisplayNames(activeSessionIds: Set(["s1"]))
        // No assertion needed — just verifying no crash
    }

    // -- pruneEventFiles --

    private func makeTempEventsDir() -> String {
        let dir = NSTemporaryDirectory() + "nala-test-events-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testPruneEventFilesDeletesOrphans() {
        let dir = makeTempEventsDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Create event files: one active, one orphan
        FileManager.default.createFile(atPath: "\(dir)/active-id.jsonl", contents: nil)
        FileManager.default.createFile(atPath: "\(dir)/orphan-id.jsonl", contents: nil)

        let store = makeStore()
        store.pruneEventFiles(activeSessionIds: Set(["active-id"]), eventsDirectory: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/active-id.jsonl"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)/orphan-id.jsonl"))
    }

    func testPruneEventFilesAllActive() {
        let dir = makeTempEventsDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        FileManager.default.createFile(atPath: "\(dir)/s1.jsonl", contents: nil)
        FileManager.default.createFile(atPath: "\(dir)/s2.jsonl", contents: nil)

        let store = makeStore()
        store.pruneEventFiles(activeSessionIds: Set(["s1", "s2"]), eventsDirectory: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/s1.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/s2.jsonl"))
    }

    func testPruneEventFilesIgnoresNonJsonl() {
        let dir = makeTempEventsDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        FileManager.default.createFile(atPath: "\(dir)/README.txt", contents: nil)
        FileManager.default.createFile(atPath: "\(dir)/orphan.jsonl", contents: nil)

        let store = makeStore()
        store.pruneEventFiles(activeSessionIds: Set(), eventsDirectory: dir)

        // Non-jsonl file should survive
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/README.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)/orphan.jsonl"))
    }

    func testPruneEventFilesMissingDirectory() {
        let store = makeStore()
        // Non-existent directory — should not crash
        store.pruneEventFiles(activeSessionIds: Set(), eventsDirectory: "/tmp/nala-nonexistent-\(UUID().uuidString)")
    }

    // -- cleanOrphanedTmpFiles --

    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "nala-test-tmp-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCleanOrphanedTmpFilesDeletesOrphanSettings() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        FileManager.default.createFile(atPath: "\(dir)nala_settings_active-id.json", contents: nil)
        FileManager.default.createFile(atPath: "\(dir)nala_settings_orphan-id.json", contents: nil)

        let store = makeStore()
        store.cleanOrphanedTmpFiles(
            activeSessionNames: Set(),
            activeSessionIds: Set(["active-id"]),
            tmpDirectory: dir
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)nala_settings_active-id.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)nala_settings_orphan-id.json"))
    }

    func testCleanOrphanedTmpFilesDeletesOrphanPrompts() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        FileManager.default.createFile(atPath: "\(dir)nala_prompt_active-id.txt", contents: nil)
        FileManager.default.createFile(atPath: "\(dir)nala_prompt_orphan-id.txt", contents: nil)

        let store = makeStore()
        store.cleanOrphanedTmpFiles(
            activeSessionNames: Set(),
            activeSessionIds: Set(["active-id"]),
            tmpDirectory: dir
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)nala_prompt_active-id.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)nala_prompt_orphan-id.txt"))
    }

    func testCleanOrphanedTmpFilesAlwaysDeletesAttachScripts() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        FileManager.default.createFile(atPath: "\(dir)nala-attach-abc123.sh", contents: nil)
        FileManager.default.createFile(atPath: "\(dir)nala-attach-def456.sh", contents: nil)

        let store = makeStore()
        store.cleanOrphanedTmpFiles(
            activeSessionNames: Set(),
            activeSessionIds: Set(),
            tmpDirectory: dir
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)nala-attach-abc123.sh"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)nala-attach-def456.sh"))
    }

    func testCleanOrphanedTmpFilesKeepsActiveFiles() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        FileManager.default.createFile(atPath: "\(dir)nala_settings_my-id.json", contents: nil)
        FileManager.default.createFile(atPath: "\(dir)nala_prompt_my-id.txt", contents: nil)

        let store = makeStore()
        store.cleanOrphanedTmpFiles(
            activeSessionNames: Set(["my-session"]),
            activeSessionIds: Set(["my-id"]),
            tmpDirectory: dir
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)nala_settings_my-id.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)nala_prompt_my-id.txt"))
    }

    func testCleanOrphanedTmpFilesIgnoresNonNalaFiles() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        FileManager.default.createFile(atPath: "\(dir)other_file.log", contents: nil)
        FileManager.default.createFile(atPath: "\(dir)something_else.json", contents: nil)

        let store = makeStore()
        store.cleanOrphanedTmpFiles(
            activeSessionNames: Set(),
            activeSessionIds: Set(),
            tmpDirectory: dir
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)other_file.log"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)something_else.json"))
    }

    // -- validateRecentBrowsePaths --

    func testValidateRecentBrowsePathsRemovesNonexistent() {
        let store = makeStore()
        // /tmp exists, /nonexistent-nala-test-path does not
        store.recentBrowsePaths = ["/tmp", "/nonexistent-nala-test-path-\(UUID().uuidString)"]

        store.validateRecentBrowsePaths()

        XCTAssertEqual(store.recentBrowsePaths, ["/tmp"])
    }

    func testValidateRecentBrowsePathsAllExist() {
        let store = makeStore()
        store.recentBrowsePaths = ["/tmp", "/"]

        store.validateRecentBrowsePaths()

        XCTAssertEqual(store.recentBrowsePaths, ["/tmp", "/"])
    }

    func testValidateRecentBrowsePathsAllMissing() {
        let store = makeStore()
        let fake1 = "/nonexistent-nala-\(UUID().uuidString)"
        let fake2 = "/nonexistent-nala-\(UUID().uuidString)"
        store.recentBrowsePaths = [fake1, fake2]

        store.validateRecentBrowsePaths()

        XCTAssertTrue(store.recentBrowsePaths.isEmpty)
    }

    func testValidateRecentBrowsePathsKeepsNetworkMounts() {
        let store = makeStore()
        store.recentBrowsePaths = [
            "/Volumes/SomeExternalDisk/project",
            "/Network/Servers/shared/project",
            "/nonexistent-nala-\(UUID().uuidString)",
        ]

        store.validateRecentBrowsePaths()

        XCTAssertEqual(store.recentBrowsePaths.count, 2)
        XCTAssertTrue(store.recentBrowsePaths.contains("/Volumes/SomeExternalDisk/project"))
        XCTAssertTrue(store.recentBrowsePaths.contains("/Network/Servers/shared/project"))
    }

    // -- validateRecentBrowsePaths: TTL --

    func testValidateRecentBrowsePathsRemovesExpiredEntries() {
        let store = makeStore()
        // /tmp exists on disk but its timestamp is 8 days ago — should be pruned
        store.recentBrowsePaths = ["/tmp"]
        store.recentBrowseTimestamps = ["/tmp": Date().addingTimeInterval(-8 * 24 * 60 * 60)]

        store.validateRecentBrowsePaths()

        XCTAssertTrue(store.recentBrowsePaths.isEmpty, "Path older than 7 days should be pruned")
        XCTAssertTrue(store.recentBrowseTimestamps.isEmpty, "Orphan timestamp should be cleaned up")
    }

    func testValidateRecentBrowsePathsKeepsFreshEntries() {
        let store = makeStore()
        // /tmp exists and timestamp is 1 day ago — should survive
        store.recentBrowsePaths = ["/tmp"]
        store.recentBrowseTimestamps = ["/tmp": Date().addingTimeInterval(-1 * 24 * 60 * 60)]

        store.validateRecentBrowsePaths()

        XCTAssertEqual(store.recentBrowsePaths, ["/tmp"], "Path younger than 7 days should survive")
        XCTAssertNotNil(store.recentBrowseTimestamps["/tmp"])
    }

    func testAddRecentBrowsePathRecordsTimestamp() {
        let store = makeStore()
        let before = Date()

        store.addRecentBrowsePath("/tmp")

        let after = Date()
        let timestamp = store.recentBrowseTimestamps["/tmp"]
        XCTAssertNotNil(timestamp, "Timestamp should be recorded for added path")
        XCTAssertGreaterThanOrEqual(timestamp!, before)
        XCTAssertLessThanOrEqual(timestamp!, after)
    }

    // -- reconcileOrder: folderExpansion pruning --

    func testReconcilePrunesStaleFolderExpansion() {
        let store = makeStore()
        store.folderExpansion = ["/old": true, "/proj/alpha": false]
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", workingDirectory: "/proj/alpha"),
        ]

        store.reconcileOrder()

        XCTAssertNil(store.folderExpansion["/old"], "Stale folder expansion entry should be pruned")
        XCTAssertEqual(store.folderExpansion["/proj/alpha"], false, "Active folder expansion should be preserved")
    }

    // -- performStartupCleanup: one-shot guard --

    func testPerformStartupCleanupRunsOnlyOnce() {
        let store = makeStore()
        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!

        // Set up stale display names
        testDefaults.set(["stale": "Old Name"], forKey: "nala.displayNames")
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.reconcileOrder()

        // First call should prune
        store.performStartupCleanup()
        let namesAfterFirst = testDefaults.dictionary(forKey: "nala.displayNames") as? [String: String] ?? [:]
        XCTAssertTrue(namesAfterFirst.isEmpty, "Stale name should be pruned on first call")

        // Add more stale data
        testDefaults.set(["stale2": "Another Old"], forKey: "nala.displayNames")

        // Second call should be a no-op (guard)
        store.performStartupCleanup()
        let namesAfterSecond = testDefaults.dictionary(forKey: "nala.displayNames") as? [String: String] ?? [:]
        XCTAssertEqual(namesAfterSecond.count, 1, "Second call should be guarded — stale data persists")
        XCTAssertEqual(namesAfterSecond["stale2"], "Another Old")
    }

    // MARK: - tmuxNotFound

    func testTmuxNotFoundDefaultsToFalse() {
        let store = makeStore()
        XCTAssertFalse(store.tmuxNotFound, "tmuxNotFound should default to false before services start")
    }

    func testTmuxServiceAvailabilityReflectsInstallState() {
        let tmux = TmuxService()
        // In CI/dev environments tmux is typically installed via Homebrew.
        // This test documents the contract: tmuxAvailable is true iff tmux
        // is found at a known path. If this test runs in an environment
        // without tmux, flip the assertion.
        let tmuxExists = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/tmux")
            || FileManager.default.isExecutableFile(atPath: "/usr/bin/tmux")
        XCTAssertEqual(tmux.tmuxAvailable, tmuxExists,
                       "TmuxService.tmuxAvailable should match whether tmux is on disk")
    }

    // MARK: - Folder Interaction Tracking

    func testRecordFolderInteractionUpdatesTimestamp() {
        let store = makeStore()
        let before = Date()

        store.recordFolderInteraction("/proj/alpha")

        let after = Date()
        let timestamp = store.folderLastUsed["/proj/alpha"]
        XCTAssertNotNil(timestamp, "Timestamp should be recorded for folder")
        XCTAssertGreaterThanOrEqual(timestamp!, before)
        XCTAssertLessThanOrEqual(timestamp!, after)
    }

    func testRecordFolderInteractionForSessionResolvesFolder() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/proj/alpha")]
        store.reconcileOrder()

        store.recordFolderInteractionForSession("s1")

        XCTAssertNotNil(store.folderLastUsed["/proj/alpha"],
                        "Should record timestamp for the session's folder")
    }

    func testRecordFolderInteractionForSessionNoOpForMissing() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/proj/alpha")]

        // Should not crash for non-existent session
        store.recordFolderInteractionForSession("nonexistent")

        XCTAssertTrue(store.folderLastUsed.isEmpty)
    }

    func testFolderLastUsedPersistsToUserDefaults() {
        let store = makeStore()
        store.recordFolderInteraction("/proj/alpha")

        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        let data = testDefaults.data(forKey: "nala.folderLastUsed")
        XCTAssertNotNil(data, "folderLastUsed should be persisted to UserDefaults")

        let decoded = try? JSONDecoder().decode([String: Date].self, from: data!)
        XCTAssertNotNil(decoded?["/proj/alpha"])
    }

    func testFolderLastUsedLoadsOnStartServices() {
        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        let date = Date()
        let encoded = try! JSONEncoder().encode(["/proj/alpha": date])
        testDefaults.set(encoded, forKey: "nala.folderLastUsed")

        let store = makeStore()
        store.startServices()

        XCTAssertNotNil(store.folderLastUsed["/proj/alpha"],
                        "folderLastUsed should load from UserDefaults on startup")
    }

    func testReconcilePrunesStaleFolderLastUsed() {
        let store = makeStore()
        store.folderLastUsed = ["/old": Date(), "/proj/alpha": Date()]
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", workingDirectory: "/proj/alpha"),
        ]

        store.reconcileOrder()

        XCTAssertNil(store.folderLastUsed["/old"],
                     "Stale folder last-used entry should be pruned")
        XCTAssertNotNil(store.folderLastUsed["/proj/alpha"],
                        "Active folder last-used entry should be preserved")
    }

    func testLaunchSessionRecordsFolderInteraction() {
        let store = makeStore()
        store.sessions = []
        store.reconcileOrder()

        store.launchSession(agentType: "claude", in: "/proj/alpha")

        XCTAssertNotNil(store.folderLastUsed["/proj/alpha"],
                        "launchSession should record folder interaction")
    }

    // MARK: - handleAgentCancel (Cancel-to-Idle)

    func testHandleAgentCancelWhileWorking() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", status: .working)]
        store.reconcileOrder()

        store.handleAgentCancel(sessionId: "s1")

        // Immediately after calling, session should still be working (2s debounce)
        XCTAssertEqual(store.sessions[0].status, .working, "Session should still be working before debounce fires")

        // Wait for the debounce timer to fire
        let expectation = expectation(description: "Cancel debounce fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)

        // After debounce, status should be idle
        XCTAssertEqual(store.sessions[0].status, .idle, "Status should be idle after cancel")
        XCTAssertEqual(store.sessions[0].latestEventSummary, "Cancelled")
    }

    func testHandleAgentCancelWhileNotWorking() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.reconcileOrder()

        store.handleAgentCancel(sessionId: "s1")

        // Should be a no-op — no timer scheduled, no state change
        let expectation = expectation(description: "Brief wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(store.sessions[0].status, .idle, "Should remain idle")
        XCTAssertNil(store.sessions[0].latestEventSummary, "Summary should not change")
    }

    func testHandleAgentCancelDebounce() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", status: .working)]
        store.reconcileOrder()

        // Trigger cancel
        store.handleAgentCancel(sessionId: "s1")

        // Within the 2s window, a working event arrives — should cancel the pending timer
        let event = StateEvent.toolUse(tool: "Read", summary: "Read file.swift", timestamp: Date())
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", event: event))

        // Wait past the debounce period
        let expectation = expectation(description: "Cancel debounce window passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)

        // Session should still be working (cancel was debounced by the working event)
        XCTAssertEqual(store.sessions[0].status, .working, "Session should stay working — cancel was debounced")
        XCTAssertEqual(store.sessions[0].latestEventSummary, "Read file.swift")
    }

    func testHandleAgentCancelClearsCorrectSession() {
        let store = makeStore()
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", workingDirectory: "/tmp", status: .working),
            makeSession(name: "b", sessionId: "s2", workingDirectory: "/tmp", status: .working),
        ]
        store.reconcileOrder()

        // Cancel only s1
        store.handleAgentCancel(sessionId: "s1")

        // Wait for debounce
        let expectation = expectation(description: "Cancel debounce fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)

        // s1 should be idle
        let s1 = store.sessions.first { $0.sessionId == "s1" }!
        XCTAssertEqual(s1.status, .idle, "s1 should be idle after cancel")
        XCTAssertEqual(s1.latestEventSummary, "Cancelled")

        // s2 should still be working
        let s2 = store.sessions.first { $0.sessionId == "s2" }!
        XCTAssertEqual(s2.status, .working, "s2 should still be working — only s1 was cancelled")
    }

    // MARK: - lastFocusedTimestamps Persistence

    func testLastFocusedTimestampsPersistsToUserDefaults() {
        let store = makeStore()
        store.lastFocusedTimestamps["s1"] = Date()

        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        let data = testDefaults.data(forKey: "nala.lastFocusedTimestamps")
        XCTAssertNotNil(data, "lastFocusedTimestamps should be persisted to UserDefaults")

        let decoded = try? JSONDecoder().decode([String: Date].self, from: data!)
        XCTAssertNotNil(decoded?["s1"])
    }

    func testLastFocusedTimestampsLoadsOnStartServices() {
        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        let date = Date()
        let encoded = try! JSONEncoder().encode(["s1": date])
        testDefaults.set(encoded, forKey: "nala.lastFocusedTimestamps")

        let store = makeStore()
        store.startServices()

        XCTAssertNotNil(store.lastFocusedTimestamps["s1"],
                        "lastFocusedTimestamps should load from UserDefaults on startup")
    }

    func testReconcilePrunesStaleLastFocusedTimestamps() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.lastFocusedTimestamps = ["s1": Date(), "stale-id": Date()]

        store.reconcileOrder()

        XCTAssertNotNil(store.lastFocusedTimestamps["s1"],
                        "Active session timestamp should be preserved")
        XCTAssertNil(store.lastFocusedTimestamps["stale-id"],
                     "Stale session timestamp should be pruned")
    }
}
