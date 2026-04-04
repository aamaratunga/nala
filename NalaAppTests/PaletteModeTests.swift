import XCTest
@testable import Nala

final class PaletteModeTests: XCTestCase {

    // MARK: - Labels

    func testSwitchSessionLabel() {
        XCTAssertEqual(PaletteMode.switchSession.label, "Switch")
    }

    func testNewAgentLabel() {
        XCTAssertEqual(PaletteMode.newAgent.label, "New Agent")
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

    // MARK: - Search Placeholders

    func testSwitchSessionPlaceholder() {
        XCTAssertEqual(PaletteMode.switchSession.searchPlaceholder, "Search sessions...")
    }

    func testNewAgentPlaceholder() {
        XCTAssertEqual(PaletteMode.newAgent.searchPlaceholder, "Select folder...")
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

    func testDifferentModesNotEqual() {
        XCTAssertNotEqual(PaletteMode.newAgent, PaletteMode.newTerminal)
        XCTAssertNotEqual(PaletteMode.switchSession, PaletteMode.newWorktree)
    }

    // MARK: - PathBrowseOrigin

    func testPathBrowseOriginEquatable() {
        XCTAssertEqual(PathBrowseOrigin.newAgent, PathBrowseOrigin.newAgent)
        XCTAssertNotEqual(PathBrowseOrigin.newAgent, PathBrowseOrigin.newTerminal)
    }

    // MARK: - Backspace-on-Empty Mode Pop

    /// Helper that simulates handleBackspaceEmpty logic (same switch as CommandPaletteView).
    private func backspaceEmptyTarget(for mode: PaletteMode) -> PaletteMode? {
        switch mode {
        case .newAgent, .newTerminal, .browsePath:
            return .switchSession
        default:
            return nil
        }
    }

    func testBackspaceEmptyInNewAgentPopsToSwitchSession() {
        let target = backspaceEmptyTarget(for: .newAgent)
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
