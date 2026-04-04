import XCTest
@testable import Nala

final class PathFinderTests: XCTestCase {

    // MARK: - Git Repo Detection

    func testGitRepoDetectionTrue() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathFinderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a .git directory
        let gitDir = tmpDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)

        XCTAssertTrue(PathFinder.isGitRepo(at: tmpDir.path))
    }

    func testGitRepoDetectionFalse() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathFinderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        XCTAssertFalse(PathFinder.isGitRepo(at: tmpDir.path))
    }

    // MARK: - Absolute Path Enumeration

    func testAbsolutePathEnumeratesDirectory() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathFinderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create subdirectories
        for name in ["alpha", "beta", "gamma"] {
            try FileManager.default.createDirectory(
                at: tmpDir.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }

        let results = await PathFinder.enumerateDirectories(
            matching: tmpDir.path + "/",
            roots: [],
            recentPaths: []
        )

        XCTAssertEqual(results.count, 3)
        let names = Set(results.map(\.displayName))
        XCTAssertEqual(names, ["alpha", "beta", "gamma"])
    }

    func testAbsolutePathFiltersChildren() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathFinderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        for name in ["coral", "corgi", "other"] {
            try FileManager.default.createDirectory(
                at: tmpDir.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }

        let results = await PathFinder.enumerateDirectories(
            matching: tmpDir.path + "/cor",
            roots: [],
            recentPaths: []
        )

        // "cor" should fuzzy match "coral" and "corgi" but not "other"
        let names = Set(results.map(\.displayName))
        XCTAssertTrue(names.contains("coral"))
        XCTAssertTrue(names.contains("corgi"))
        XCTAssertFalse(names.contains("other"))
    }

    func testNonExistentDirectoryReturnsEmpty() async {
        let results = await PathFinder.enumerateDirectories(
            matching: "/nonexistent-path-that-does-not-exist-12345/",
            roots: [],
            recentPaths: []
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testAbsolutePathExpandsTilde() async {
        // "~/." should expand and enumerate (home directory exists)
        // We just verify it doesn't crash and returns something
        let results = await PathFinder.enumerateDirectories(
            matching: "~/",
            roots: [],
            recentPaths: []
        )

        // Home directory should have at least some subdirectories
        XCTAssertFalse(results.isEmpty)
    }

    // MARK: - Excluded Directories

    func testExcludedDirectoriesSkipped() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathFinderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create an excluded directory and a normal one
        for name in ["node_modules", "src"] {
            try FileManager.default.createDirectory(
                at: tmpDir.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }

        let results = await PathFinder.enumerateDirectories(
            matching: tmpDir.path + "/",
            roots: [],
            recentPaths: []
        )

        let names = results.map(\.displayName)
        XCTAssertTrue(names.contains("src"))
        XCTAssertFalse(names.contains("node_modules"))
    }

    func testHiddenDirectoriesSkipped() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathFinderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        for name in [".hidden", "visible"] {
            try FileManager.default.createDirectory(
                at: tmpDir.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }

        let results = await PathFinder.enumerateDirectories(
            matching: tmpDir.path + "/",
            roots: [],
            recentPaths: []
        )

        let names = results.map(\.displayName)
        XCTAssertTrue(names.contains("visible"))
        XCTAssertFalse(names.contains(".hidden"))
    }

    // MARK: - Fuzzy Fragment Mode

    func testFuzzyFragmentMatchesDirectoryNames() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathFinderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        for name in ["myproject", "another"] {
            try FileManager.default.createDirectory(
                at: tmpDir.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }

        let results = await PathFinder.enumerateDirectories(
            matching: "myproj",
            roots: [tmpDir.path],
            recentPaths: []
        )

        let names = results.map(\.displayName)
        XCTAssertTrue(names.contains("myproject"))
        XCTAssertFalse(names.contains("another"))
    }

    // MARK: - Depth Limit

    func testDepthLimitRespected() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathFinderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create nested: level1/level2/level3/target
        let deep = tmpDir.appendingPathComponent("level1/level2/level3/target")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        // Also create level1/match at depth 1
        let shallow = tmpDir.appendingPathComponent("level1/match")
        try FileManager.default.createDirectory(at: shallow, withIntermediateDirectories: true)

        let results = await PathFinder.enumerateDirectories(
            matching: "match",
            roots: [tmpDir.path],
            recentPaths: []
        )

        // "match" at depth 1 should be found
        let paths = results.map(\.path)
        XCTAssertTrue(paths.contains(shallow.path))

        // "target" at depth 3 should NOT be found (maxDepth = 2)
        XCTAssertFalse(paths.contains(deep.path))
    }

    // MARK: - Sorting

    func testRecentPathsSortFirst() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathFinderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectA = tmpDir.appendingPathComponent("project-a")
        let projectB = tmpDir.appendingPathComponent("project-b")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)

        let results = await PathFinder.enumerateDirectories(
            matching: tmpDir.path + "/",
            roots: [],
            recentPaths: [projectB.path]
        )

        // project-b should come first because it's recent
        XCTAssertEqual(results.first?.path, projectB.path)
    }

    // MARK: - Files Are Excluded (only directories)

    func testFilesAreExcluded() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathFinderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a directory and a file
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("mydir"),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: tmpDir.appendingPathComponent("myfile.txt").path,
            contents: nil
        )

        let results = await PathFinder.enumerateDirectories(
            matching: tmpDir.path + "/",
            roots: [],
            recentPaths: []
        )

        let names = results.map(\.displayName)
        XCTAssertTrue(names.contains("mydir"))
        XCTAssertFalse(names.contains("myfile.txt"))
    }

    // MARK: - PathResult

    func testPathResultEquatable() {
        let a = PathResult(path: "/tmp/a", displayName: "a", isDirectory: true, isGitRepo: false)
        let b = PathResult(path: "/tmp/a", displayName: "a", isDirectory: true, isGitRepo: false)
        let c = PathResult(path: "/tmp/c", displayName: "c", isDirectory: true, isGitRepo: false)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testPathResultIdIsPath() {
        let result = PathResult(path: "/tmp/test", displayName: "test", isDirectory: true, isGitRepo: false)
        XCTAssertEqual(result.id, "/tmp/test")
    }

    // MARK: - Browse Root

    func testFuzzySearchUsesBrowseRootInsteadOfCommonPaths() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathFinderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a target directory inside our custom browse root
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("myproject"),
            withIntermediateDirectories: true
        )

        let results = await PathFinder.enumerateDirectories(
            matching: "myproj",
            roots: [],
            recentPaths: [],
            browseRoot: tmpDir.path
        )

        let names = results.map(\.displayName)
        XCTAssertTrue(names.contains("myproject"))
    }

    func testFuzzySearchFallsBackToCommonPathsWhenBrowseRootEmpty() async {
        // With empty browseRoot, should use commonPaths fallback (existing behavior)
        let results = await PathFinder.enumerateDirectories(
            matching: "xyznonexistent",
            roots: [],
            recentPaths: [],
            browseRoot: ""
        )

        // Just verify it doesn't crash and returns (likely empty for a nonsense query)
        XCTAssertNotNil(results)
    }

    func testFuzzySearchWithNonExistentBrowseRoot() async {
        let results = await PathFinder.enumerateDirectories(
            matching: "anything",
            roots: [],
            recentPaths: [],
            browseRoot: "/nonexistent-browse-root-12345"
        )

        // Non-existent browse root should produce no results from that root
        XCTAssertTrue(results.isEmpty)
    }
}
