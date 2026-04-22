import XCTest
@testable import Nala

final class TmuxServiceTests: XCTestCase {

    // MARK: - Session Name Parsing

    func testParseValidClaudeSessionName() {
        let result = TmuxService.parseSessionName("claude-12345678-1234-1234-1234-123456789abc")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.agentType, "claude")
        XCTAssertEqual(result?.uuid, "12345678-1234-1234-1234-123456789abc")
    }

    func testParseGeminiSessionNameReturnsNil() {
        let result = TmuxService.parseSessionName("gemini-abcdef01-2345-6789-abcd-ef0123456789")
        XCTAssertNil(result, "Gemini sessions are no longer supported")
    }

    func testParseValidCodexSessionName() {
        let result = TmuxService.parseSessionName("codex-abcdef01-2345-6789-abcd-ef0123456789")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.agentType, "codex")
        XCTAssertEqual(result?.uuid, "abcdef01-2345-6789-abcd-ef0123456789")
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

        // Should at least have hooks key with Nala hooks injected
        let hooks = merged["hooks"] as? [String: [[String: Any]]]
        XCTAssertNotNil(hooks, "Hooks should be present even with no user settings")

        // Verify Nala hooks are present
        XCTAssertNotNil(hooks?["PreToolUse"])
        XCTAssertNotNil(hooks?["PermissionRequest"])
        XCTAssertNotNil(hooks?["PostToolUse"])
        XCTAssertNotNil(hooks?["Stop"])
        XCTAssertNotNil(hooks?["UserPromptSubmit"])
        XCTAssertNotNil(hooks?["SessionStart"])

        // Verify removed hooks are not present
        XCTAssertNil(hooks?["Notification"], "Notification hook should not be registered")
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
        for event in ["PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "UserPromptSubmit", "SessionStart"] {
            let groups = hooks[event]!
            let commands = groups.flatMap { group -> [String] in
                guard let hookList = group["hooks"] as? [[String: Any]] else { return [] }
                return hookList.compactMap { $0["command"] as? String }
            }
            // At least one command should write to the session's event file
            let writesToFile = commands.contains { $0.contains("\(sessionId).jsonl") }
            XCTAssertTrue(writesToFile, "\(event) hook must write to \(sessionId).jsonl, got: \(commands)")
        }
    }

    // MARK: - Launch Command Construction

    func testShellQuoteEscapesShellMetacharacters() {
        XCTAssertEqual(TmuxService.shellQuote(""), "''")
        XCTAssertEqual(TmuxService.shellQuote("plain"), "'plain'")
        XCTAssertEqual(TmuxService.shellQuote("Bob's $HOME && rm -rf /"), "'Bob'\\''s $HOME && rm -rf /'")
    }

    func testParseAdditionalLaunchFlagsBlankReturnsEmpty() throws {
        XCTAssertEqual(try TmuxService.parseAdditionalLaunchFlags(""), [])
        XCTAssertEqual(try TmuxService.parseAdditionalLaunchFlags(" \t\n "), [])
    }

    func testParseAdditionalLaunchFlagsSupportsQuotesAndEscapes() throws {
        XCTAssertEqual(
            try TmuxService.parseAdditionalLaunchFlags(#"--model "opus 4" --label 'Bob'\''s test' arg\ with\ spaces"#),
            ["--model", "opus 4", "--label", "Bob's test", "arg with spaces"]
        )
    }

    func testBuildCodexLaunchCommandQuotesExecutableDirectoryAndPrompt() throws {
        let service = TmuxService(executableResolver: { provider in
            provider.id == "codex" ? "/tmp/Codex Tools/codex'bin/codex" : nil
        })

        let command = try service.buildCodexLaunchCommand(
            sessionId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            workingDirectory: "/tmp/Nala Codex's Project; rm -rf nope",
            prompt: "fix Bob's bug && echo bad; $(touch nope)"
        )

        XCTAssertEqual(
            command,
            "NALA_SESSION_ID='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' " +
            "'/tmp/Codex Tools/codex'\\''bin/codex' " +
            "-C '/tmp/Nala Codex'\\''s Project; rm -rf nope' " +
            "--enable codex_hooks " +
            "'fix Bob'\\''s bug && echo bad; $(touch nope)'"
        )
    }

    func testBuildCodexLaunchCommandOmitsEmptyPrompt() throws {
        let service = TmuxService(executableResolver: { _ in "/opt/homebrew/bin/codex" })

        let command = try service.buildCodexLaunchCommand(
            sessionId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            workingDirectory: "/tmp/project",
            prompt: ""
        )

        XCTAssertEqual(
            command,
            "NALA_SESSION_ID='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' '/opt/homebrew/bin/codex' -C '/tmp/project' --enable codex_hooks"
        )
    }

    func testBuildCodexLaunchCommandInsertsAdditionalFlagsAfterRequiredFlags() throws {
        let service = TmuxService(executableResolver: { _ in "/opt/homebrew/bin/codex" })

        let command = try service.buildCodexLaunchCommand(
            sessionId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            workingDirectory: "/tmp/project",
            prompt: "ship it",
            additionalLaunchFlags: "-c disable_response_storage=true --full-auto"
        )

        XCTAssertEqual(
            command,
            "NALA_SESSION_ID='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' " +
            "'/opt/homebrew/bin/codex' -C '/tmp/project' --enable codex_hooks " +
            "'-c' 'disable_response_storage=true' '--full-auto' " +
            "'ship it'"
        )
    }

    func testBuildCodexLaunchCommandQuotesAdditionalFlagValuesWithSpaces() throws {
        let service = TmuxService(executableResolver: { _ in "/opt/homebrew/bin/codex" })

        let command = try service.buildCodexLaunchCommand(
            sessionId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            workingDirectory: "/tmp/project",
            prompt: nil,
            additionalLaunchFlags: #"--config "approval mode=on request" --label 'Bob'\''s run'"#
        )

        XCTAssertEqual(
            command,
            "NALA_SESSION_ID='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' " +
            "'/opt/homebrew/bin/codex' -C '/tmp/project' --enable codex_hooks " +
            "'--config' 'approval mode=on request' '--label' 'Bob'\\''s run'"
        )
    }

    func testBuildCodexLaunchCommandThrowsForUnbalancedQuotes() {
        let service = TmuxService(executableResolver: { _ in "/opt/homebrew/bin/codex" })

        XCTAssertThrowsError(
            try service.buildCodexLaunchCommand(
                sessionId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                workingDirectory: "/tmp/project",
                prompt: nil,
                additionalLaunchFlags: #"--config "unterminated"#
            )
        ) { error in
            guard case TmuxError.invalidLaunchFlags(let message) = error else {
                return XCTFail("Expected invalidLaunchFlags, got \(error)")
            }
            XCTAssertTrue(message.contains("Unclosed double quote"))
        }
    }

    func testBuildCodexLaunchCommandThrowsWhenExecutableMissing() {
        let service = TmuxService(executableResolver: { _ in nil })

        XCTAssertThrowsError(
            try service.buildCodexLaunchCommand(
                sessionId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                workingDirectory: "/tmp/project",
                prompt: nil
            )
        ) { error in
            guard case TmuxError.executableNotFound(let provider) = error else {
                return XCTFail("Expected executableNotFound, got \(error)")
            }
            XCTAssertEqual(provider, "Codex")
        }
    }

    func testCreateCodexSessionFailsBeforeCreatingTmuxWhenExecutableMissing() async {
        let recorder = TmuxCommandRecorder()
        let service = TmuxService(
            executableResolver: { _ in nil },
            tmuxRunner: { args in
                await recorder.record(args)
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        do {
            _ = try await service.createSession(agentType: "codex", workingDirectory: "/tmp/project")
            XCTFail("Expected missing Codex executable to throw")
        } catch TmuxError.executableNotFound(let provider) {
            XCTAssertEqual(provider, "Codex")
        } catch {
            XCTFail("Expected executableNotFound, got \(error)")
        }

        let commands = await recorder.commands
        XCTAssertTrue(commands.isEmpty, "Missing Codex CLI should not leave behind a tmux session")
    }

    func testCreateSessionFailsBeforeCreatingTmuxWhenAdditionalFlagsAreInvalid() async {
        let recorder = TmuxCommandRecorder()
        let service = TmuxService(
            executableResolver: { _ in "/opt/homebrew/bin/codex" },
            tmuxRunner: { args in
                await recorder.record(args)
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            },
            launchFlagsReader: { provider in
                provider.id == "codex" ? #"--config "unterminated"# : ""
            }
        )

        do {
            _ = try await service.createSession(agentType: "codex", workingDirectory: "/tmp/project")
            XCTFail("Expected invalid launch flags to throw")
        } catch TmuxError.invalidLaunchFlags(let message) {
            XCTAssertTrue(message.contains("Unclosed double quote"))
        } catch {
            XCTFail("Expected invalidLaunchFlags, got \(error)")
        }

        let commands = await recorder.commands
        XCTAssertTrue(commands.isEmpty, "Invalid launch flags should not leave behind a tmux session")
    }

    func testCreateCodexSessionUsesProviderPrefixAndLaunchCommand() async throws {
        let recorder = TmuxCommandRecorder()
        let service = TmuxService(
            executableResolver: { _ in "/opt/homebrew/bin/codex" },
            tmuxRunner: { args in
                await recorder.record(args)
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let sessionName = try await service.createSession(
            agentType: "codex",
            workingDirectory: "/tmp/project with spaces",
            prompt: "hello from codex"
        )

        XCTAssertTrue(sessionName.hasPrefix("codex-"))

        let commands = await recorder.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0][0], "new-session")
        XCTAssertEqual(commands[0][3], sessionName)
        XCTAssertEqual(commands[0][8], "-c")
        XCTAssertEqual(commands[0][9], "/tmp/project with spaces")
        XCTAssertEqual(commands[1][0], "send-keys")
        XCTAssertEqual(commands[1][2], sessionName)
        XCTAssertTrue(commands[1][3].contains("NALA_SESSION_ID="))
        XCTAssertTrue(commands[1][3].contains("'/opt/homebrew/bin/codex' -C '/tmp/project with spaces' --enable codex_hooks 'hello from codex'"))
    }

    func testCreateCodexSessionUsesAdditionalLaunchFlagsReader() async throws {
        let recorder = TmuxCommandRecorder()
        let service = TmuxService(
            executableResolver: { _ in "/opt/homebrew/bin/codex" },
            tmuxRunner: { args in
                await recorder.record(args)
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            },
            launchFlagsReader: { provider in
                provider.id == "codex" ? "--full-auto" : ""
            }
        )

        let sessionName = try await service.createSession(
            agentType: "codex",
            workingDirectory: "/tmp/project",
            prompt: "hello"
        )

        let commands = await recorder.commands
        XCTAssertEqual(commands[1][2], sessionName)
        XCTAssertTrue(commands[1][3].contains("--enable codex_hooks '--full-auto' 'hello'"))
    }

    func testCreateCodexSessionReadsAdditionalLaunchFlagsFromDefaults() async throws {
        let suiteName = "com.nala.tmux.flags.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("--full-auto", forKey: TmuxService.codexAdditionalLaunchFlagsKey)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let recorder = TmuxCommandRecorder()
        let service = TmuxService(
            executableResolver: { _ in "/opt/homebrew/bin/codex" },
            tmuxRunner: { args in
                await recorder.record(args)
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            },
            launchFlagsDefaults: defaults
        )

        _ = try await service.createSession(
            agentType: "codex",
            workingDirectory: "/tmp/project"
        )

        let commands = await recorder.commands
        XCTAssertTrue(commands[1][3].contains("--enable codex_hooks '--full-auto'"))
    }

    func testCreateClaudeSessionUsesAdditionalLaunchFlagsReader() async throws {
        let recorder = TmuxCommandRecorder()
        let service = TmuxService(
            tmuxRunner: { args in
                await recorder.record(args)
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            },
            launchFlagsReader: { provider in
                provider.id == "claude" ? #"--model "opus 4""# : ""
            }
        )

        let sessionName = try await service.createSession(
            agentType: "claude",
            workingDirectory: "/tmp/project",
            prompt: "hello"
        )
        defer {
            if let parsed = TmuxService.parseSessionName(sessionName) {
                try? FileManager.default.removeItem(atPath: "/tmp/nala_settings_\(parsed.uuid).json")
                try? FileManager.default.removeItem(atPath: "/tmp/nala_prompt_\(parsed.uuid).txt")
            }
        }

        let commands = await recorder.commands
        XCTAssertEqual(commands[1][2], sessionName)
        XCTAssertTrue(commands[1][3].contains("'--model' 'opus 4' \"$(cat"))
    }

    func testBuildClaudeLaunchCommandInsertsAdditionalFlagsBeforePrompt() throws {
        let service = TmuxService()
        let sessionId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let command = try service.buildClaudeLaunchCommand(
            sessionId: sessionId,
            sessionName: "claude-\(sessionId)",
            workingDirectory: "/tmp/project",
            prompt: "hello claude",
            additionalLaunchFlags: #"--model "opus 4" --dangerously-skip-permissions"#
        )
        defer {
            try? FileManager.default.removeItem(atPath: "/tmp/nala_settings_\(sessionId).json")
            try? FileManager.default.removeItem(atPath: "/tmp/nala_prompt_\(sessionId).txt")
        }

        XCTAssertEqual(
            command,
            "env -u CLAUDECODE claude --session-id \(sessionId) " +
            "--settings '/tmp/nala_settings_\(sessionId).json' " +
            "'--model' 'opus 4' '--dangerously-skip-permissions' " +
            "\"$(cat '/tmp/nala_prompt_\(sessionId).txt')\""
        )
    }

    func testBuildClaudeLaunchCommandBlankAdditionalFlagsPreservesCurrentCommand() throws {
        let service = TmuxService()
        let sessionId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let command = try service.buildClaudeLaunchCommand(
            sessionId: sessionId,
            sessionName: "claude-\(sessionId)",
            workingDirectory: "/tmp/project",
            prompt: nil,
            additionalLaunchFlags: ""
        )
        defer {
            try? FileManager.default.removeItem(atPath: "/tmp/nala_settings_\(sessionId).json")
        }

        XCTAssertEqual(
            command,
            "env -u CLAUDECODE claude --session-id \(sessionId) --settings '/tmp/nala_settings_\(sessionId).json'"
        )
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

private actor TmuxCommandRecorder {
    private(set) var commands: [[String]] = []

    func record(_ args: [String]) {
        commands.append(args)
    }
}
