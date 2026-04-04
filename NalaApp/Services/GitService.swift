import Foundation
import os

struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }

    var errorMessage: String {
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.isEmpty {
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Extract the most relevant line (fatal/error) instead of the full output
        if let fatal = msg.components(separatedBy: .newlines).last(where: { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }) {
            return String(fatal.dropFirst(fatal.hasPrefix("fatal:") ? 7 : 7)).trimmingCharacters(in: .whitespaces)
        }
        return msg
    }
}

enum GitService {
    private static let logger = Logger(subsystem: "com.nala.app", category: "GitService")

    // MARK: - Git Root Detection

    /// Walks up from `path` to find the nearest directory containing `.git`.
    /// Returns the git root path, or `nil` if no git repo is found.
    /// Skips TCC-protected directories to avoid macOS permission prompts.
    static func findGitRoot(from path: String) -> String? {
        let standardPath = URL(fileURLWithPath: path).standardized.path
        if isInsideProtectedDirectory(standardPath) {
            return nil
        }

        var current = URL(fileURLWithPath: standardPath)
        while current.path != "/" {
            // Stop walking if we've reached a protected directory boundary
            if isInsideProtectedDirectory(current.path) {
                current = current.deletingLastPathComponent()
                continue
            }
            let gitPath = current.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: gitPath) {
                return current.path
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Home subdirectories that require TCC consent for filesystem access.
    private static let protectedDirectoryNames: Set<String> = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"
    ]

    /// Returns `true` if the path is inside a TCC-protected home subdirectory.
    private static func isInsideProtectedDirectory(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in protectedDirectoryNames {
            let protected = "\(home)/\(dir)"
            if path == protected || path.hasPrefix(protected + "/") {
                return true
            }
        }
        return false
    }

    // MARK: - Worktree Operations

    static func createWorktree(repoPath: String, worktreeFolder: String, branchName: String) async -> CommandResult {
        let worktreePath = (worktreeFolder as NSString).appendingPathComponent(branchName)
        let args = ["-C", repoPath, "worktree", "add", worktreePath, "-b", branchName]
        logger.info("Creating worktree: repo=\(repoPath) folder=\(worktreeFolder) branch=\(branchName) target=\(worktreePath)")
        logger.debug("Command: git \(args.joined(separator: " "))")
        let result = await runGitWithRetry(args: args, label: "create worktree '\(branchName)'")
        if result.succeeded {
            logger.info("Worktree created at \(worktreePath)")
        } else {
            logger.error("Create worktree failed (exit \(result.exitCode)): stdout=\(result.stdout) stderr=\(result.stderr)")
        }
        return result
    }

    static func deleteBranch(repoPath: String, branchName: String) async -> CommandResult {
        let args = ["-C", repoPath, "branch", "-D", branchName]
        logger.info("Deleting branch: repo=\(repoPath) branch=\(branchName)")
        let result = await runGit(args: args, label: "delete branch '\(branchName)'")
        if result.succeeded {
            logger.info("Branch deleted: \(branchName)")
        } else {
            logger.error("Delete branch failed (exit \(result.exitCode)): \(result.stderr)")
        }
        return result
    }

    static func removeWorktree(repoPath: String, worktreePath: String, force: Bool = false) async -> CommandResult {
        var args = ["-C", repoPath, "worktree", "remove", worktreePath]
        if force { args.append("--force") }
        logger.info("Removing worktree: repo=\(repoPath) path=\(worktreePath) force=\(force)")
        logger.debug("Command: git \(args.joined(separator: " "))")
        let result = await runGitWithRetry(args: args, label: "remove worktree\(force ? " (force)" : "")")
        if result.succeeded {
            logger.info("Worktree removed: \(worktreePath)")
        } else {
            logger.error("Remove worktree failed (exit \(result.exitCode)): stdout=\(result.stdout) stderr=\(result.stderr)")
        }
        return result
    }

    /// Returns `true` if the path is a git worktree (`.git` is a file, not a directory).
    static func isWorktree(path: String) -> Bool {
        let gitPath = (path as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }

    /// Parses the `.git` file in a worktree to find the parent repo path.
    static func findParentRepoPath(worktreePath: String) -> String? {
        let gitFile = (worktreePath as NSString).appendingPathComponent(".git")
        guard let content = try? String(contentsOfFile: gitFile, encoding: .utf8) else {
            logger.debug("findParentRepoPath(\(worktreePath)): could not read .git file")
            return nil
        }

        // Format: "gitdir: /path/to/repo/.git/worktrees/<name>"
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir: ") else {
            logger.debug("findParentRepoPath(\(worktreePath)): .git file missing 'gitdir: ' prefix, content=\(trimmed)")
            return nil
        }
        let gitdir = String(trimmed.dropFirst("gitdir: ".count))
        logger.debug("findParentRepoPath(\(worktreePath)): gitdir=\(gitdir)")

        // Walk up from .git/worktrees/<name> to the repo root
        let url = URL(fileURLWithPath: gitdir)
        // .git/worktrees/<name> -> .git/worktrees -> .git -> repo root
        let dotGit = url.deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = dotGit.deletingLastPathComponent()

        // Verify it's actually a git repo
        let mainGitDir = dotGit.path
        var isDir: ObjCBool = true
        guard FileManager.default.fileExists(atPath: mainGitDir, isDirectory: &isDir),
              isDir.boolValue else {
            logger.warning("findParentRepoPath(\(worktreePath)): derived .git dir does not exist: \(mainGitDir)")
            return nil
        }

        logger.info("findParentRepoPath(\(worktreePath)) → \(repoRoot.path)")
        return repoRoot.path
    }

    // MARK: - Script Execution

    static func runScript(scriptPath: String, worktreePath: String, branchName: String, repoPath: String) async -> CommandResult {
        let expandedPath = (scriptPath as NSString).expandingTildeInPath
        logger.info("Running script: \(expandedPath) worktree=\(worktreePath) branch=\(branchName) repo=\(repoPath)")
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            logger.error("Script not found: \(expandedPath)")
            return CommandResult(exitCode: -1, stdout: "", stderr: "Script not found: \(scriptPath)")
        }

        // Run through a login+interactive shell so .zshrc is sourced and the
        // user's full PATH (Homebrew, npm globals, claude, etc.) is available.
        // Env vars are inlined in the command to avoid overriding process.environment
        // (which would clobber the shell's own PATH setup).
        let command = """
        export NALA_WORKTREE_PATH='\(worktreePath.replacingOccurrences(of: "'", with: "'\\''"))'
        export NALA_BRANCH_NAME='\(branchName.replacingOccurrences(of: "'", with: "'\\''"))'
        export NALA_REPO_PATH='\(repoPath.replacingOccurrences(of: "'", with: "'\\''"))'
        '\(expandedPath.replacingOccurrences(of: "'", with: "'\\''"))'
        """

        return await runProcess(
            executablePath: "/bin/zsh",
            args: ["-l", "-i", "-c", command],
            environment: nil,
            label: "script \(URL(fileURLWithPath: scriptPath).lastPathComponent)"
        )
    }

