import SwiftUI
import XCTest
@testable import Nala

final class AgentProviderTests: XCTestCase {
    func testLookupKnownProviders() {
        XCTAssertEqual(AgentProvider.provider(for: "claude").id, "claude")
        XCTAssertEqual(AgentProvider.provider(for: "codex").id, "codex")
        XCTAssertEqual(AgentProvider.provider(for: "terminal").id, "terminal")
    }

    func testLookupUnknownProviderFallsBackToGenericAgent() {
        let provider = AgentProvider.provider(for: "gemini")

        XCTAssertEqual(provider.id, "gemini")
        XCTAssertEqual(provider.displayName, "Gemini")
        XCTAssertEqual(provider.fallbackDisplayLabel, "Agent")
        XCTAssertEqual(provider.defaultCommands, [])
        XCTAssertFalse(provider.supportsEventTracking)
        XCTAssertFalse(provider.supportsAutoNaming)
    }

    func testProviderLabelsAndPrefixes() {
        XCTAssertEqual(AgentProvider.claude.displayName, "Claude")
        XCTAssertEqual(AgentProvider.claude.sessionPrefix, "claude")
        XCTAssertEqual(AgentProvider.codex.displayName, "Codex")
        XCTAssertEqual(AgentProvider.codex.sessionPrefix, "codex")
        XCTAssertEqual(AgentProvider.terminal.displayName, "Terminal")
        XCTAssertEqual(AgentProvider.terminal.sessionPrefix, "terminal")
    }

    func testClaudeDefaultCommandsUnchanged() {
        XCTAssertEqual(
            AgentProvider.claude.defaultCommands,
            [
                SessionCommand(name: "compact", description: "Compress conversation history"),
                SessionCommand(name: "clear", description: "Clear conversation and start fresh"),
                SessionCommand(name: "review", description: "Review code changes"),
                SessionCommand(name: "cost", description: "Show token usage and cost"),
                SessionCommand(name: "diff", description: "View changes made in session"),
            ]
        )
    }

    func testTerminalAndCodexHaveNoDefaultAgentCommands() {
        XCTAssertEqual(AgentProvider.terminal.defaultCommands, [])
        XCTAssertEqual(AgentProvider.codex.defaultCommands, [])
    }

    func testCodexBadgeColorIsOpenAIGreen() {
        assertColor(AgentProvider.codex.badgeColor, equals: NalaTheme.openaiGreen)
    }

    func testClaudeBadgeColorIsClaudeOrange() {
        assertColor(AgentProvider.claude.badgeColor, equals: NalaTheme.claudeOrange)
    }

    func testProviderExecutableCandidates() {
        XCTAssertEqual(AgentProvider.claude.executableCandidates, ["claude"])
        XCTAssertEqual(
            AgentProvider.codex.executableCandidates,
            ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex", "codex"]
        )
        XCTAssertEqual(AgentProvider.terminal.executableCandidates, [])
    }

    func testEventTrackingCapability() {
        XCTAssertTrue(AgentProvider.claude.supportsEventTracking)
        XCTAssertTrue(AgentProvider.codex.supportsEventTracking)
        XCTAssertFalse(AgentProvider.terminal.supportsEventTracking)
    }

    func testAutoNamingCapabilityIsClaudeOnly() {
        XCTAssertTrue(AgentProvider.claude.supportsAutoNaming)
        XCTAssertFalse(AgentProvider.codex.supportsAutoNaming)
        XCTAssertFalse(AgentProvider.terminal.supportsAutoNaming)
    }

    private func assertColor(
        _ actual: Color,
        equals expected: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualColor = NSColor(actual)
        let expectedColor = NSColor(expected)

        XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.001, file: file, line: line)
    }
}
