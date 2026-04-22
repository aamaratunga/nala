import SwiftUI
import XCTest
@testable import Nala

final class PaletteModeTests: XCTestCase {

    // MARK: - Labels

    func testSwitchSessionLabel() {
        XCTAssertEqual(PaletteMode.switchSession.label, "Switch")
    }

    func testNewAgentLabel() {
        XCTAssertEqual(PaletteMode.newAgent.label, "New Claude")
    }

    func testNewCodexAgentLabel() {
        XCTAssertEqual(PaletteMode.newCodexAgent.label, "New Codex")
    }

    func testNewTerminalLabel() {
        XCTAssertEqual(PaletteMode.newTerminal.label, "New Terminal")
    }

    func testNewWorktreeLabel() {
        XCTAssertEqual(PaletteMode.newWorktree.label, "New Worktree")
    }

    func testBrowsePathLabel() {
        XCTAssertEqual(PaletteMode.browsePath(origin: .newAgent).label, "Browse")
    }

    func testLaunchModeChipColors() {
        assertColor(PaletteMode.newAgent.chipColor, equals: NalaTheme.claudeOrange)
        assertColor(PaletteMode.newCodexAgent.chipColor, equals: NalaTheme.openaiGreen)
    }

    // MARK: - Search Placeholders

    func testSwitchSessionPlaceholder() {
        XCTAssertEqual(PaletteMode.switchSession.searchPlaceholder, "Search sessions...")
    }

    func testNewAgentPlaceholder() {
        XCTAssertEqual(PaletteMode.newAgent.searchPlaceholder, "Select folder...")
    }

    func testNewCodexAgentPlaceholder() {
        XCTAssertEqual(PaletteMode.newCodexAgent.searchPlaceholder, "Select folder...")
    }

    func testNewTerminalPlaceholder() {
        XCTAssertEqual(PaletteMode.newTerminal.searchPlaceholder, "Select folder...")
    }

    func testNewWorktreePlaceholder() {
        XCTAssertEqual(PaletteMode.newWorktree.searchPlaceholder, "Search repos...")
    }

    func testBrowsePathPlaceholder() {
        XCTAssertEqual(PaletteMode.browsePath(origin: .newAgent).searchPlaceholder, "Type a path...")
    }

    // MARK: - Equatable

    func testBrowsePathEquatableSameOrigin() {
        XCTAssertEqual(
            PaletteMode.browsePath(origin: .newAgent),
            PaletteMode.browsePath(origin: .newAgent)
        )
    }

    func testBrowsePathEquatableDifferentOrigin() {
        XCTAssertNotEqual(
            PaletteMode.browsePath(origin: .newAgent),
            PaletteMode.browsePath(origin: .newTerminal)
        )
    }

    func testBrowsePathEquatableCodexOrigin() {
        XCTAssertEqual(
            PaletteMode.browsePath(origin: .newCodexAgent),
            PaletteMode.browsePath(origin: .newCodexAgent)
        )
        XCTAssertNotEqual(
            PaletteMode.browsePath(origin: .newCodexAgent),
            PaletteMode.browsePath(origin: .newAgent)
        )
    }

    func testDifferentModesNotEqual() {
        XCTAssertNotEqual(PaletteMode.newAgent, PaletteMode.newTerminal)
        XCTAssertNotEqual(PaletteMode.newAgent, PaletteMode.newCodexAgent)
        XCTAssertNotEqual(PaletteMode.newCodexAgent, PaletteMode.newTerminal)
        XCTAssertNotEqual(PaletteMode.switchSession, PaletteMode.newWorktree)
    }

    // MARK: - PathBrowseOrigin

    func testPathBrowseOriginEquatable() {
        XCTAssertEqual(PathBrowseOrigin.newAgent, PathBrowseOrigin.newAgent)
        XCTAssertEqual(PathBrowseOrigin.newCodexAgent, PathBrowseOrigin.newCodexAgent)
        XCTAssertNotEqual(PathBrowseOrigin.newAgent, PathBrowseOrigin.newTerminal)
        XCTAssertNotEqual(PathBrowseOrigin.newAgent, PathBrowseOrigin.newCodexAgent)
    }

    // MARK: - Launch Routing

    func testSavedFolderLaunchRoutingUsesClaudeForNewAgent() {
        XCTAssertEqual(PaletteMode.newAgent.launchAgentType, "claude")
    }

    func testSavedFolderLaunchRoutingUsesCodexForNewCodexAgent() {
        XCTAssertEqual(PaletteMode.newCodexAgent.launchAgentType, "codex")
    }

    func testSavedFolderLaunchRoutingUsesTerminalForNewTerminal() {
        XCTAssertEqual(PaletteMode.newTerminal.launchAgentType, "terminal")
    }

    func testNonFolderModesHaveNoLaunchAgentType() {
        XCTAssertNil(PaletteMode.switchSession.launchAgentType)
        XCTAssertNil(PaletteMode.newWorktree.launchAgentType)
        XCTAssertNil(PaletteMode.browsePath(origin: .newCodexAgent).launchAgentType)
    }

    func testBrowsePathOriginRoutingUsesCodex() {
        XCTAssertEqual(PathBrowseOrigin.newCodexAgent.launchAgentType, "codex")
    }

    func testBrowsePathOriginRoutingPreservesExistingProviders() {
        XCTAssertEqual(PathBrowseOrigin.newAgent.launchAgentType, "claude")
        XCTAssertEqual(PathBrowseOrigin.newTerminal.launchAgentType, "terminal")
    }

    func testBrowseOriginForFolderModes() {
        XCTAssertEqual(PaletteMode.newAgent.browseOrigin, .newAgent)
        XCTAssertEqual(PaletteMode.newCodexAgent.browseOrigin, .newCodexAgent)
        XCTAssertEqual(PaletteMode.newTerminal.browseOrigin, .newTerminal)
    }

    func testBrowseOriginReturnsToCodexMode() {
        XCTAssertEqual(PathBrowseOrigin.newCodexAgent.returnMode, .newCodexAgent)
    }

    // MARK: - Backspace-on-Empty Mode Pop

    /// Helper that simulates handleBackspaceEmpty logic (same switch as CommandPaletteView).
    private func backspaceEmptyTarget(for mode: PaletteMode) -> PaletteMode? {
        switch mode {
        case .newAgent, .newCodexAgent, .newTerminal, .browsePath:
            return .switchSession
        default:
            return nil
        }
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

    func testBackspaceEmptyInNewAgentPopsToSwitchSession() {
        let target = backspaceEmptyTarget(for: .newAgent)
        XCTAssertEqual(target, .switchSession)
    }

    func testBackspaceEmptyInNewCodexAgentPopsToSwitchSession() {
        let target = backspaceEmptyTarget(for: .newCodexAgent)
        XCTAssertEqual(target, .switchSession)
    }

    func testBackspaceEmptyInNewTerminalPopsToSwitchSession() {
        let target = backspaceEmptyTarget(for: .newTerminal)
        XCTAssertEqual(target, .switchSession)
    }

    func testBackspaceEmptyInBrowsePathPopsToSwitchSession() {
        let target = backspaceEmptyTarget(for: .browsePath(origin: .newAgent))
        XCTAssertEqual(target, .switchSession)
    }
}