    // MARK: - Session-Level Git State

    struct GitStatus: Equatable {
        var branch: String = ""
        var dirtyFileCount: Int = 0
        var aheadCount: Int = 0
        var behindCount: Int = 0
    }

    struct WorktreeInfo: Equatable {
        let path: String
        let branch: String
        let isHead: Bool
    }

    struct GitStateUpdate: Equatable {
        let repoPath: String
        let status: GitStatus
    }

    /// Environment variable to prevent index.lock contention during git polling.
    private static let safeGitEnv = ["GIT_OPTIONAL_LOCKS": "0"]

    /// Get git status for a repo path (branch, dirty files, ahead/behind).
    static func gitStatus(repoPath: String) async -> GitStatus {
        var status = GitStatus()

        // Get branch name
        let branchResult = await runProcess(
            executablePath: "/usr/bin/git",
            args: ["-C", repoPath, "rev-parse", "--abbrev-ref", "HEAD"],
            environment: safeGitEnv,
            label: "branch name"
        )
        if branchResult.succeeded {
            status.branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Get dirty file count
        let porcelainResult = await runProcess(
            executablePath: "/usr/bin/git",
            args: ["-C", repoPath, "status", "--porcelain"],
            environment: safeGitEnv,
            label: "status porcelain"
        )
        if porcelainResult.succeeded {
            status.dirtyFileCount = porcelainResult.stdout
                .split(separator: "\n")
                .filter { !$0.isEmpty }
                .count
        }

        return status
    }

    /// Get branch name for a repo path.
    static func branchName(repoPath: String) async -> String? {
        let result = await runProcess(
            executablePath: "/usr/bin/git",
            args: ["-C", repoPath, "rev-parse", "--abbrev-ref", "HEAD"],
            environment: safeGitEnv,
            label: "branch name"
        )
        guard result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get git diff summary for a repo path.
    static func gitDiff(repoPath: String) async -> String? {
        let result = await runProcess(
            executablePath: "/usr/bin/git",
            args: ["-C", repoPath, "diff", "--stat"],
            environment: safeGitEnv,
            label: "diff stat"
        )
        guard result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// List all worktrees for a repo.
    static func worktreeList(repoPath: String) async -> [WorktreeInfo] {
        let result = await runProcess(
            executablePath: "/usr/bin/git",
            args: ["-C", repoPath, "worktree", "list", "--porcelain"],
            environment: safeGitEnv,
            label: "worktree list"
        )
        guard result.succeeded else { return [] }
        return parseWorktreeList(result.stdout)
    }

    /// Parse `git worktree list --porcelain` output into WorktreeInfo structs.
    static func parseWorktreeList(_ output: String) -> [WorktreeInfo] {
        var worktrees: [WorktreeInfo] = []
        var currentPath = ""
        var currentBranch = ""
        var isHead = false

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let str = String(line)
            if str.hasPrefix("worktree ") {
                // Save previous worktree if exists
                if !currentPath.isEmpty {
                    worktrees.append(WorktreeInfo(path: currentPath, branch: currentBranch, isHead: isHead))
                }
                currentPath = String(str.dropFirst("worktree ".count))
                currentBranch = ""
                isHead = false
            } else if str.hasPrefix("branch ") {
                let ref = String(str.dropFirst("branch ".count))
                // Strip refs/heads/ prefix
                currentBranch = ref.hasPrefix("refs/heads/")
                    ? String(ref.dropFirst("refs/heads/".count))
                    : ref
            } else if str == "HEAD" {
                isHead = true
            } else if str.isEmpty && !currentPath.isEmpty {
                worktrees.append(WorktreeInfo(path: currentPath, branch: currentBranch, isHead: isHead))
                currentPath = ""
                currentBranch = ""
                isHead = false
            }
        }

        // Don't forget the last entry
        if !currentPath.isEmpty {
            worktrees.append(WorktreeInfo(path: currentPath, branch: currentBranch, isHead: isHead))
        }

        return worktrees
    }

    /// Parse `git status --porcelain` output to count dirty files.
    static func parsePorcelainStatus(_ output: String) -> Int {
        output.split(separator: "\n")
            .filter { !$0.isEmpty }
            .count
    }

    // MARK: - Git State Polling

    /// A polling coordinator that polls git status for a set of worktree paths.
    final class GitStatePoller: @unchecked Sendable {
        private var paths: Set<String> = []
        private var continuationIndex = 0
        private var continuations: [Int: AsyncStream<GitStateUpdate>.Continuation] = [:]
        private let lock = NSLock()

        func setPaths(_ newPaths: Set<String>) {
            lock.lock()
            paths = newPaths
            lock.unlock()
        }

        func updates() -> AsyncStream<GitStateUpdate> {
            AsyncStream { [weak self] continuation in
                guard let self else {
                    continuation.finish()
                    return
                }
                lock.lock()
                let id = continuationIndex
                continuationIndex += 1
                continuations[id] = continuation
                lock.unlock()

                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.lock.lock()
                    self.continuations.removeValue(forKey: id)
                    self.lock.unlock()
                }
            }
        }

        func pollOnce() async {
            lock.lock()
            let currentPaths = paths
            lock.unlock()

            for path in currentPaths {
                let status = await GitService.gitStatus(repoPath: path)
                let update = GitStateUpdate(repoPath: path, status: status)

                lock.lock()
                let conts = Array(continuations.values)
                lock.unlock()

                for c in conts {
                    c.yield(update)
                }
            }
        }

        func stop() {
            lock.lock()
            for (_, c) in continuations { c.finish() }
            continuations.removeAll()
            lock.unlock()
        }
    }

    // MARK: - Process Helpers

    private static func runGit(args: [String], label: String) async -> CommandResult {
        await runProcess(executablePath: "/usr/bin/git", args: args, environment: nil, label: label)
    }

    /// Runs a git command with retry on index lock contention (exponential backoff).
    private static func runGitWithRetry(
        args: [String],
        label: String,
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 1.0
    ) async -> CommandResult {
        let lockErrors = ["index.lock", "Unable to create", "lock file"]
        for attempt in 0...maxRetries {
            let result = await runGit(args: args, label: label)
            if result.succeeded { return result }
            let isLockError = lockErrors.contains { result.stderr.contains($0) }
            if !isLockError || attempt == maxRetries { return result }
            let delay = baseDelay * pow(2.0, Double(attempt))
            logger.warning("Git lock contention (attempt \(attempt + 1)/\(maxRetries + 1)), retrying in \(delay)s: \(result.stderr)")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        // Unreachable, but satisfies the compiler
        return await runGit(args: args, label: label)
    }

    /// Thread-safe mutable data buffer for incremental pipe reads.
    private final class LockedBuffer: @unchecked Sendable {
        private var _data = Data()
        private let lock = NSLock()

        func append(_ new: Data) {
            guard !new.isEmpty else { return }
            lock.lock()
            _data.append(new)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return _data
        }
    }

    private static func runProcess(
        executablePath: String,
        args: [String],
        environment: [String: String]?,
        label: String
    ) async -> CommandResult {
        logger.debug("runProcess: \(executablePath) \(args.joined(separator: " "))")
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = args

            if let environment {
                var env = ProcessInfo.processInfo.environment
                for (key, value) in environment { env[key] = value }
                process.environment = env
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Read pipe data incrementally to prevent deadlock when the child
            // process fills the 64KB pipe buffer.
            let stdoutBuf = LockedBuffer()
            let stderrBuf = LockedBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stdoutBuf.append(data) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stderrBuf.append(data) }
            }

            process.terminationHandler = { process in
                // Stop reading and drain remaining data
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutBuf.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderrBuf.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

                let stdout = String(data: stdoutBuf.data, encoding: .utf8) ?? ""
                let stderr = String(data: stderrBuf.data, encoding: .utf8) ?? ""

                let result = CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
                if result.succeeded {
                    logger.info("Git \(label) succeeded")
                } else {
                    logger.warning("Git \(label) failed (\(process.terminationStatus)): \(stderr)")
                }
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                logger.error("Failed to run \(label): \(error)")
                continuation.resume(returning: CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription))
            }
        }
    }
}
