import Foundation
import os

// MARK: - PathResult

struct PathResult: Identifiable, Equatable {
    let id: String
    let path: String
    let displayName: String
    let isDirectory: Bool
    let isGitRepo: Bool
    let isRecent: Bool

    init(path: String, displayName: String, isDirectory: Bool, isGitRepo: Bool, isRecent: Bool = false) {
        self.id = path
        self.path = path
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.isGitRepo = isGitRepo
        self.isRecent = isRecent
    }
}

// MARK: - PathFinder

@MainActor
@Observable
final class PathFinder {
    var results: [PathResult] = []
    var isSearching = false

    private var searchGeneration: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private nonisolated(unsafe) static let logger = Logger(subsystem: "com.nala.app", category: "PathFinder")

    private nonisolated(unsafe) static let excludedDirectories: Set<String> = [
        "node_modules", ".git", "build", "DerivedData", ".build",
        "Pods", ".Trash", "Library", ".cache", "__pycache__"
    ]

    private nonisolated(unsafe) static let maxDepth = 2

    // MARK: - Public API

    /// Begin a debounced search for the given query.
    func search(query: String, roots: [String], recentPaths: [String], browseRoot: String = "") {
        debounceTask?.cancel()

        if query.isEmpty {
            searchGeneration &+= 1
            results = defaultResults(recentPaths: recentPaths)
            isSearching = false
            return
        }

        isSearching = true
        let generation = searchGeneration &+ 1
        searchGeneration = generation

        debounceTask = Task { [generation] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, generation == self.searchGeneration else { return }

            let found = await Self.enumerateDirectories(
                matching: query,
                roots: roots,
                recentPaths: recentPaths,
                browseRoot: browseRoot
            )

            guard !Task.isCancelled, generation == self.searchGeneration else { return }
            self.results = found
            self.isSearching = false
        }
    }

