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

    // MARK: - handlePulseUpdate

    func testPulseUpdateSetsStatusAndSummary() {
        let store = makeStore()
        store.sessions = [makeSession(name: "claude-s1", sessionId: "s1", workingDirectory: "/tmp")]
        store.reconcileOrder()

        let update = PulseUpdate(
            sessionName: "claude-s1",
            result: PulseResult(status: "Implementing tests", summary: "Adding unit tests")
        )
        store.handlePulseUpdate(update)

        XCTAssertEqual(store.sessions[0].status, "Implementing tests")
        XCTAssertEqual(store.sessions[0].summary, "Adding unit tests")
    }

    func testPulseUpdateNoOpForUnknownSession() {
        let store = makeStore()
        store.sessions = [makeSession(name: "claude-s1", sessionId: "s1", workingDirectory: "/tmp")]

        let update = PulseUpdate(
            sessionName: "nonexistent",
            result: PulseResult(status: "Stuff", summary: "Things")
        )
        // Should not crash
        store.handlePulseUpdate(update)

        XCTAssertNil(store.sessions[0].status)
    }

    // MARK: - handleAgentStateUpdate

    func testAgentStateUpdatePropagatesAllFields() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.reconcileOrder()

        let now = Date()
        let state = AgentState(
            working: true,
            done: false,
            waitingForInput: false,
            stuck: false,
            sleeping: false,
            lastEventTime: now,
            latestEventType: "tool_use",
            latestEventSummary: "Edited main.swift",
            waitingReason: nil,
            waitingSummary: nil
        )
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", state: state))

        XCTAssertTrue(store.sessions[0].working)
        XCTAssertFalse(store.sessions[0].done)
        XCTAssertFalse(store.sessions[0].waitingForInput)
        XCTAssertFalse(store.sessions[0].stuck)
        XCTAssertFalse(store.sessions[0].sleeping)
        XCTAssertEqual(store.sessions[0].latestEventSummary, "Edited main.swift")
        XCTAssertNotNil(store.sessions[0].stalenessSeconds)
    }

    func testAgentStateUpdateSuppressesDoneIfAcknowledged() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", done: true)]
        store.reconcileOrder()

        // Pre-acknowledge the session
        store.acknowledgeSession("s1")
        XCTAssertFalse(store.sessions[0].done)

        // Agent reports done=true again
        let state = AgentState(done: true, latestEventType: "stop", latestEventSummary: "Agent stopped")
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", state: state))

        // Should still be suppressed
        XCTAssertFalse(store.sessions[0].done)
    }

    func testAgentStateUpdateAutoAcknowledgesSelectedSession() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.reconcileOrder()
        store.selectedSessionId = "s1"

        let state = AgentState(done: true, latestEventType: "stop", latestEventSummary: "Done")
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", state: state))

        // Auto-acknowledged: done should be cleared
        XCTAssertFalse(store.sessions[0].done)

        // Persisted in acknowledged set
        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        let saved = testDefaults.stringArray(forKey: "nala.acknowledgedSessions") ?? []
        XCTAssertTrue(saved.contains("s1"))
    }

    func testAgentStateUpdateClearsAcknowledgementOnNewActivity() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", done: true)]
        store.reconcileOrder()

        // Acknowledge
        store.acknowledgeSession("s1")

        // Agent becomes active again
        let state = AgentState(working: true, done: false, latestEventType: "tool_use", latestEventSummary: "Read file.swift")
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", state: state))

        // Acknowledged set should be cleared for this session
        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        let saved = testDefaults.stringArray(forKey: "nala.acknowledgedSessions") ?? []
        XCTAssertFalse(saved.contains("s1"), "Acknowledgement should clear on new activity")

        // Now when it becomes done again, it should show as done
        let doneState = AgentState(done: true, latestEventType: "stop", latestEventSummary: "Stopped")
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", state: doneState))

        // Not selected, so done should remain true
        store.selectedSessionId = nil
        XCTAssertTrue(store.sessions[0].done, "Done should not be suppressed after acknowledgement cleared")
    }

    func testAgentStateUpdateFiltersPromptSubmitFromEventSummary() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", latestEventSummary: "Read main.swift")]
        store.reconcileOrder()

        let state = AgentState(
            working: true,
            latestEventType: "prompt_submit",
            latestEventSummary: "User submitted prompt"
        )
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", state: state))

        // latestEventSummary should NOT be updated for prompt_submit
        XCTAssertEqual(store.sessions[0].latestEventSummary, "Read main.swift")
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
        XCTAssertTrue(placeholder?.working ?? false)

        // Placeholder should be selected
        XCTAssertEqual(store.selectedSessionId, placeholder?.id)

        // activeLaunches should have an entry
        XCTAssertNotNil(store.activeLaunches[placeholder!.id])
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

    func testAcknowledgeSessionClearsDone() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", done: true)]
        store.reconcileOrder()

        store.acknowledgeSession("s1")

        XCTAssertFalse(store.sessions[0].done, "Done should be cleared after acknowledgement")
    }

    func testAcknowledgeSessionPersists() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", done: true)]
        store.reconcileOrder()

        store.acknowledgeSession("s1")

        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        let saved = testDefaults.stringArray(forKey: "nala.acknowledgedSessions") ?? []
        XCTAssertTrue(saved.contains("s1"), "Acknowledged session ID should be persisted")
    }

    func testAcknowledgeNoOpWhenNotDone() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", done: false, working: true)]
        store.reconcileOrder()

        store.acknowledgeSession("s1")

        // Should not add to acknowledged set since session isn't done
        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        let saved = testDefaults.stringArray(forKey: "nala.acknowledgedSessions") ?? []
        XCTAssertFalse(saved.contains("s1"), "Non-done session should not be acknowledged")
    }

    func testAcknowledgedSessionsLoadOnStartup() {
        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        testDefaults.set(["s1", "s2"], forKey: "nala.acknowledgedSessions")

        let store = makeStore()
        store.startServices() // triggers loadSavedOrder → loadAcknowledgedSessions

        // Verify by checking that a done session with acknowledged ID is suppressed
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.reconcileOrder()

        let state = AgentState(done: true, latestEventType: "stop", latestEventSummary: "Done")
        store.handleAgentStateUpdate(AgentStateUpdate(sessionId: "s1", state: state))

        XCTAssertFalse(store.sessions[0].done, "Done should be suppressed for pre-acknowledged session")
    }

    func testReconcilePrunesStaleAcknowledgedIds() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.reconcileOrder()

        // Manually acknowledge a session, then remove it
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", done: true)]
        store.acknowledgeSession("s1")

        // Now remove s1 and reconcile
        store.sessions = [makeSession(sessionId: "s2", workingDirectory: "/tmp")]
        store.reconcileOrder()

        // s1 should be pruned from acknowledged set
        let testDefaults = UserDefaults(suiteName: Self.testSuiteName)!
        let saved = testDefaults.stringArray(forKey: "nala.acknowledgedSessions") ?? []
        XCTAssertFalse(saved.contains("s1"), "Stale acknowledged ID should be pruned")
    }
}
