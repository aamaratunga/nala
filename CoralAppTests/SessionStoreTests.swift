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
}