    /// Cancel any active search.
    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        isSearching = false
    }

    // MARK: - Default Results

    private func defaultResults(recentPaths: [String]) -> [PathResult] {
        recentPaths.prefix(10).compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return PathResult(
                path: path,
                displayName: url.lastPathComponent,
                isDirectory: true,
                isGitRepo: Self.isGitRepo(at: path),
                isRecent: true
            )
        }
    }

    // MARK: - Enumeration (nonisolated for Swift 6 safety)

    nonisolated static func enumerateDirectories(
        matching query: String,
        roots: [String],
        recentPaths: [String],
        browseRoot: String = ""
    ) async -> [PathResult] {
        // Determine search mode from query
        let expandedQuery = expandTilde(query)

        if expandedQuery.hasPrefix("/") {
            // Absolute path mode: enumerate the directory, filter children
            return enumerateAbsolute(query: expandedQuery, recentPaths: recentPaths)
        } else if query.contains("/") {
            // Relative path mode: search across roots
            return enumerateRelative(query: query, roots: roots, recentPaths: recentPaths)
        } else {
            // Fuzzy fragment mode: fuzzy match dir names across roots + recent
            return enumerateFuzzy(query: query, roots: roots, recentPaths: recentPaths, browseRoot: browseRoot)
        }
    }

    // MARK: - Absolute Path Mode

    private nonisolated static func enumerateAbsolute(query: String, recentPaths: [String]) -> [PathResult] {
        let fm = FileManager.default

        // Split into directory and filter components
        let url = URL(fileURLWithPath: query)
        let parentPath: String
        let filter: String

        if query.hasSuffix("/") {
            parentPath = query
            filter = ""
        } else {
            parentPath = url.deletingLastPathComponent().path
            filter = url.lastPathComponent
        }

        guard fm.fileExists(atPath: parentPath) else { return [] }

        var gitCache: [String: Bool] = [:]
        let recentSet = Set(recentPaths)

        do {
            let contents = try fm.contentsOfDirectory(atPath: parentPath)
            var results: [PathResult] = []

            for name in contents {
                guard !Task.isCancelled else { return [] }
                guard !excludedDirectories.contains(name) else { continue }
                guard !name.hasPrefix(".") else { continue }

                let fullPath = (parentPath as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

                if filter.isEmpty || fuzzyMatch(query: filter, target: name) != nil {
                    results.append(PathResult(
                        path: fullPath,
                        displayName: name,
                        isDirectory: true,
                        isGitRepo: cachedIsGitRepo(at: fullPath, cache: &gitCache),
                        isRecent: recentSet.contains(fullPath)
                    ))
                }
            }

            return sortResults(results, query: filter)
        } catch {
            logger.debug("Failed to enumerate \(parentPath): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Relative Path Mode

    private nonisolated static func enumerateRelative(query: String, roots: [String], recentPaths: [String]) -> [PathResult] {
        let components = query.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return [] }

        let filter = String(components.last ?? "")
        let fm = FileManager.default
        var gitCache: [String: Bool] = [:]
        let recentSet = Set(recentPaths)
        var results: [PathResult] = []
        var seen = Set<String>()

        // Only walk parent dirs of recent paths (user-chosen). Roots (folderOrder)
        // are already known directories — walking them is unnecessary and can trigger
        // TCC prompts if a session was discovered on a network volume.
        let searchRoots = Array(Set(recentPaths.compactMap { URL(fileURLWithPath: $0).deletingLastPathComponent().path }))

        for root in searchRoots {
            guard !Task.isCancelled else { return [] }
            guard fm.fileExists(atPath: root) else { continue }

            // Walk up to maxDepth, looking for paths that match the query components
            let found = walkDirectory(root, depth: 0, maxDepth: maxDepth, fm: fm, filter: filter, gitCache: &gitCache, recentSet: recentSet)
            for result in found {
                if !seen.contains(result.path) {
                    seen.insert(result.path)
                    results.append(result)
                }
            }
        }

        return sortResults(results, query: filter)
    }

    // MARK: - Fuzzy Fragment Mode

    private nonisolated static func enumerateFuzzy(query: String, roots: [String], recentPaths: [String], browseRoot: String = "") -> [PathResult] {
        let fm = FileManager.default
        var gitCache: [String: Bool] = [:]
        let recentSet = Set(recentPaths)
        var results: [PathResult] = []
        var seen = Set<String>()

        // Search recent paths first (they get priority)
        for path in recentPaths {
            guard !Task.isCancelled else { return [] }
            let name = URL(fileURLWithPath: path).lastPathComponent
            if fuzzyMatch(query: query, target: name) != nil {
                if !seen.contains(path) && fm.fileExists(atPath: path) {
                    seen.insert(path)
                    let isGit = cachedIsGitRepo(at: path, cache: &gitCache)
                    results.append(PathResult(
                        path: path,
                        displayName: name,
                        isDirectory: true,
                        isGitRepo: isGit,
                        isRecent: true
                    ))
                }
            }
        }

        // Match roots directly by their last path component — zero filesystem I/O.
        // Roots are folderOrder entries (known session directories). Walking their
        // subtrees is unnecessary and can trigger TCC prompts if a session was
        // discovered on a network volume.
        for root in roots {
            guard !Task.isCancelled else { return [] }
            guard !seen.contains(root) else { continue }
            let name = URL(fileURLWithPath: root).lastPathComponent
            if fuzzyMatch(query: query, target: name) != nil {
                if fm.fileExists(atPath: root) {
                    seen.insert(root)
                    let isGit = cachedIsGitRepo(at: root, cache: &gitCache)
                    results.append(PathResult(
                        path: root,
                        displayName: name,
                        isDirectory: true,
                        isGitRepo: isGit,
                        isRecent: false
                    ))
                }
            }
        }

        // Search browse root (user-configured) — walk its subtrees to discover
        // project directories the user wants to launch agents in.
        let expandedBrowseRoot = expandTilde(browseRoot)
        if !expandedBrowseRoot.isEmpty {
            guard !Task.isCancelled else { return [] }
            if fm.fileExists(atPath: expandedBrowseRoot) && !roots.contains(expandedBrowseRoot) {
                let found = walkDirectory(expandedBrowseRoot, depth: 0, maxDepth: maxDepth, fm: fm, filter: query, gitCache: &gitCache, recentSet: recentSet)
                for result in found {
                    if !seen.contains(result.path) {
                        seen.insert(result.path)
                        results.append(result)
                    }
                }
            }
        }

        return sortResults(results, query: query)
    }

    // MARK: - Directory Walking

    private nonisolated static func walkDirectory(
        _ path: String,
        depth: Int,
        maxDepth: Int,
        fm: FileManager,
        filter: String,
        gitCache: inout [String: Bool],
        recentSet: Set<String>
    ) -> [PathResult] {
        guard depth <= maxDepth else { return [] }

        var results: [PathResult] = []

        do {
            let contents = try fm.contentsOfDirectory(atPath: path)
            for name in contents {
                guard !excludedDirectories.contains(name) else { continue }
                guard !name.hasPrefix(".") else { continue }

                let fullPath = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

                if fuzzyMatch(query: filter, target: name) != nil {
                    results.append(PathResult(
                        path: fullPath,
                        displayName: name,
                        isDirectory: true,
                        isGitRepo: cachedIsGitRepo(at: fullPath, cache: &gitCache),
                        isRecent: recentSet.contains(fullPath)
                    ))
                }

                // Recurse if not at max depth
                if depth < maxDepth {
                    results += walkDirectory(fullPath, depth: depth + 1, maxDepth: maxDepth, fm: fm, filter: filter, gitCache: &gitCache, recentSet: recentSet)
                }
            }
        } catch {
            // Permission denied or other error — skip silently
        }

        return results
    }

    // MARK: - Git Repo Detection

    nonisolated static func isGitRepo(at path: String) -> Bool {
        let gitPath = (path as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath)
    }

    private nonisolated static func cachedIsGitRepo(at path: String, cache: inout [String: Bool]) -> Bool {
        if let cached = cache[path] { return cached }
        let result = isGitRepo(at: path)
        cache[path] = result
        return result
    }

    // MARK: - Sorting

    private nonisolated static func sortResults(_ results: [PathResult], query: String) -> [PathResult] {
        results.sorted { a, b in
            // Recent paths first
            if a.isRecent != b.isRecent { return a.isRecent }
            // Git repos before non-repos
            if a.isGitRepo != b.isGitRepo { return a.isGitRepo }
            // Better fuzzy match score
            let scoreA = fuzzyMatch(query: query, target: a.displayName)?.score ?? 0
            let scoreB = fuzzyMatch(query: query, target: b.displayName)?.score ?? 0
            if scoreA != scoreB { return scoreA > scoreB }
            // Alphabetical fallback
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    // MARK: - Helpers

    private nonisolated static func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return path
    }
}
