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
        XCTAssertEqual(EventFileWatcher.stalenessThreshold, 360, "Staleness threshold should be 6 minutes")
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

    // MARK: - Batched Event Emission (Regression: intermediate states dropped)

    /// Thread-safe update collector for async stream tests.
    private class UpdateCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _updates: [AgentState] = []

        func append(_ state: AgentState) {
            lock.lock()
            _updates.append(state)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return _updates.count
        }

        var updates: [AgentState] {
            lock.lock()
            defer { lock.unlock() }
            return _updates
        }
    }

    /// Verifies that when prompt_submit + stop arrive in one batch, both
    /// the intermediate working state and the final done state are emitted
    /// as separate updates through the AsyncStream.
    func testProcessEventsBatchedPromptSubmitThenStop() {
        let watcher = EventFileWatcher()
        let sessionId = UUID().uuidString.lowercased()
        let path = "\(EventFileWatcher.eventsDirectory)/\(sessionId).jsonl"

        try? FileManager.default.createDirectory(
            atPath: EventFileWatcher.eventsDirectory,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])

        // Thread-safe collector; expectation fires after 3 updates (initial + 2 events)
        let collector = UpdateCollector()
        let gotAllUpdates = expectation(description: "Got initial + 2 batched event updates")
        gotAllUpdates.expectedFulfillmentCount = 3

        let stream = watcher.updates()
        let collectTask = Task {
            for await update in stream {
                collector.append(update.state)
                gotAllUpdates.fulfill()
            }
        }

        watcher.startWatching(sessionId: sessionId)

        // Delay to ensure the stream consumer processes the initial empty state
        let writeDelay = expectation(description: "write delay")
        writeDelay.isInverted = true
        wait(for: [writeDelay], timeout: 0.3)

        // Use recent timestamps so the staleness check doesn't override working→stuck
        let now = ISO8601DateFormatter().string(from: Date())
        let promptJson = #"{"hook_event_name":"UserPromptSubmit","prompt":"fix bug","timestamp":""# + now + #""}"#
        let stopJson = #"{"hook_event_name":"Stop","stop_hook_active":true,"reason":"end_turn","timestamp":""# + now + #""}"#
        let batch = "\(promptJson)\n\(stopJson)\n"

        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile()
        fh.write(batch.data(using: .utf8)!)
        fh.closeFile()

        wait(for: [gotAllUpdates], timeout: 5.0)
        collectTask.cancel()
        watcher.stopWatching(sessionId: sessionId)
        try? FileManager.default.removeItem(atPath: path)

        let all = collector.updates
        // Expect: [initial(empty), working(prompt_submit), done(stop)]
        XCTAssertGreaterThanOrEqual(all.count, 3,
            "Per-event emission should produce initial + 2 event updates")
        // First is initial empty state
        XCTAssertFalse(all[0].working, "Initial state should not be working")
        XCTAssertFalse(all[0].done, "Initial state should not be done")
        // Second is intermediate working from prompt_submit
        XCTAssertTrue(all[1].working,
            "Second update should be working (from prompt_submit)")
        // Third is done from stop
        XCTAssertTrue(all[2].done,
            "Third update should be done (from stop)")
    }

    /// Verifies that when notification + stop arrive in one batch, both
    /// the intermediate waitingForInput state and the final done state are emitted.
    func testProcessEventsBatchedNotificationThenStop() {
        let watcher = EventFileWatcher()
        let sessionId = UUID().uuidString.lowercased()
        let path = "\(EventFileWatcher.eventsDirectory)/\(sessionId).jsonl"

        try? FileManager.default.createDirectory(
            atPath: EventFileWatcher.eventsDirectory,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])

        let collector = UpdateCollector()
        let gotAllUpdates = expectation(description: "Got initial + 2 batched event updates")
        gotAllUpdates.expectedFulfillmentCount = 3

        let stream = watcher.updates()
        let collectTask = Task {
            for await update in stream {
                collector.append(update.state)
                gotAllUpdates.fulfill()
            }
        }

        watcher.startWatching(sessionId: sessionId)

        let writeDelay = expectation(description: "write delay")
        writeDelay.isInverted = true
        wait(for: [writeDelay], timeout: 0.3)

        // Use recent timestamps so staleness checks don't interfere
        let now = ISO8601DateFormatter().string(from: Date())
        let notifJson = #"{"hook_event_name":"Notification","message":"Permission required","timestamp":""# + now + #""}"#
        let stopJson = #"{"hook_event_name":"Stop","stop_hook_active":true,"reason":"end_turn","timestamp":""# + now + #""}"#
        let batch = "\(notifJson)\n\(stopJson)\n"

        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile()
        fh.write(batch.data(using: .utf8)!)
        fh.closeFile()

        wait(for: [gotAllUpdates], timeout: 5.0)
        collectTask.cancel()
        watcher.stopWatching(sessionId: sessionId)
        try? FileManager.default.removeItem(atPath: path)

        let all = collector.updates
        XCTAssertGreaterThanOrEqual(all.count, 3,
            "Per-event emission should produce initial + 2 event updates")
        XCTAssertFalse(all[0].working, "Initial state should not be working")
        XCTAssertFalse(all[0].done, "Initial state should not be done")
        XCTAssertTrue(all[1].waitingForInput,
            "Second update should be waitingForInput (from notification)")
        XCTAssertTrue(all[2].done,
            "Third update should be done (from stop)")
    }

    // MARK: - Tail Recovery (Regression: main-thread hang from full file reads)

    /// Verifies that startWatching recovers the correct agent state from the tail
    /// of a large event file, without reading the entire file. This prevents
    /// multi-second UI hangs when event files grow to megabytes.
    func testStartWatchingRecoversStateFromLargeFile() {
        let watcher = EventFileWatcher()
        let sessionId = UUID().uuidString.lowercased()
        let path = "\(EventFileWatcher.eventsDirectory)/\(sessionId).jsonl"

        // Build a large event file: many old events followed by a final "stop"
        var lines: [String] = []
        for i in 0..<2000 {
            let event: [String: Any] = [
                "hook_event_name": "PostToolUse",
                "tool_name": "Read",
                "tool_input": ["file_path": "/tmp/file_\(i).swift"],
                "timestamp": "2026-01-01T00:00:00Z"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: event),
               let str = String(data: data, encoding: .utf8) {
                lines.append(str)
            }
        }
        // Final event: agent stopped (done)
        let stopEvent: [String: Any] = [
            "hook_event_name": "Stop",
            "stop_hook_active": true,
            "reason": "end_turn",
            "timestamp": "2026-01-01T01:00:00Z"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: stopEvent),
           let str = String(data: data, encoding: .utf8) {
            lines.append(str)
        }

        let content = lines.joined(separator: "\n") + "\n"
        let contentData = content.data(using: .utf8)!
        // Ensure file is large enough that tail recovery reads a subset
        XCTAssertGreaterThan(contentData.count, 256 * 1024,
            "Test file should exceed 256KB to exercise tail recovery")

        try? FileManager.default.createDirectory(
            atPath: EventFileWatcher.eventsDirectory,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: contentData, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(atPath: path) }

        watcher.startWatching(sessionId: sessionId)
        defer { watcher.stopWatching(sessionId: sessionId) }

        // State should reflect the final "stop" event (done = true)
        let state = watcher.cachedState(for: sessionId)
        XCTAssertNotNil(state, "State should be recovered from event file tail")
        XCTAssertTrue(state?.done ?? false, "Final stop event should set done = true")
        XCTAssertFalse(state?.working ?? true, "Done agent should not be working")
    }
}
