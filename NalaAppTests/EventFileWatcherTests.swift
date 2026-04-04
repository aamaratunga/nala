import XCTest
@testable import Nala

final class EventFileWatcherTests: XCTestCase {

    // MARK: - Event Parsing

    func testParseToolUseEvent() {
        let json: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "Read",
            "tool_input": ["file_path": "/tmp/test.swift"]
        ]

        let result = EventFileWatcher.parseHookEvent(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.eventType, "tool_use")
        XCTAssertEqual(result?.summary, "Read test.swift")
    }

    func testParseStopEvent() {
        let json: [String: Any] = [
            "hook_event_name": "Stop",
            "stop_hook_active": true,
            "reason": "end_turn"
        ]

        let result = EventFileWatcher.parseHookEvent(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.eventType, "stop")
        XCTAssertTrue(result?.summary.contains("end_turn") ?? false)
    }

    func testParseNotificationEvent() {
        let json: [String: Any] = [
            "hook_event_name": "Notification",
            "message": "Permission required for file write"
        ]

        let result = EventFileWatcher.parseHookEvent(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.eventType, "notification")
        XCTAssertTrue(result?.summary.contains("Permission required") ?? false)
    }

    func testParseWaitingForInputAsStop() {
        let json: [String: Any] = [
            "hook_event_name": "Notification",
            "message": "Agent is waiting for your input"
        ]

        let result = EventFileWatcher.parseHookEvent(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.eventType, "stop", "'waiting for your input' should be treated as stop")
    }

    func testParsePromptSubmitEvent() {
        let json: [String: Any] = [
            "hook_event_name": "UserPromptSubmit",
            "prompt": "Fix the bug"
        ]

        let result = EventFileWatcher.parseHookEvent(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.eventType, "prompt_submit")
    }

    func testParseSessionResetEvent() {
        let json: [String: Any] = [
            "hook_event_name": "SessionStart"
        ]

        let result = EventFileWatcher.parseHookEvent(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.eventType, "session_reset")
    }

    func testParseUnknownEventReturnsNil() {
        let json: [String: Any] = [
            "some_unknown_field": "value"
        ]

        let result = EventFileWatcher.parseHookEvent(json)
        XCTAssertNil(result)
    }

    func testParseBashToolSummary() {
        let json: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "npm test -- --coverage"]
        ]

        let result = EventFileWatcher.parseHookEvent(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.summary, "Ran: npm test -- --coverage")
    }

    func testParseLongBashCommandTruncates() {
        let longCommand = String(repeating: "x", count: 200)
        let json: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": longCommand]
        ]

        let result = EventFileWatcher.parseHookEvent(json)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.summary.count < 100, "Long commands should be truncated")
        XCTAssertTrue(result!.summary.hasSuffix("..."))
    }

    // MARK: - State Derivation

    func testToolUseDerivesWorkingState() {
        // Tool use events should set working = true
        let json: [String: Any] = [
            "tool_name": "Edit",
            "tool_input": ["file_path": "/tmp/test.swift"]
        ]

        let result = EventFileWatcher.parseHookEvent(json)
        XCTAssertEqual(result?.eventType, "tool_use")
        // State derivation is internal to EventFileWatcher, but we verify the event type
        // would trigger working=true in the state machine
    }

    func testSleepDetection() {
        // "Ran: sleep" summary should trigger sleeping state
        let json: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "sleep 60"]
        ]

        let result = EventFileWatcher.parseHookEvent(json)
        XCTAssertTrue(result?.summary.hasPrefix("Ran: sleep") ?? false)
    }

    // MARK: - Events Directory

    func testEventsDirectoryPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(EventFileWatcher.eventsDirectory, "\(home)/.nala/events")
    }

    func testStalenessThreshold() {
        XCTAssertEqual(EventFileWatcher.stalenessThreshold, 420, "Staleness threshold should be 7 minutes")
    }

    // MARK: - Concatenated JSON Splitting

    func testSplitConcatenatedJSON() {
        // Simulates hook events written without newlines (the root cause of grey dots)
        let concatenated = """
        {"hook_event_name":"UserPromptSubmit","prompt":"fix bug"}{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/a.swift"}}{"hook_event_name":"Stop","reason":"end_turn"}
        """

        let objects = EventFileWatcher.splitConcatenatedJSON(concatenated)
        XCTAssertEqual(objects.count, 3)
        XCTAssertEqual(objects[0]["hook_event_name"] as? String, "UserPromptSubmit")
        XCTAssertEqual(objects[1]["tool_name"] as? String, "Read")
        XCTAssertEqual(objects[2]["hook_event_name"] as? String, "Stop")
    }

    func testSplitConcatenatedJSONWithNestedBraces() {
        // Ensure nested braces in tool_input don't break the splitter
        let concatenated = """
        {"tool_name":"Bash","tool_input":{"command":"echo {hello}"}}{"hook_event_name":"Stop","reason":"done"}
        """

        let objects = EventFileWatcher.splitConcatenatedJSON(concatenated)
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects[0]["tool_name"] as? String, "Bash")
        XCTAssertEqual(objects[1]["hook_event_name"] as? String, "Stop")
    }

    func testSplitConcatenatedJSONWithBracesInStrings() {
        // Braces inside JSON string values should not be treated as object boundaries
        let concatenated = """
        {"tool_name":"Bash","tool_input":{"command":"echo }{"},"other":"val"}{"hook_event_name":"Stop","reason":"x"}
        """

        let objects = EventFileWatcher.splitConcatenatedJSON(concatenated)
        XCTAssertEqual(objects.count, 2, "Braces inside strings should be ignored")
    }

    func testSplitSingleObject() {
        let single = #"{"hook_event_name":"Stop","reason":"end_turn"}"#
        let objects = EventFileWatcher.splitConcatenatedJSON(single)
        XCTAssertEqual(objects.count, 1)
    }

    func testSplitEmptyString() {
        let objects = EventFileWatcher.splitConcatenatedJSON("")
        XCTAssertEqual(objects.count, 0)
    }
}
