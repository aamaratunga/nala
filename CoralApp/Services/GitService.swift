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
    private static let logger = Logger(subsystem: "com.coral.app", category: "GitService")

    // MARK: - Git Root Detection

    /// Walks up from `path` to find the nearest directory containing `.git`.
    /// Returns the git root path, or `nil` if no git repo is found.
    static func findGitRoot(from path: String) -> String? {
        var current = URL(fileURLWithPath: path).standardized
        while current.path != "/" {
            let gitPath = current.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: gitPath) {
                return current.path
            }
            current = current.deletingLastPathComponent()
        }
        return nil
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
        export CORAL_WORKTREE_PATH='\(worktreePath.replacingOccurrences(of: "'", with: "'\\''"))'
        export CORAL_BRANCH_NAME='\(branchName.replacingOccurrences(of: "'", with: "'\\''"))'
        export CORAL_REPO_PATH='\(repoPath.replacingOccurrences(of: "'", with: "'\\''"))'
        '\(expandedPath.replacingOccurrences(of: "'", with: "'\\''"))'
        """

        return await runProcess(
            executablePath: "/bin/zsh",
            args: ["-l", "-i", "-c", command],
            environment: nil,
            label: "script \(URL(fileURLWithPath: scriptPath).lastPathComponent)"
        )
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

            process.terminationHandler = { process in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

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
                logger.error("Failed to run \(label): \(error)")
                continuation.resume(returning: CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription))
            }
        }
    }
}
