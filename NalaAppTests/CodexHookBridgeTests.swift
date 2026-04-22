import XCTest
@testable import Nala

final class CodexHookBridgeTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nala-codex-hook-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDirectory.path)
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    func testMissingHooksFileCreatesNalaHooks() throws {
        let hooksURL = tempDirectory.appendingPathComponent("hooks.json")
        let bridge = CodexHookBridge(hooksFileURL: hooksURL)

        XCTAssertEqual(bridge.installationStatus(), .missing)
        XCTAssertEqual(try bridge.installOrRepair(), .installed)

        let document = try readDocument(at: hooksURL)
        assertAllNalaHooksPresent(in: document)
        XCTAssertEqual(bridge.installationStatus(), .installed)
    }

    func testInvalidHooksFileFailsClearly() throws {
        let hooksURL = tempDirectory.appendingPathComponent("hooks.json")
        try Data("not json".utf8).write(to: hooksURL)
        let bridge = CodexHookBridge(hooksFileURL: hooksURL)

        XCTAssertThrowsError(try bridge.installOrRepair()) { error in
            XCTAssertEqual(error as? CodexHookBridge.BridgeError, .invalidJSON(hooksURL.path))
        }
    }

    func testMergePreservesUnrelatedHooksAndTopLevelEntries() throws {
        let hooksURL = tempDirectory.appendingPathComponent("hooks.json")
        try writeDocument([
            "custom": "keep-me",
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "echo user-hook",
                            ],
                        ],
                    ],
                ],
                "CustomEvent": [
                    [
                        "matcher": ".*",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "echo custom",
                            ],
                        ],
                    ],
                ],
            ],
        ], to: hooksURL)

        let bridge = CodexHookBridge(hooksFileURL: hooksURL)

        XCTAssertEqual(try bridge.installOrRepair(), .repaired)

        let document = try readDocument(at: hooksURL)
        XCTAssertEqual(document["custom"] as? String, "keep-me")
        XCTAssertTrue(commands(for: "PreToolUse", in: document).contains("echo user-hook"))
        XCTAssertTrue(commands(for: "CustomEvent", in: document).contains("echo custom"))
        assertAllNalaHooksPresent(in: document)
    }

    func testMergeIsIdempotent() throws {
        let hooksURL = tempDirectory.appendingPathComponent("hooks.json")
        let bridge = CodexHookBridge(hooksFileURL: hooksURL)

        XCTAssertEqual(try bridge.installOrRepair(), .installed)
        XCTAssertEqual(try bridge.installOrRepair(), .alreadyInstalled)

        let document = try readDocument(at: hooksURL)
        for event in CodexHookBridge.hookEvents {
            let matchingCommands = commands(for: event, in: document)
                .filter { $0 == CodexHookBridge.nalaHookCommand }
            XCTAssertEqual(matchingCommands.count, 1, "\(event) should contain one Nala hook command")
        }
    }

    func testHookCommandHasSilentNalaSessionGuardAndEventTarget() throws {
        let hooksURL = tempDirectory.appendingPathComponent("hooks.json")
        let bridge = CodexHookBridge(hooksFileURL: hooksURL)
        _ = try bridge.installOrRepair()

        let document = try readDocument(at: hooksURL)
        for event in CodexHookBridge.hookEvents {
            let eventCommands = commands(for: event, in: document)
            XCTAssertTrue(eventCommands.contains(CodexHookBridge.nalaHookCommand))
        }

        XCTAssertTrue(CodexHookBridge.nalaHookCommand.contains(#"[ -z "$NALA_SESSION_ID" ] && exit 0"#))
        XCTAssertTrue(CodexHookBridge.nalaHookCommand.contains("umask 077"))
        XCTAssertTrue(CodexHookBridge.nalaHookCommand.contains(#"~/.nala/events/$NALA_SESSION_ID.jsonl"#))
        XCTAssertFalse(CodexHookBridge.nalaHookCommand.contains("echo \""))
    }

    func testWritePermissionFailureIsReported() throws {
        let readOnlyDirectory = tempDirectory.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: readOnlyDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyDirectory.path)
        }

        let hooksURL = readOnlyDirectory.appendingPathComponent("hooks.json")
        let bridge = CodexHookBridge(hooksFileURL: hooksURL)

        XCTAssertThrowsError(try bridge.installOrRepair()) { error in
            guard case CodexHookBridge.BridgeError.writeFailed = error else {
                return XCTFail("Expected writeFailed, got \(error)")
            }
        }
    }

    func testConcurrentChangeIsReReadAndPreserved() throws {
        let hooksURL = tempDirectory.appendingPathComponent("hooks.json")
        try writeDocument(["hooks": [:]], to: hooksURL)

        var reReadCount = 0
        let bridge = CodexHookBridge(
            hooksFileURL: hooksURL,
            beforeOptimisticReRead: {
                reReadCount += 1
                guard reReadCount == 1 else { return }
                try? self.writeDocument([
                    "hooks": [
                        "Stop": [
                            [
                                "matcher": ".*",
                                "hooks": [
                                    [
                                        "type": "command",
                                        "command": "echo concurrent",
                                    ],
                                ],
                            ],
                        ],
                    ],
                ], to: hooksURL)
            }
        )

        XCTAssertEqual(try bridge.installOrRepair(), .repaired)

        let document = try readDocument(at: hooksURL)
        XCTAssertTrue(commands(for: "Stop", in: document).contains("echo concurrent"))
        assertAllNalaHooksPresent(in: document)
    }

    func testStillRacingConcurrentChangeFails() throws {
        let hooksURL = tempDirectory.appendingPathComponent("hooks.json")
        try writeDocument(["hooks": [:]], to: hooksURL)

        var reReadCount = 0
        let bridge = CodexHookBridge(
            hooksFileURL: hooksURL,
            beforeOptimisticReRead: {
                reReadCount += 1
                guard reReadCount <= 2 else { return }
                try? self.writeDocument([
                    "hooks": [
                        "Stop": [
                            [
                                "matcher": ".*",
                                "hooks": [
                                    [
                                        "type": "command",
                                        "command": "echo concurrent-\(reReadCount)",
                                    ],
                                ],
                            ],
                        ],
                    ],
                ], to: hooksURL)
            }
        )

        XCTAssertThrowsError(try bridge.installOrRepair()) { error in
            XCTAssertEqual(error as? CodexHookBridge.BridgeError, .concurrentModification(hooksURL.path))
        }
    }

    func testDetectFeatureStateParsesCodexHooksFeature() async {
        let bridge = CodexHookBridge(
            hooksFileURL: tempDirectory.appendingPathComponent("hooks.json"),
            executableResolver: { provider in
                provider.id == AgentProvider.codex.id ? "/tmp/codex" : nil
            },
            processRunner: { _, args in
                if args == ["--version"] {
                    return CommandResult(exitCode: 0, stdout: "codex-cli 0.122.0\n", stderr: "")
                }
                if args == ["features", "list"] {
                    return CommandResult(
                        exitCode: 0,
                        stdout: "codex_hooks  under development  false\nother stable true\n",
                        stderr: ""
                    )
                }
                return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
            }
        )

        let state = await bridge.detectFeatureState()

        XCTAssertEqual(state.version, "codex-cli 0.122.0")
        XCTAssertTrue(state.hooksFeatureListed)
        XCTAssertEqual(state.hooksEnabledByDefault, false)
        XCTAssertEqual(state.errorMessage, nil)
    }

    // MARK: - Helpers

    private func readDocument(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func writeDocument(_ document: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func commands(for event: String, in document: [String: Any]) -> [String] {
        guard let hooks = document["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]] else {
            return []
        }

        return groups.flatMap { group -> [String] in
            guard let hookCommands = group["hooks"] as? [[String: Any]] else { return [] }
            return hookCommands.compactMap { $0["command"] as? String }
        }
    }

    private func assertAllNalaHooksPresent(in document: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        for event in CodexHookBridge.hookEvents {
            XCTAssertTrue(
                commands(for: event, in: document).contains(CodexHookBridge.nalaHookCommand),
                "\(event) missing Nala hook command",
                file: file,
                line: line
            )
        }
    }
}
