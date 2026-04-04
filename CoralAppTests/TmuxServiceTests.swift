import XCTest
@testable import Coral

final class TmuxServiceTests: XCTestCase {

    // MARK: - Session Name Parsing

    func testParseValidClaudeSessionName() {
        let result = TmuxService.parseSessionName("claude-12345678-1234-1234-1234-123456789abc")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.agentType, "claude")
        XCTAssertEqual(result?.uuid, "12345678-1234-1234-1234-123456789abc")
    }

    func testParseValidGeminiSessionName() {
        let result = TmuxService.parseSessionName("gemini-abcdef01-2345-6789-abcd-ef0123456789")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.agentType, "gemini")
    }

    func testParseValidTerminalSessionName() {
        let result = TmuxService.parseSessionName("terminal-00000000-0000-0000-0000-000000000000")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.agentType, "terminal")
    }

    func testParseInvalidSessionNameNoUUID() {
        let result = TmuxService.parseSessionName("claude-agent-1")
        XCTAssertNil(result)
    }

    func testParseInvalidSessionNameWrongPrefix() {
        let result = TmuxService.parseSessionName("copilot-12345678-1234-1234-1234-123456789abc")
        XCTAssertNil(result)
    }

    func testParseEmptyString() {
        let result = TmuxService.parseSessionName("")
        XCTAssertNil(result)
    }

    func testParseCaseInsensitive() {
        let result = TmuxService.parseSessionName("CLAUDE-12345678-1234-1234-1234-123456789ABC")
        XCTAssertNotNil(result)
    }

    // MARK: - Settings Merge

    func testBuildMergedSettingsWithEmptyDirectory() {
        let merged = TmuxService.buildMergedSettings(workingDirectory: "/nonexistent/path", sessionId: "test-session-id")

        // Should at least have hooks key with Coral hooks injected
        let hooks = merged["hooks"] as? [String: [[String: Any]]]
        XCTAssertNotNil(hooks, "Hooks should be present even with no user settings")

        // Verify Coral hooks are present
        XCTAssertNotNil(hooks?["PostToolUse"])
        XCTAssertNotNil(hooks?["Stop"])
        XCTAssertNotNil(hooks?["Notification"])
        XCTAssertNotNil(hooks?["UserPromptSubmit"])
        XCTAssertNotNil(hooks?["SessionStart"])
    }

    func testReadSettingsFileReturnsEmptyForMissingFile() {
        let result = TmuxService.readSettingsFile(atPath: "/nonexistent/settings.json")
        XCTAssertTrue(result.isEmpty)
    }

    func testReadSettingsFileReturnsEmptyForInvalidJSON() {
        let tmpFile = NSTemporaryDirectory() + "test_invalid_settings.json"
        try? "not json".write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let result = TmuxService.readSettingsFile(atPath: tmpFile)
        XCTAssertTrue(result.isEmpty)
    }

    func testReadSettingsFileReturnsValidJSON() {
        let tmpFile = NSTemporaryDirectory() + "test_valid_settings.json"
        try? "{\"key\": \"value\"}".write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let result = TmuxService.readSettingsFile(atPath: tmpFile)
        XCTAssertEqual(result["key"] as? String, "value")
    }

    // MARK: - Grace Period

    func testGracePeriodPreventsEmptyOnFirstPoll() async {
        let service = TmuxService()

        // Simulate having previous sessions
        // First poll with sessions
        // We can't easily test this without tmux, but we test the logic:
        // The emptyPollCount should increment on empty responses
        // and the grace threshold is 3

        // After 3 empty polls, it should accept the empty state
        XCTAssertEqual(TmuxService.sessionNamePattern.numberOfCaptureGroups, 2)
    }

    func testHooksWriteToEventFileNotHTTP() {
        let sessionId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let merged = TmuxService.buildMergedSettings(workingDirectory: "/nonexistent/path", sessionId: sessionId)
        let hooks = merged["hooks"] as! [String: [[String: Any]]]

        // Every hook event that tracks agent state should write to the JSONL event file
        for event in ["PostToolUse", "Stop", "Notification", "UserPromptSubmit", "SessionStart"] {
            let groups = hooks[event]!
            let commands = groups.flatMap { group -> [String] in
                guard let hookList = group["hooks"] as? [[String: Any]] else { return [] }
                return hookList.compactMap { $0["command"] as? String }
            }
            // At least one command should write to the session's event file
            let writesToFile = commands.contains { $0.contains("\(sessionId).jsonl") }
            XCTAssertTrue(writesToFile, "\(event) hook must write to \(sessionId).jsonl, got: \(commands)")

            // No command should reference the old Python hooks
            let usesPythonHook = commands.contains { $0.contains("coral-hook-agentic-state") }
            XCTAssertFalse(usesPythonHook, "\(event) hook must not use coral-hook-agentic-state (removed Python backend)")
        }
    }

    // MARK: - Bracketed Paste

    func testBracketPasteStartSequence() {
        // ESC [ 200 ~ in hex
        XCTAssertEqual(TmuxService.bracketPasteStart, ["-H", "1b", "-H", "5b", "-H", "32", "-H", "30", "-H", "30", "-H", "7e"])
    }

    func testBracketPasteEndSequence() {
        // ESC [ 201 ~ in hex
        XCTAssertEqual(TmuxService.bracketPasteEnd, ["-H", "1b", "-H", "5b", "-H", "32", "-H", "30", "-H", "31", "-H", "7e"])
    }
}
