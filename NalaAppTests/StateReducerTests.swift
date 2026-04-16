import XCTest
@testable import Nala

final class StateReducerTests: XCTestCase {

    private let now = Date()

    // MARK: - Basic Transitions

    func testIdleToWorkingOnToolUse() {
        let t = StateReducer.reduce(
            current: .idle,
            event: .toolUse(tool: "Read", summary: "Read main.swift", timestamp: now),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .working)
        XCTAssertTrue(t.didChange)
        XCTAssertEqual(t.from, .idle)
        XCTAssertEqual(t.source, .eventWatcher)
    }

    func testIdleToWorkingOnPromptSubmit() {
        let t = StateReducer.reduce(
            current: .idle,
            event: .promptSubmit(summary: "Fix the bug", timestamp: now),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .working)
        XCTAssertTrue(t.didChange)
    }

    func testIdleIgnoresLateStop() {
        // A late stop (arriving after the session was already auto-acknowledged)
        // must not re-trigger done.
        let t = StateReducer.reduce(
            current: .idle,
            event: .stop(reason: "end_turn", timestamp: now),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .idle)
        XCTAssertFalse(t.didChange)
    }

    func testWorkingToDoneOnStop() {
        let t = StateReducer.reduce(
            current: .working,
            event: .stop(reason: "end_turn", timestamp: now),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .done)
        XCTAssertTrue(t.didChange)
    }

    func testWorkingToWaitingOnPermissionRequest() {
        let t = StateReducer.reduce(
            current: .working,
            event: .permissionRequest(
                tool: "Bash",
                summary: "Permission required: Ran: rm -rf /tmp/old",
                waitingReason: "Permission required: Ran: rm -rf /tmp/old",
                waitingSummary: "Permission required: Ran: rm -rf /tmp/old",
                timestamp: now
            ),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .waitingForInput)
        XCTAssertTrue(t.didChange)
    }

    func testWorkingToStuckOnStaleness() {
        let t = StateReducer.reduce(
            current: .working,
            event: .stalenessCheck(elapsed: 400), // > 360s threshold
            source: .stalenessRefresh
        )
        XCTAssertEqual(t.to, .stuck)
        XCTAssertTrue(t.didChange)
    }

    func testWorkingNotStuckBelowThreshold() {
        let t = StateReducer.reduce(
            current: .working,
            event: .stalenessCheck(elapsed: 300), // < 360s threshold
            source: .stalenessRefresh
        )
        XCTAssertEqual(t.to, .working)
        XCTAssertFalse(t.didChange)
    }

    func testWorkingToSleeping() {
        let t = StateReducer.reduce(
            current: .working,
            event: .sleepDetected(summary: "Ran: sleep 60", timestamp: now),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .sleeping)
        XCTAssertTrue(t.didChange)
    }

    func testDoneToWorkingOnPromptSubmit() {
        let t = StateReducer.reduce(
            current: .done,
            event: .promptSubmit(summary: "Continue", timestamp: now),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .working)
        XCTAssertTrue(t.didChange)
    }

    func testDoneToWorkingOnToolUse() {
        let t = StateReducer.reduce(
            current: .done,
            event: .toolUse(tool: "Read", summary: "Read file", timestamp: now),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .working)
        XCTAssertTrue(t.didChange)
    }

    func testDoneToIdleOnUserAcknowledged() {
        let t = StateReducer.reduce(
            current: .done,
            event: .userAcknowledged,
            source: .userAction
        )
        XCTAssertEqual(t.to, .idle)
        XCTAssertTrue(t.didChange)
    }

    func testDoneToIdleOnUserCancelled() {
        let t = StateReducer.reduce(
            current: .done,
            event: .userCancelled,
            source: .userAction
        )
        XCTAssertEqual(t.to, .idle)
        XCTAssertTrue(t.didChange)
    }

    func testWorkingToIdleOnUserCancelled() {
        let t = StateReducer.reduce(
            current: .working,
            event: .userCancelled,
            source: .userAction
        )
        XCTAssertEqual(t.to, .idle)
        XCTAssertTrue(t.didChange)
    }

