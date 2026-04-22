import Foundation

final class CodexHookBridge: @unchecked Sendable {
    typealias ProcessRunner = @Sendable (String, [String]) async -> CommandResult

    enum InstallResult: Equatable {
        case installed
        case repaired
        case alreadyInstalled
    }

    enum InstallationStatus: Equatable {
        case missing
        case repairNeeded
        case installed
        case failed(String)
    }

    enum BridgeError: LocalizedError, Equatable {
        case invalidJSON(String)
        case invalidStructure(String)
        case concurrentModification(String)
        case readFailed(String, String)
        case writeFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let path):
                return "Invalid Codex hooks JSON at \(path)"
            case .invalidStructure(let path):
                return "Unsupported Codex hooks structure at \(path)"
            case .concurrentModification(let path):
                return "Codex hooks changed while Nala was updating \(path). Try again."
            case .readFailed(let path, let reason):
                return "Could not read Codex hooks at \(path): \(reason)"
            case .writeFailed(let path, let reason):
                return "Could not write Codex hooks at \(path): \(reason)"
            }
        }
    }

    struct FeatureState: Equatable {
        let version: String?
        let hooksFeatureListed: Bool
        let hooksEnabledByDefault: Bool?
        let errorMessage: String?

        var summary: String {
            if let errorMessage { return errorMessage }

            var parts: [String] = []
            if let version, !version.isEmpty {
                parts.append(version)
            } else {
                parts.append("Codex CLI version unknown")
            }

            if hooksFeatureListed {
                if let hooksEnabledByDefault {
                    parts.append(hooksEnabledByDefault ? "codex_hooks enabled by default" : "codex_hooks available, disabled by default")
                } else {
                    parts.append("codex_hooks available")
                }
            } else {
                parts.append("codex_hooks not reported by this CLI")
            }

            return parts.joined(separator: "; ")
        }
    }

    static let hookEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "Stop",
    ]

    static let nalaHookCommand = #"[ -z "$NALA_SESSION_ID" ] && exit 0; mkdir -p ~/.nala/events && { cat; echo; } >> ~/.nala/events/$NALA_SESSION_ID.jsonl"#

    private let hooksFileURL: URL
    private let fileManager: FileManager
    private let executableResolver: AgentProviderProvider
    private let processRunner: ProcessRunner
    private let beforeOptimisticReRead: (() -> Void)?

    typealias AgentProviderProvider = @Sendable (AgentProvider) -> String?

    init(
        hooksFileURL: URL? = nil,
        fileManager: FileManager = .default,
        executableResolver: AgentProviderProvider? = nil,
        processRunner: ProcessRunner? = nil,
        beforeOptimisticReRead: (() -> Void)? = nil
    ) {
        self.hooksFileURL = hooksFileURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("hooks.json")
        self.fileManager = fileManager
        self.executableResolver = executableResolver ?? { provider in
            TmuxService.resolveExecutable(for: provider)
        }
        self.processRunner = processRunner ?? { executable, args in
            await Self.runProcess(executablePath: executable, args: args)
        }
        self.beforeOptimisticReRead = beforeOptimisticReRead
    }

    func installationStatus() -> InstallationStatus {
        do {
            guard let data = try readHooksData() else { return .missing }
            let document = try parseDocument(data: data)
            return Self.containsAllNalaHooks(in: document) ? .installed : .repairNeeded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func installOrRepair() throws -> InstallResult {
        try ensureHooksDirectoryExists()

        let originalData = try readHooksData()
        let originalDocument = try parseDocument(data: originalData)
        if Self.containsAllNalaHooks(in: originalDocument) {
            return .alreadyInstalled
        }

        let mergedDocument = try Self.mergingNalaHooks(into: originalDocument, path: hooksFileURL.path)
        let latestData = try optimisticRead()

        if latestData != originalData {
            let latestDocument = try parseDocument(data: latestData)
            let latestMergedDocument = try Self.mergingNalaHooks(into: latestDocument, path: hooksFileURL.path)
            let stableData = try optimisticRead()
            guard stableData == latestData else {
                throw BridgeError.concurrentModification(hooksFileURL.path)
            }
            try writeDocument(latestMergedDocument)
            return originalData == nil ? .installed : .repaired
        }

        try writeDocument(mergedDocument)
        return originalData == nil ? .installed : .repaired
    }

    func detectFeatureState() async -> FeatureState {
        guard let executable = executableResolver(.codex) else {
            return FeatureState(
                version: nil,
                hooksFeatureListed: false,
                hooksEnabledByDefault: nil,
                errorMessage: "Codex CLI not found"
            )
        }

        let versionResult = await processRunner(executable, ["--version"])
        let version = versionResult.succeeded
            ? versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        let featuresResult = await processRunner(executable, ["features", "list"])
        guard featuresResult.succeeded else {
            return FeatureState(
                version: version,
                hooksFeatureListed: false,
                hooksEnabledByDefault: nil,
                errorMessage: "Could not inspect Codex features: \(featuresResult.errorMessage)"
            )
        }

        let hookLine = featuresResult.stdout
            .split(separator: "\n")
            .map(String.init)
            .first { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).first == "codex_hooks" }

        guard let hookLine else {
            return FeatureState(
                version: version,
                hooksFeatureListed: false,
                hooksEnabledByDefault: nil,
                errorMessage: nil
            )
        }

        let columns = hookLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let enabledByDefault = columns.last.map { $0 == "true" }

        return FeatureState(
            version: version,
            hooksFeatureListed: true,
            hooksEnabledByDefault: enabledByDefault,
            errorMessage: nil
        )
    }

    private func ensureHooksDirectoryExists() throws {
        let directory = hooksFileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BridgeError.writeFailed(directory.path, error.localizedDescription)
        }
    }

    private func readHooksData() throws -> Data? {
        guard fileManager.fileExists(atPath: hooksFileURL.path) else { return nil }
        do {
            return try Data(contentsOf: hooksFileURL)
        } catch {
            throw BridgeError.readFailed(hooksFileURL.path, error.localizedDescription)
        }
    }

    private func optimisticRead() throws -> Data? {
        beforeOptimisticReRead?()
        return try readHooksData()
    }

    private func parseDocument(data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let document = object as? [String: Any] else {
                throw BridgeError.invalidStructure(hooksFileURL.path)
            }
            _ = try Self.hooksDictionary(from: document, path: hooksFileURL.path)
            return document
        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError.invalidJSON(hooksFileURL.path)
        }
    }

    private func writeDocument(_ document: [String: Any]) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: hooksFileURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hooksFileURL.path)
        } catch {
            throw BridgeError.writeFailed(hooksFileURL.path, error.localizedDescription)
        }
    }

    private static func containsAllNalaHooks(in document: [String: Any]) -> Bool {
        guard let hooks = try? hooksDictionary(from: document, path: "") else { return false }
        return hookEvents.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return containsNalaCommand(in: groups)
        }
    }

    private static func mergingNalaHooks(into document: [String: Any], path: String) throws -> [String: Any] {
        var document = document
        var hooks = try hooksDictionary(from: document, path: path)

        for event in hookEvents {
            var groups: [[String: Any]]
            if let existingGroups = hooks[event] {
                guard let typedGroups = existingGroups as? [[String: Any]] else {
                    throw BridgeError.invalidStructure(path)
                }
                groups = typedGroups
            } else {
                groups = []
            }

            if !containsNalaCommand(in: groups) {
                groups.append(nalaHookGroup())
            }
            hooks[event] = groups
        }

        document["hooks"] = hooks
        return document
    }

    private static func hooksDictionary(from document: [String: Any], path: String) throws -> [String: Any] {
        guard let hooks = document["hooks"] else { return [:] }
        guard let typedHooks = hooks as? [String: Any] else {
            throw BridgeError.invalidStructure(path)
        }
        return typedHooks
    }

    private static func containsNalaCommand(in groups: [[String: Any]]) -> Bool {
        groups.contains { group in
            guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
            return hooks.contains { hook in
                hook["type"] as? String == "command" &&
                    hook["command"] as? String == nalaHookCommand
            }
        }
    }

    private static func nalaHookGroup() -> [String: Any] {
        [
            "matcher": ".*",
            "hooks": [
                [
                    "type": "command",
                    "command": nalaHookCommand,
                ],
            ],
        ]
    }

    private static func runProcess(executablePath: String, args: [String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { process in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription))
            }
        }
    }
}
