import XCTest
@testable import Coral

final class SessionStoreTests: XCTestCase {

    private func makeStore() -> SessionStore {
        SessionStore()
    }

    // MARK: - Full Update

    func testFullUpdateReplacesSessions() {
        let store = makeStore()
        store.sessions = [makeSession(name: "old", sessionId: "old-1")]

        store.handleFullUpdate([
            makeSession(name: "new-a", sessionId: "new-1", workingDirectory: "/tmp/a"),
            makeSession(name: "new-b", sessionId: "new-2", workingDirectory: "/tmp/a"),
        ])

        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions[0].sessionId, "new-1")
        XCTAssertEqual(store.sessions[1].sessionId, "new-2")
    }

    func testFullUpdateDeduplicatesById() {
        let store = makeStore()

        store.handleFullUpdate([
            makeSession(name: "agent-1", sessionId: "dup-1", workingDirectory: "/tmp"),
            makeSession(name: "agent-1-copy", sessionId: "dup-1", workingDirectory: "/tmp"),
        ])

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].name, "agent-1")
    }

    func testFullUpdatePreservesExistingCommands() {
        let store = makeStore()
        let cmds = [SessionCommand(name: "test", description: "Run tests")]
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", commands: cmds)]

        // Incoming session has no commands (as WebSocket payloads typically don't)
        store.handleFullUpdate([
            makeSession(sessionId: "s1", workingDirectory: "/tmp", commands: [])
        ])

        XCTAssertEqual(store.sessions[0].commands, cmds)
    }

    func testFullUpdateSetsIsConnected() {
        let store = makeStore()
        XCTAssertFalse(store.isConnected)

        store.handleFullUpdate([makeSession(workingDirectory: "/tmp")])

        XCTAssertTrue(store.isConnected)
    }

    // MARK: - Diff — Changes

    func testDiffUpdatesExistingSessionByCompositeKey() {
        let store = makeStore()
        store.sessions = [makeSession(name: "a", sessionId: "s1", status: nil, workingDirectory: "/tmp")]

        store.handleDiff(
            changed: [makeSession(name: "a", sessionId: "s1", status: "Working", workingDirectory: "/tmp")],
            removed: []
        )

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].status, "Working")
    }

    func testDiffMatchesByNameWhenSessionIdEmpty() {
        let store = makeStore()
        store.sessions = [makeSession(name: "term-1", sessionId: "", workingDirectory: "/tmp")]

        store.handleDiff(
            changed: [makeSession(name: "term-1", sessionId: "", status: "Busy", workingDirectory: "/tmp")],
            removed: []
        )

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].status, "Busy")
    }

    func testDiffAppendsNewSession() {
        let store = makeStore()
        store.sessions = [makeSession(name: "a", sessionId: "s1", workingDirectory: "/tmp")]

        store.handleDiff(
            changed: [makeSession(name: "b", sessionId: "s2", workingDirectory: "/tmp")],
            removed: []
        )

        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions[1].sessionId, "s2")
    }

    func testDiffPreservesCommandsOnUpdate() {
        let store = makeStore()
        let cmds = [SessionCommand(name: "build", description: "Build it")]
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp", commands: cmds)]

        store.handleDiff(
            changed: [makeSession(sessionId: "s1", workingDirectory: "/tmp", commands: [])],
            removed: []
        )

        XCTAssertEqual(store.sessions[0].commands, cmds)
    }

    // MARK: - Diff — Removals

    func testDiffRemovesBySessionId() {
        let store = makeStore()
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", workingDirectory: "/tmp"),
            makeSession(name: "b", sessionId: "s2", workingDirectory: "/tmp"),
        ]

        store.handleDiff(changed: [], removed: ["s1"])

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].sessionId, "s2")
    }

    func testDiffRemovesByName() {
        let store = makeStore()
        store.sessions = [
            makeSession(name: "term-1", sessionId: "", workingDirectory: "/tmp"),
            makeSession(name: "agent-1", sessionId: "s1", workingDirectory: "/tmp"),
        ]

        store.handleDiff(changed: [], removed: ["term-1"])

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].name, "agent-1")
    }

    func testDiffClearsSelectionWhenSelectedRemoved() {
        let store = makeStore()
        store.sessions = [makeSession(sessionId: "s1", workingDirectory: "/tmp")]
        store.selectedSessionId = "s1"

        store.handleDiff(changed: [], removed: ["s1"])

        XCTAssertNil(store.selectedSessionId)
    }

    func testDiffKeepsSelectionWhenOtherRemoved() {
        let store = makeStore()
        store.sessions = [
            makeSession(name: "a", sessionId: "s1", workingDirectory: "/tmp"),
            makeSession(name: "b", sessionId: "s2", workingDirectory: "/tmp"),
        ]
        store.selectedSessionId = "s1"

        store.handleDiff(changed: [], removed: ["s2"])

        XCTAssertEqual(store.selectedSessionId, "s1")
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

    // MARK: - Pending Kills (Task 7.1.1)

    func testHandleDiffFiltersPendingKills() {
        let store = makeStore()
        let s1 = makeSession(name: "a", sessionId: "s1", workingDirectory: "/tmp")
        let s2 = makeSession(name: "b", sessionId: "s2", workingDirectory: "/tmp")
        store.sessions = [s1, s2]
        store.reconcileOrder()

        // Optimistically remove s1 — this adds "s1" to pendingKills
        store.removeSessionOptimistically(s1)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].sessionId, "s2")

        // Now a diff arrives with s1 as a changed session — should NOT be re-added
        store.handleDiff(
            changed: [makeSession(name: "a", sessionId: "s1", status: "Working", workingDirectory: "/tmp")],
            removed: []
        )

        XCTAssertEqual(store.sessions.count, 1, "Killed session should not be re-added by handleDiff")
        XCTAssertEqual(store.sessions[0].sessionId, "s2")
    }

    func testPendingKillsClearedOnRemovalDiff() {
        let store = makeStore()
        let s1 = makeSession(name: "a", sessionId: "s1", workingDirectory: "/tmp")
        store.sessions = [s1]
        store.reconcileOrder()

        store.removeSessionOptimistically(s1)
        XCTAssertTrue(store.sessions.isEmpty)

        // Server sends removal diff for s1 — clears pendingKills
        store.handleDiff(changed: [], removed: ["s1"])

        // Now if s1 reappears (e.g. same name relaunched), it should be added
        store.handleDiff(
            changed: [makeSession(name: "a-new", sessionId: "s1", workingDirectory: "/tmp")],
            removed: []
        )
        XCTAssertEqual(store.sessions.count, 1, "Session should be added after pendingKills is cleared")
    }

    // MARK: - Launch Placeholder (Task 7.1.2)

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

    func testLaunchPlaceholderReplacedByDiff() {
        let store = makeStore()
        store.sessions = []
        store.reconcileOrder()

        // Launch creates placeholder
        store.launchSession(agentType: "claude", in: "/tmp")
        let placeholderId = store.selectedSessionId!
        let launchState = store.activeLaunches[placeholderId]!

        // Simulate the API response arriving (set realSessionId on launch state)
        launchState.realSessionId = "real-session-123"
        launchState.isFinished = true

        // Simulate WS diff with the real session matching the realSessionId
        store.handleDiff(
            changed: [makeSession(name: "claude-agent-1", sessionId: "real-session-123", workingDirectory: "/tmp")],
            removed: []
        )

        // Placeholder should be gone, real session should exist
        XCTAssertNil(store.sessions.first(where: { $0.isPlaceholder }), "Placeholder should be removed")
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].sessionId, "real-session-123")

        // Selection should transfer to real session
        XCTAssertEqual(store.selectedSessionId, "real-session-123")

        // activeLaunches should be cleaned up
        XCTAssertNil(store.activeLaunches[placeholderId])
    }

    // MARK: - Optimistic Kill (Task 7.1.3)

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

        // Take a snapshot before kill
        let snapshot = s1

        store.removeSessionOptimistically(s1)
        XCTAssertTrue(store.sessions.isEmpty)

        // Restore (simulates API kill failure → undo)
        store.restoreSession(snapshot)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].id, "s1")

        // After restore, handleDiff should be able to add the session again
        // (pendingKills should be cleared by restoreSession)
        store.handleDiff(
            changed: [makeSession(name: "a", sessionId: "s1", status: "Updated", workingDirectory: "/tmp")],
            removed: []
        )
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].status, "Updated")
    }

    // MARK: - Rename (Task 7.1.4)

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

        let saved = UserDefaults.standard.stringArray(forKey: "coral.recentBrowsePaths")
        XCTAssertNotNil(saved)
        XCTAssertTrue(saved?.contains("/persisted/path") ?? false)
    }

    // MARK: - Browse Root

    func testBrowseRootDefaultsToEmpty() {
        UserDefaults.standard.removeObject(forKey: "coral.browseRoot")
        let store = makeStore()
        XCTAssertEqual(store.browseRoot, "")
    }

    func testBrowseRootPersistsToUserDefaults() {
        let store = makeStore()
        store.browseRoot = "/Users/test/src"

        let saved = UserDefaults.standard.string(forKey: "coral.browseRoot")
        XCTAssertEqual(saved, "/Users/test/src")
    }

    func testBrowseRootLoadsOnConnect() {
        UserDefaults.standard.set("/Users/test/projects", forKey: "coral.browseRoot")
        let store = makeStore()
        // loadSavedOrder is called inside connect(), which reads persisted defaults
        store.connect(port: 0)
        XCTAssertEqual(store.browseRoot, "/Users/test/projects")
    }

    func testBrowseRootClearPersistsEmpty() {
        let store = makeStore()
        store.browseRoot = "/some/path"
        store.browseRoot = ""

        let saved = UserDefaults.standard.string(forKey: "coral.browseRoot")
        XCTAssertEqual(saved, "")
    }
}
