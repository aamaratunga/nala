import XCTest
@testable import Coral

final class SessionTests: XCTestCase {

    // MARK: - JSON Decoding

    func testDecodeFullPayload() throws {
        let data = Data(fullSessionJSON.utf8)
        let session = try coralJSONDecoder.decode(Session.self, from: data)

        XCTAssertEqual(session.name, "claude-agent-1")
        XCTAssertEqual(session.agentType, "claude")
        XCTAssertEqual(session.sessionId, "abc123")
        XCTAssertEqual(session.tmuxSession, "tmux-claude-1")
        XCTAssertEqual(session.status, "Implementing feature")
        XCTAssertEqual(session.summary, "Adding unit tests")
        XCTAssertEqual(session.stalenessSeconds, 42.5)
        XCTAssertEqual(session.branch, "feature/tests")
        XCTAssertEqual(session.displayName, "Test Agent")
        XCTAssertEqual(session.icon, "beaker")
        XCTAssertEqual(session.workingDirectory, "/Users/dev/project")
        XCTAssertFalse(session.waitingForInput)
        XCTAssertFalse(session.done)
        XCTAssertTrue(session.working)
        XCTAssertFalse(session.stuck)
        XCTAssertNil(session.waitingReason)
        XCTAssertNil(session.waitingSummary)
        XCTAssertEqual(session.changedFileCount, 3)
        XCTAssertEqual(session.boardProject, "myboard")
        XCTAssertEqual(session.boardJobTitle, "Backend Dev")
        XCTAssertEqual(session.boardUnread, 2)
        XCTAssertEqual(session.commands.count, 1)
        XCTAssertEqual(session.commands.first?.name, "test")
        XCTAssertEqual(session.logPath, "/tmp/claude_coral_project.log")
    }

    func testDecodeMinimalPayload() throws {
        let data = Data(minimalSessionJSON.utf8)
        let session = try coralJSONDecoder.decode(Session.self, from: data)

        XCTAssertEqual(session.name, "bare-agent")
        // All optional/defaulted fields should have their defaults
        XCTAssertEqual(session.agentType, "claude")
        XCTAssertEqual(session.sessionId, "")
        XCTAssertEqual(session.tmuxSession, "")
        XCTAssertNil(session.status)
        XCTAssertNil(session.summary)
        XCTAssertNil(session.stalenessSeconds)
        XCTAssertNil(session.branch)
        XCTAssertNil(session.displayName)
        XCTAssertNil(session.icon)
        XCTAssertEqual(session.workingDirectory, "")
        XCTAssertFalse(session.waitingForInput)
        XCTAssertFalse(session.done)
        XCTAssertFalse(session.working)
        XCTAssertFalse(session.stuck)
        XCTAssertNil(session.waitingReason)
        XCTAssertNil(session.waitingSummary)
        XCTAssertEqual(session.changedFileCount, 0)
        XCTAssertNil(session.boardProject)
        XCTAssertNil(session.boardJobTitle)
        XCTAssertEqual(session.boardUnread, 0)
        XCTAssertTrue(session.commands.isEmpty)
        XCTAssertEqual(session.logPath, "")
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

    // MARK: - SessionCommand

    func testSessionCommandRoundTrip() throws {
        let cmd = SessionCommand(name: "build", description: "Build the project")
        let data = try JSONEncoder().encode(cmd)
        let decoded = try JSONDecoder().decode(SessionCommand.self, from: data)
        XCTAssertEqual(decoded, cmd)
    }
}
