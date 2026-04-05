import Foundation
import os

// MARK: - Data Types

struct AgentState: Equatable {
    var working: Bool = false
    var done: Bool = false
    var waitingForInput: Bool = false
    var stuck: Bool = false
    var sleeping: Bool = false
    var lastEventTime: Date?
    var latestEventType: String?
    var latestEventSummary: String?
    var waitingReason: String?
    var waitingSummary: String?
}

struct AgentStateUpdate: Equatable {
    let sessionId: String
    let state: AgentState
}

// MARK: - EventFileWatcher

final class EventFileWatcher: @unchecked Sendable {
    private let logger = os.Logger(subsystem: "com.nala.app", category: "EventFileWatcher")

    /// Base directory for event JSONL files
    static let eventsDirectory: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.nala/events"
    }()

    /// Staleness threshold in seconds (7 minutes)
    static let stalenessThreshold: TimeInterval = 420

    // MARK: - Per-Session Watcher State

    private class SessionWatcher {
        var sessionId: String
        var path: String
        var lastOffset: UInt64 = 0
        var fileDescriptor: Int32 = -1
        var source: DispatchSourceFileSystemObject?
        var partialLine: String = ""
        /// Internal state mutated only on watcherQueue. Use stateLock for cross-thread reads.
        var _currentState = AgentState()
        var latestEventType: String?
        var latestEventTime: Date?
        var latestSummary: String?

        /// Lock protecting cross-thread reads of _currentState.
        let stateLock = NSLock()

        /// Thread-safe getter: snapshot the current state under lock.
        var currentState: AgentState {
            get {
                stateLock.lock()
                defer { stateLock.unlock() }
                return _currentState
            }
            set {
                stateLock.lock()
                _currentState = newValue
                stateLock.unlock()
            }
        }

        init(sessionId: String, path: String) {
            self.sessionId = sessionId
            self.path = path
        }
    }

    private var watchers: [String: SessionWatcher] = [:]
    private let watchersLock = NSLock()
    private let watcherQueue = DispatchQueue(label: "com.nala.eventfilewatcher", qos: .utility)
    private var continuationIndex = 0
    private var continuations: [Int: AsyncStream<AgentStateUpdate>.Continuation] = [:]
    private let continuationsLock = NSLock()

    /// ISO 8601 date formatter for parsing event timestamps.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601FormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Initialization

    init() {
        // Create events directory if needed
        try? FileManager.default.createDirectory(
            atPath: Self.eventsDirectory,
            withIntermediateDirectories: true
        )
    }

    deinit {
        // DispatchSource crashes if deallocated while still resumed.
        // Ensure all sources are cancelled on any teardown path.
        let allWatchers = watchers
        watchers.removeAll()
        for (_, watcher) in allWatchers {
            watcher.source?.cancel()
        }
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
    }

    // MARK: - Public API

    /// Start watching events for a session.
    func startWatching(sessionId: String) {
        watchersLock.lock()
        guard watchers[sessionId] == nil else {
            watchersLock.unlock()
            return
        }

        let path = "\(Self.eventsDirectory)/\(sessionId).jsonl"
        let watcher = SessionWatcher(sessionId: sessionId, path: path)

        // If file exists, read from current position (process existing events for state recovery)
        if FileManager.default.fileExists(atPath: path) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let text = String(data: data, encoding: .utf8) {
                processEvents(text: text, watcher: watcher, emitUpdate: false)
                watcher.lastOffset = UInt64(data.count)
            }
        } else {
            // Create the file so dispatch source can watch it
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            watchersLock.unlock()
            logger.warning("Failed to open event file for watching: \(path)")
            return
        }

        watcher.fileDescriptor = fd
        setupDispatchSource(watcher: watcher)
        watchers[sessionId] = watcher
        watchersLock.unlock()

        // Emit initial state
        emitUpdate(watcher: watcher)
    }

    /// Stop watching events for a session.
    func stopWatching(sessionId: String) {
        watchersLock.lock()
        guard let watcher = watchers.removeValue(forKey: sessionId) else {
            watchersLock.unlock()
            return
        }
        watchersLock.unlock()
        watcher.source?.cancel()
        // FD is closed in setCancelHandler (set up in setupDispatchSource)
    }

    /// Stop all watchers.
    func stopAll() {
        watchersLock.lock()
        let allWatchers = watchers
        watchers.removeAll()
        watchersLock.unlock()
        for (_, watcher) in allWatchers {
            watcher.source?.cancel()
            // FD is closed in setCancelHandler
        }
        continuationsLock.lock()
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
        continuationsLock.unlock()
    }

    /// Get the current cached state for a session (thread-safe).
    /// Reads through a per-watcher lock instead of dispatching to the queue,
    /// avoiding main-thread blocking when the watcher queue is busy.
    func cachedState(for sessionId: String) -> AgentState? {
        watchersLock.lock()
        let watcher = watchers[sessionId]
        watchersLock.unlock()
        return watcher?.currentState
    }

    /// Stream of state updates from all watched sessions.
    func updates() -> AsyncStream<AgentStateUpdate> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            continuationsLock.lock()
            let id = continuationIndex
            continuationIndex += 1
            continuations[id] = continuation
            continuationsLock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.continuationsLock.lock()
                self?.continuations.removeValue(forKey: id)
                self?.continuationsLock.unlock()
            }
        }
    }

    /// Re-derive state for all watchers (call periodically to detect staleness).
    /// Dispatches onto watcherQueue to serialize with dispatch source event handlers.
    func refreshStaleness() {
        watcherQueue.async { [weak self] in
            guard let self else { return }
            self.watchersLock.lock()
            let allWatchers = Array(self.watchers.values)
            self.watchersLock.unlock()
            for watcher in allWatchers {
                let oldState = watcher.currentState
                self.deriveState(watcher: watcher)
                if watcher.currentState != oldState {
                    self.emitUpdate(watcher: watcher)
                }
            }
        }
    }

    // MARK: - Event Parsing

    /// Parse a single JSONL line as a Claude Code hook event.
    static func parseHookEvent(_ json: [String: Any]) -> (eventType: String, summary: String, waitingReason: String?, waitingSummary: String?)? {
        let hookType = json["hook_event_name"] as? String ?? json["type"] as? String ?? ""
        let toolName = json["tool_name"] as? String ?? ""

        // SessionStart with clear
        if hookType == "SessionStart" {
            return ("session_reset", "Session reset: /clear", nil, nil)
        }

        // UserPromptSubmit
        if hookType == "UserPromptSubmit" || (json["prompt"] != nil && toolName.isEmpty && json["stop_hook_active"] == nil) {
            let promptText = json["prompt"] as? String
            let summary: String
            if let text = promptText, !text.isEmpty {
                // Truncate long prompts for display
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                summary = "Prompt: \(String(trimmed.prefix(200)))"
            } else {
                summary = "User submitted prompt"
            }
            return ("prompt_submit", summary, nil, nil)
        }

        // Tool use
        if !toolName.isEmpty {
            let input = json["tool_input"] as? [String: Any] ?? [:]
            let summary = makeToolSummary(toolName: toolName, input: input)
            return ("tool_use", summary, nil, nil)
        }

        // Stop
        if hookType == "Stop" || json["stop_hook_active"] != nil {
            let reason = json["reason"] as? String ?? "unknown"
            return ("stop", "Agent stopped: \(reason)", nil, nil)
        }

        // Notification
        if hookType == "Notification" || json["message"] != nil {
            let message = json["message"] as? String ?? ""
            // "waiting for your input" is treated as stop (done)
            if message.lowercased().contains("waiting for your input") {
                return ("stop", "Agent stopped: waiting for input", nil, nil)
            }
            let truncated = message.count > 100 ? String(message.prefix(100)) + "..." : message
            return ("notification", "Notification: \(truncated)", message, truncated)
        }

        return nil
    }

    /// Generate a human-readable summary for a tool use event.
    private static func makeToolSummary(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Read":
            let fp = input["file_path"] as? String ?? ""
            let name = (fp as NSString).lastPathComponent
            return "Read \(name)"
        case "Write":
            let fp = input["file_path"] as? String ?? ""
            let name = (fp as NSString).lastPathComponent
            return "Wrote \(name)"
        case "Edit":
            let fp = input["file_path"] as? String ?? ""
            let name = (fp as NSString).lastPathComponent
            return "Edited \(name)"
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            let truncated = cmd.count > 80 ? String(cmd.prefix(80)) + "..." : cmd
            return "Ran: \(truncated)"
        case "Grep":
            let pattern = input["pattern"] as? String ?? ""
            return "Searched for '\(pattern.count > 40 ? String(pattern.prefix(40)) + "..." : pattern)'"
        case "Glob":
            let pattern = input["pattern"] as? String ?? ""
            return "Glob: \(pattern.count > 60 ? String(pattern.prefix(60)) + "..." : pattern)"
        case "Task":
            let desc = input["description"] as? String ?? ""
            return "Launched subagent: \(desc.count > 60 ? String(desc.prefix(60)) + "..." : desc)"
        default:
            return "Used \(toolName)"
        }
    }

    /// Parse event timestamp from JSON, falling back to current time.
    private static func parseTimestamp(from json: [String: Any]) -> Date {
        if let ts = json["timestamp"] as? String {
            if let date = iso8601Formatter.date(from: ts) { return date }
            if let date = iso8601FormatterNoFrac.date(from: ts) { return date }
        }
        if let ts = json["ts"] as? String {
            if let date = iso8601Formatter.date(from: ts) { return date }
            if let date = iso8601FormatterNoFrac.date(from: ts) { return date }
        }
        if let epoch = json["timestamp"] as? TimeInterval {
            return Date(timeIntervalSince1970: epoch)
        }
        return Date()
    }

    // MARK: - State Derivation

    /// Derive agent state flags from the latest event.
    /// Ported from live_sessions.py lines 186-195.
    private func deriveState(watcher: SessionWatcher) {
        var state = AgentState()
        state.latestEventType = watcher.latestEventType
        state.lastEventTime = watcher.latestEventTime
        state.latestEventSummary = watcher.latestSummary

        guard let eventType = watcher.latestEventType else {
            watcher.currentState = state
            return
        }

        switch eventType {
        case "tool_use", "prompt_submit":
            state.working = true

            // Check if sleeping: summary starts with "Ran: sleep"
            if let summary = watcher.latestSummary, summary.hasPrefix("Ran: sleep") {
                state.working = false
                state.sleeping = true
            }

            // Check staleness
            if let lastTime = watcher.latestEventTime {
                let elapsed = Date().timeIntervalSince(lastTime)
                if elapsed > Self.stalenessThreshold {
                    state.working = false
                    state.stuck = true
                }
            }

        case "notification":
            state.waitingForInput = true
            state.waitingReason = watcher.currentState.waitingReason
            state.waitingSummary = watcher.currentState.waitingSummary

        case "stop":
            state.done = true

        case "session_reset":
            // All flags false — fresh start
            break

        default:
            break
        }

        watcher.currentState = state
    }

    // MARK: - Internal

    private func setupDispatchSource(watcher: SessionWatcher) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watcher.fileDescriptor,
            eventMask: [.write, .extend],
            queue: watcherQueue
        )

        source.setEventHandler { [weak self, weak watcher] in
            guard let self, let watcher else { return }
            self.readNewContent(watcher: watcher)
        }

        // Capture FD by value — the watcher may be deallocated before this
        // handler fires (it runs asynchronously after source.cancel()).
        let fd = watcher.fileDescriptor
        source.setCancelHandler {
            if fd >= 0 { Darwin.close(fd) }
        }

        watcher.source = source
        source.resume()
    }

    private func readNewContent(watcher: SessionWatcher) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: watcher.path),
              let fileSize = attrs[.size] as? UInt64 else { return }

        // Handle truncation
        if fileSize < watcher.lastOffset {
            watcher.lastOffset = 0
            watcher.partialLine = ""
        }

        guard fileSize > watcher.lastOffset else { return }

        guard let fileHandle = FileHandle(forReadingAtPath: watcher.path) else { return }
        defer { fileHandle.closeFile() }

        fileHandle.seek(toFileOffset: watcher.lastOffset)
        let data = fileHandle.readData(ofLength: Int(fileSize - watcher.lastOffset))
        watcher.lastOffset = fileSize

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

        processEvents(text: text, watcher: watcher, emitUpdate: true)
    }

    private func processEvents(text: String, watcher: SessionWatcher, emitUpdate shouldEmit: Bool) {
        let fullText = watcher.partialLine + text
        let lines = fullText.split(separator: "\n", omittingEmptySubsequences: false)

        if text.hasSuffix("\n") {
            watcher.partialLine = ""
        } else if let last = lines.last {
            watcher.partialLine = String(last)
        }

        let completeLines = text.hasSuffix("\n") ? lines : lines.dropLast()
        var stateChanged = false

        for line in completeLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Try parsing as a single JSON object first (fast path)
            let jsonObjects: [[String: Any]]
            if let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                jsonObjects = [json]
            } else {
                // Fallback: line may contain concatenated JSON objects without
                // newline separators (e.g., {...}{...}{...}). Split by tracking
                // brace depth, respecting string literals.
                jsonObjects = Self.splitConcatenatedJSON(trimmed)
            }

            for json in jsonObjects {
                guard let parsed = Self.parseHookEvent(json) else { continue }

                let oldState = watcher.currentState
                watcher.latestEventType = parsed.eventType
                watcher.latestEventTime = Self.parseTimestamp(from: json)
                watcher.latestSummary = parsed.summary

                if let wr = parsed.waitingReason {
                    watcher.currentState.waitingReason = wr
                }
                if let ws = parsed.waitingSummary {
                    watcher.currentState.waitingSummary = ws
                }

                deriveState(watcher: watcher)
                if watcher.currentState != oldState {
                    stateChanged = true
                }
            }
        }

        if stateChanged && shouldEmit {
            emitUpdate(watcher: watcher)
        }
    }

    /// Split a string containing concatenated JSON objects (e.g., `{...}{...}`)
    /// into individual objects by tracking brace depth. Handles nested braces
    /// and string literals correctly.
    static func splitConcatenatedJSON(_ text: String) -> [[String: Any]] {
        var results: [[String: Any]] = []
        var depth = 0
        var inString = false
        var escape = false
        var startIndex = text.startIndex

        for i in text.indices {
            let c = text[i]

            if escape {
                escape = false
                continue
            }
            if c == "\\" && inString {
                escape = true
                continue
            }
            if c == "\"" {
                inString = !inString
                continue
            }
            if inString { continue }

            if c == "{" {
                if depth == 0 { startIndex = i }
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let endIndex = text.index(after: i)
                    let objectStr = String(text[startIndex..<endIndex])
                    if let data = objectStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        results.append(json)
                    }
                }
            }
        }

        return results
    }

    private func emitUpdate(watcher: SessionWatcher) {
        let update = AgentStateUpdate(sessionId: watcher.sessionId, state: watcher.currentState)
        continuationsLock.lock()
        let conts = Array(continuations.values)
        continuationsLock.unlock()
        for c in conts {
            c.yield(update)
        }
    }
}
