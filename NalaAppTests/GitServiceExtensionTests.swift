import XCTest
@testable import Nala

final class GitServiceExtensionTests: XCTestCase {

    // MARK: - Porcelain Status Parsing

    func testParsePorcelainStatusEmpty() {
        let count = GitService.parsePorcelainStatus("")
        XCTAssertEqual(count, 0)
    }

    func testParsePorcelainStatusSingleFile() {
        let output = " M src/main.swift\n"
        let count = GitService.parsePorcelainStatus(output)
        XCTAssertEqual(count, 1)
    }

    func testParsePorcelainStatusMultipleFiles() {
        let output = """
         M src/main.swift
        ?? new_file.txt
        A  staged.swift
        """
        let count = GitService.parsePorcelainStatus(output)
        XCTAssertEqual(count, 3)
    }

    func testParsePorcelainStatusIgnoresEmptyLines() {
        let output = " M src/main.swift\n\n?? new_file.txt\n"
        let count = GitService.parsePorcelainStatus(output)
        XCTAssertEqual(count, 2)
    }

    // MARK: - Worktree List Parsing

    func testParseWorktreeListSingle() {
        let output = """
        worktree /Users/dev/project
        HEAD abc1234
        branch refs/heads/main

        """

        let worktrees = GitService.parseWorktreeList(output)
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertEqual(worktrees[0].path, "/Users/dev/project")
        XCTAssertEqual(worktrees[0].branch, "main")
    }

    func testParseWorktreeListMultiple() {
        let output = """
        worktree /Users/dev/project
        HEAD abc1234
        branch refs/heads/main

        worktree /Users/dev/project-feature
        HEAD def5678
        branch refs/heads/feature/tests

        """

        let worktrees = GitService.parseWorktreeList(output)
        XCTAssertEqual(worktrees.count, 2)
        XCTAssertEqual(worktrees[0].path, "/Users/dev/project")
        XCTAssertEqual(worktrees[0].branch, "main")
        XCTAssertEqual(worktrees[1].path, "/Users/dev/project-feature")
        XCTAssertEqual(worktrees[1].branch, "feature/tests")
    }

    func testParseWorktreeListEmpty() {
        let worktrees = GitService.parseWorktreeList("")
        XCTAssertTrue(worktrees.isEmpty)
    }

    func testParseWorktreeListStripsBranchPrefix() {
        let output = """
        worktree /tmp/wt
        HEAD abc
        branch refs/heads/my-branch

        """

        let worktrees = GitService.parseWorktreeList(output)
        XCTAssertEqual(worktrees[0].branch, "my-branch", "refs/heads/ prefix should be stripped")
    }

    // MARK: - Safe Git Environment

    func testGitStatusMethodExists() async {
        // Verify the method signature works (calls real git, just confirms it doesn't crash)
        let status = await GitService.gitStatus(repoPath: "/nonexistent")
        // Will return empty since path doesn't exist, but shouldn't crash
        XCTAssertEqual(status.branch, "")
        XCTAssertEqual(status.dirtyFileCount, 0)
    }

    func testBranchNameMethodExists() async {
        let branch = await GitService.branchName(repoPath: "/nonexistent")
        XCTAssertNil(branch)
    }
}
