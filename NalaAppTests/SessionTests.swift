import XCTest
@testable import Nala

final class SessionTests: XCTestCase {

    // MARK: - Status Enum

    func testDefaultStatusIsIdle() {
        let session = makeSession()
        XCTAssertEqual(session.status, .idle)
    }

    func testStatusFromExplicitParameter() {
        let session = makeSession(status: .working)
        XCTAssertEqual(session.status, .working)
    }

    func testAllStatusValues() {
        for status in [AgentStatus.idle, .working, .done, .stuck, .sleeping, .waitingForInput] {
            let session = makeSession(status: status)
            XCTAssertEqual(session.status, status)
        }
    }

    // MARK: - Computed Properties

    func testIdUsesSessionIdWhenPresent() {
        let session = makeSession(name: "fallback", sessionId: "real-id")
        XCTAssertEqual(session.id, "real-id")
    }

    func testIdFallsBackToNameWhenSessionIdEmpty() {
        let session = makeSession(name: "fallback", sessionId: "")
        XCTAssertEqual(session.id, "fallback")
    }

    func testDisplayLabelUsesDisplayName() {
        let session = makeSession(displayName: "My Agent", boardJobTitle: "Dev")
        XCTAssertEqual(session.displayLabel, "My Agent")
    }

    func testDisplayLabelFallsToJobTitle() {
        let session = makeSession(displayName: nil, boardJobTitle: "Backend Dev")
        XCTAssertEqual(session.displayLabel, "Backend Dev")
    }

    func testDisplayLabelFallsToAgentForClaude() {
        let session = makeSession(agentType: "claude", displayName: nil, boardJobTitle: nil)
        XCTAssertEqual(session.displayLabel, "Agent")
    }

    func testDisplayLabelFallsToTerminalForTerminalType() {
        let session = makeSession(agentType: "terminal", displayName: nil, boardJobTitle: nil)
        XCTAssertEqual(session.displayLabel, "Terminal")
    }

    func testDisplayLabelSkipsEmptyDisplayName() {
        let session = makeSession(displayName: "", boardJobTitle: "Dev")
        XCTAssertEqual(session.displayLabel, "Dev")
    }

    func testDisplayLabelSkipsEmptyJobTitle() {
        let session = makeSession(displayName: nil, boardJobTitle: "")
        XCTAssertEqual(session.displayLabel, "Agent")
    }

    // MARK: - effectiveSubtitle (switch on status)

    func testEffectiveSubtitleDone() {
        let session = makeSession(status: .done)
        XCTAssertEqual(session.effectiveSubtitle, "Completed")
    }

    func testEffectiveSubtitleStuckWithReason() {
        let session = makeSession(status: .stuck, waitingReason: "Network timeout")
        XCTAssertEqual(session.effectiveSubtitle, "Network timeout")
    }

    func testEffectiveSubtitleStuckWithoutReason() {
        let session = makeSession(status: .stuck)
        XCTAssertEqual(session.effectiveSubtitle, "Stuck")
    }

    func testEffectiveSubtitleWaitingWithSummary() {
        let session = makeSession(status: .waitingForInput, waitingSummary: "Need API key")
        XCTAssertEqual(session.effectiveSubtitle, "Need API key")
    }

    func testEffectiveSubtitleWaitingWithoutSummary() {
        let session = makeSession(status: .waitingForInput)
        XCTAssertEqual(session.effectiveSubtitle, "Waiting for input")
    }

    func testEffectiveSubtitleSleeping() {
        let session = makeSession(status: .sleeping)
        XCTAssertEqual(session.effectiveSubtitle, "Sleeping")
    }

    func testEffectiveSubtitleWorkingWithEvent() {
        let session = makeSession(status: .working, latestEventSummary: "Read main.swift")
        XCTAssertEqual(session.effectiveSubtitle, "Read main.swift")
    }

    func testEffectiveSubtitleIdleNil() {
        let session = makeSession(status: .idle)
        XCTAssertNil(session.effectiveSubtitle)
    }

    // MARK: - SessionCommand

    func testSessionCommandRoundTrip() throws {
        let cmd = SessionCommand(name: "build", description: "Build the project")
        let data = try JSONEncoder().encode(cmd)
        let decoded = try JSONDecoder().decode(SessionCommand.self, from: data)
        XCTAssertEqual(decoded, cmd)
    }
}