    // MARK: - Session Reset

    func testSessionResetFromAnyState() {
        let states: [AgentStatus] = [.idle, .working, .waitingForInput, .sleeping, .done, .stuck]
        for state in states {
            let t = StateReducer.reduce(current: state, event: .sessionReset, source: .eventWatcher)
            XCTAssertEqual(t.to, .idle, "sessionReset from \(state) should go to idle")
        }
    }

    // MARK: - Same-State Re-application (didChange = false)

    func testSameStateReappliedReturnsFalse() {
        // Working + toolUse → working (no change)
        let t = StateReducer.reduce(
            current: .working,
            event: .toolUse(tool: "Read", summary: "Read file", timestamp: now),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .working)
        XCTAssertFalse(t.didChange)
    }

    func testDoneStopReappliedReturnsFalse() {
        let t = StateReducer.reduce(
            current: .done,
            event: .stop(reason: "end_turn", timestamp: now),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .done)
        XCTAssertFalse(t.didChange)
    }

    // MARK: - Polled State Dedup

    func testPolledStateSameReturnsFalse() {
        let t = StateReducer.reduce(
            current: .working,
            event: .polledState(status: .working),
            source: .tmuxPolling
        )
        XCTAssertEqual(t.to, .working)
        XCTAssertFalse(t.didChange)
    }

    func testPolledStateDifferentReturnsTrue() {
        let t = StateReducer.reduce(
            current: .working,
            event: .polledState(status: .done),
            source: .tmuxPolling
        )
        XCTAssertEqual(t.to, .done)
        XCTAssertTrue(t.didChange)
    }

    // MARK: - UserAcknowledged only affects done

    func testUserAcknowledgedFromWorkingIsNoOp() {
        let t = StateReducer.reduce(
            current: .working,
            event: .userAcknowledged,
            source: .userAction
        )
        XCTAssertEqual(t.to, .working)
        XCTAssertFalse(t.didChange)
    }

    func testUserAcknowledgedFromIdleIsNoOp() {
        let t = StateReducer.reduce(
            current: .idle,
            event: .userAcknowledged,
            source: .userAction
        )
        XCTAssertEqual(t.to, .idle)
        XCTAssertFalse(t.didChange)
    }

    // MARK: - PreToolUse Transitions

    func testPreToolUseAskUserQuestionTransitionsToWaiting() {
        let t = StateReducer.reduce(
            current: .idle,
            event: .preToolUse(tool: "AskUserQuestion", summary: "Which option?", timestamp: now),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .waitingForInput)
        XCTAssertTrue(t.didChange)
    }

    func testPreToolUseReadTransitionsToWorking() {
        let t = StateReducer.reduce(
            current: .idle,
            event: .preToolUse(tool: "Read", summary: "Read main.swift", timestamp: now),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .working)
        XCTAssertTrue(t.didChange)
    }

    func testPreToolUseBashFromWorkingIsNoChange() {
        let t = StateReducer.reduce(
            current: .working,
            event: .preToolUse(tool: "Bash", summary: "Ran: npm test", timestamp: now),
            source: .eventWatcher
        )
        XCTAssertEqual(t.to, .working)
        XCTAssertFalse(t.didChange)
    }

    // MARK: - Staleness only affects working

    func testStalenessCheckOnIdleIsNoOp() {
        let t = StateReducer.reduce(
            current: .idle,
            event: .stalenessCheck(elapsed: 999),
            source: .stalenessRefresh
        )
        XCTAssertEqual(t.to, .idle)
        XCTAssertFalse(t.didChange)
    }

    func testStalenessCheckOnDoneIsNoOp() {
        let t = StateReducer.reduce(
            current: .done,
            event: .stalenessCheck(elapsed: 999),
            source: .stalenessRefresh
        )
        XCTAssertEqual(t.to, .done)
        XCTAssertFalse(t.didChange)
    }
}
