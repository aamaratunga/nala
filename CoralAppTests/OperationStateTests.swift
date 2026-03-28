import XCTest
@testable import Coral

final class OperationStateTests: XCTestCase {

    // MARK: - WorktreeCreationState (Task 7.2.1)

    func testCreationStateTransitions() {
        let state = WorktreeCreationState(
            branchName: "feature/test",
            repoDisplayName: "my-repo",
            worktreePath: "/worktrees/feature-test",
            repoPath: "/repos/my-repo"
        )

        // All steps start as pending
        for step in WorktreeCreationState.Step.allCases {
            XCTAssertEqual(state.stepStatuses[step], .pending)
        }
        XCTAssertFalse(state.isFinished)
        XCTAssertFalse(state.hasFailed)
        XCTAssertNil(state.currentStep)

        // Advance through the pipeline
        state.advance(to: .creatingWorktree)
        XCTAssertEqual(state.currentStep, .creatingWorktree)
        XCTAssertEqual(state.stepStatuses[.creatingWorktree], .inProgress)

        state.completeCurrentStep()
        XCTAssertEqual(state.stepStatuses[.creatingWorktree], .completed)

        // Skip setup script (no script configured)
        state.skipStep(.runningSetupScript)
        XCTAssertEqual(state.stepStatuses[.runningSetupScript], .skipped)

        // Launch agent
        state.advance(to: .launchingAgent)
        XCTAssertEqual(state.stepStatuses[.launchingAgent], .inProgress)
        // Previous step should be completed when advance is called
        XCTAssertEqual(state.stepStatuses[.creatingWorktree], .completed)

        state.completeCurrentStep()
        state.isFinished = true
        XCTAssertTrue(state.isFinished)
        XCTAssertFalse(state.hasFailed)
    }

    func testCreationStateFailure() {
        let state = WorktreeCreationState(
            branchName: "bad-branch",
            repoDisplayName: "my-repo",
            worktreePath: "/worktrees/bad-branch",
            repoPath: "/repos/my-repo"
        )

        state.advance(to: .creatingWorktree)
        state.fail(at: .creatingWorktree, message: "Branch already exists")

        XCTAssertTrue(state.hasFailed)
        XCTAssertEqual(state.error, "Branch already exists")
        XCTAssertNil(state.currentStep)
        if case .failed(let msg) = state.stepStatuses[.creatingWorktree] {
            XCTAssertEqual(msg, "Branch already exists")
        } else {
            XCTFail("Expected .failed status")
        }
    }

    func testCreationPlaceholderInStore() {
        let store = SessionStore()
        store.sessions = []
        var config = RepoConfig()
        config.repoPath = "/repos/my-repo"
        config.worktreeFolderPath = "/worktrees"
        store.repoConfigs = [config]

        // beginWorktreeCreation creates placeholder + state synchronously
        store.beginWorktreeCreation(
            config: store.repoConfigs[0],
            branchName: "test-branch"
        )

        // Placeholder should exist
        XCTAssertEqual(store.sessions.count, 1)
        let placeholder = store.sessions[0]
        XCTAssertTrue(placeholder.isPlaceholder)
        XCTAssertEqual(placeholder.branch, "test-branch")
        XCTAssertEqual(placeholder.workingDirectory, "/worktrees/test-branch")

        // Creation state should exist
        XCTAssertNotNil(store.activeCreations[placeholder.id])

        // Should be selected
        XCTAssertEqual(store.selectedSessionId, placeholder.id)

        // Discovered folders should include the worktree path
        XCTAssertTrue(store.discoveredFolders.contains("/worktrees/test-branch"))
    }

    // MARK: - WorktreeDeletionState (Task 7.2.2)

    func testDeletionStateTransitions() {
        let state = WorktreeDeletionState(
            folderPath: "/worktrees/old-branch",
            sessionCount: 2,
            repoPath: "/repos/my-repo"
        )

        // All steps start as pending
        for step in WorktreeDeletionState.Step.allCases {
            XCTAssertEqual(state.stepStatuses[step], .pending)
        }
        XCTAssertFalse(state.isFinished)
        XCTAssertFalse(state.hasFailed)

        // Step 1: Kill sessions
        state.advance(to: .killingSessions)
        XCTAssertEqual(state.stepStatuses[.killingSessions], .inProgress)

        state.completeCurrentStep()
        XCTAssertEqual(state.stepStatuses[.killingSessions], .completed)

        // Step 2: Skip pre-delete script
        state.skipStep(.runningPreDeleteScript)
        XCTAssertEqual(state.stepStatuses[.runningPreDeleteScript], .skipped)

        // Step 3: Remove worktree
        state.advance(to: .removingWorktree)
        XCTAssertEqual(state.stepStatuses[.removingWorktree], .inProgress)

        state.completeCurrentStep()

        // Step 4: Delete branch
        state.advance(to: .deletingBranch)
        XCTAssertEqual(state.stepStatuses[.deletingBranch], .inProgress)

        state.completeCurrentStep()
        state.isFinished = true

        XCTAssertTrue(state.isFinished)
        XCTAssertFalse(state.hasFailed)
    }

    func testDeletionStateFailureAtRemoveStep() {
        let state = WorktreeDeletionState(
            folderPath: "/worktrees/stuck",
            sessionCount: 0,
            repoPath: "/repos/my-repo"
        )

        state.skipStep(.killingSessions)
        state.skipStep(.runningPreDeleteScript)
        state.advance(to: .removingWorktree)
        state.fail(at: .removingWorktree, message: "Permission denied")

        XCTAssertTrue(state.hasFailed)
        XCTAssertEqual(state.error, "Permission denied")
        // Steps after failure should remain pending
        XCTAssertEqual(state.stepStatuses[.deletingBranch], .pending)
    }

    func testDeletionStateMetadata() {
        let state = WorktreeDeletionState(
            folderPath: "/worktrees/my-feature",
            sessionCount: 3,
            repoPath: "/repos/project"
        )

        XCTAssertEqual(state.folderLabel, "my-feature")
        XCTAssertEqual(state.sessionCount, 3)
        XCTAssertEqual(state.id, "/worktrees/my-feature")
    }

    func testDeletionStateInStore() {
        let store = SessionStore()
        let s1 = makeSession(name: "a", sessionId: "s1", workingDirectory: "/worktrees/old")
        let s2 = makeSession(name: "b", sessionId: "s2", workingDirectory: "/worktrees/old")
        store.sessions = [s1, s2]
        store.reconcileOrder()

        // beginWorktreeDeletion creates state + selects session synchronously
        store.beginWorktreeDeletion(folderPath: "/worktrees/old")

        // Deletion state should exist
        XCTAssertNotNil(store.activeDeletions["/worktrees/old"])

        // First session in the folder should be selected
        XCTAssertEqual(store.selectedSessionId, "s1")
    }

    // MARK: - SessionRestartState (Task 7.2.3)

    func testRestartStateInitialValues() {
        let session = makeSession(name: "agent-1", sessionId: "s1", workingDirectory: "/tmp")
        let state = SessionRestartState(originalSession: session)

        XCTAssertEqual(state.id, "s1")
        XCTAssertEqual(state.originalSession.name, "agent-1")
        XCTAssertFalse(state.isFinished)
        XCTAssertNil(state.error)
    }

    func testRestartStatePhaseTransitions() {
        let session = makeSession(name: "agent-1", sessionId: "s1", workingDirectory: "/tmp")
        let state = SessionRestartState(originalSession: session)

        // Starts in killing phase
        XCTAssertEqual(state.phase, .killing)

        // Transitions to launching
        state.phase = .launching
        XCTAssertEqual(state.phase, .launching)

        // Finishes
        state.isFinished = true
        XCTAssertTrue(state.isFinished)
    }

    func testRestartStateInStore() {
        let store = SessionStore()
        let s1 = makeSession(name: "agent-1", sessionId: "s1", workingDirectory: "/tmp")
        store.sessions = [s1]
        store.reconcileOrder()

        // restartSession creates state synchronously
        store.restartSession(s1)

        // State should exist keyed by the original session's ID
        XCTAssertNotNil(store.activeRestarts["s1"])
        XCTAssertEqual(store.activeRestarts["s1"]?.originalSession.name, "agent-1")
    }

    // MARK: - SessionLaunchState

    func testLaunchStateInitialValues() {
        let state = SessionLaunchState(workingDirectory: "/tmp/project", agentType: "claude")

        XCTAssertTrue(state.id.hasPrefix("launching-"))
        XCTAssertEqual(state.workingDirectory, "/tmp/project")
        XCTAssertEqual(state.agentType, "claude")
        XCTAssertFalse(state.isFinished)
        XCTAssertNil(state.realSessionId)
        XCTAssertNil(state.error)
    }

    // MARK: - ProgressStep Protocol

    func testCreationStepsConformToProgressStep() {
        let allSteps = WorktreeCreationState.Step.allCases
        XCTAssertEqual(allSteps.count, 3)
        XCTAssertEqual(allSteps.map(\.rawValue), [
            "Creating worktree",
            "Running setup script",
            "Launching agent"
        ])
    }

    func testDeletionStepsConformToProgressStep() {
        let allSteps = WorktreeDeletionState.Step.allCases
        XCTAssertEqual(allSteps.count, 4)
        XCTAssertEqual(allSteps.map(\.rawValue), [
            "Killing sessions",
            "Running pre-delete script",
            "Removing worktree",
            "Deleting branch"
        ])
    }
}
