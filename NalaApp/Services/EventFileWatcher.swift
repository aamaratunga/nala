import Foundation
import QuartzCore
import os

// MARK: - Data Types

struct AgentStateUpdate: Equatable {
    let sessionId: String
    let event: StateEvent
}

// MARK: - EventFileWatcher

final class EventFileWatcher: @unchecked Sendable {
    private let logger = os.Logger(subsystem: "com.nala.app", category: "EventFileWatcher")

    /// Base directory for event JSONL files
    static let eventsDirectory: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.nala/events"
    }()

    // MARK: - Per-Session Watcher State

    private class SessionWatcher {
        var sessionId: String
        var path: String
        var lastOffset: UInt64 = 0
        var fileDescriptor: Int32 = -1
        var source: DispatchSourceFileSystemObject?
        var partialLine: String = ""
        var transcriptPath: String?
        var transcriptLastOffset: UInt64 = 0
        var transcriptFileDescriptor: Int32 = -1
        var transcriptSource: DispatchSourceFileSystemObject?
        var transcriptPartialLine: String = ""
        var openQuestionCallIds: Set<String> = []
        /// Cached agent status, mutated only on watcherQueue. Use stateLock for cross-thread reads.
        var _currentStatus: AgentStatus = .idle
        var latestEventType: String?
        var latestEventTime: Date?
        var latestSummary: String?
        var waitingReason: String?
        var waitingSummary: String?
        /// Whether the first live event has been logged for launch timing.
        var firstEventLogged = false

        /// Lock protecting cross-thread reads of _currentStatus.
        let stateLock = NSLock()

        /// Thread-safe getter: snapshot the current status under lock.
        var currentStatus: AgentStatus {
            get {
                stateLock.lock()
                defer { stateLock.unlock() }
                return _currentStatus
            }
            set {
                stateLock.lock()
                _currentStatus = newValue
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

    private enum TranscriptRecordEvent {
        case questionRequest(callId: String, summary: String, timestamp: Date)
        case questionAnswered(callId: String, timestamp: Date)
    }

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
            cancelTranscriptWatcher(watcher)
        }
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
    }

    // MARK: - Public API

    /// Start watching events for a session.
    ///
    /// Registers the watcher immediately (so `cachedStatus` returns a default
    /// state) but performs all file I/O — tail recovery, file creation, fd open,
    /// dispatch source setup — on the background `watcherQueue`. This keeps
    /// `handleTmuxUpdate` (which calls this from the main thread) responsive.
    func startWatching(sessionId: String) {
        watchersLock.lock()
        guard watchers[sessionId] == nil else {
            watchersLock.unlock()
            return
        }

        let path = "\(Self.eventsDirectory)/\(sessionId).jsonl"
        let watcher = SessionWatcher(sessionId: sessionId, path: path)
        watchers[sessionId] = watcher
        watchersLock.unlock()

        // File I/O on background queue — never block the main thread.
        watcherQueue.async { [weak self] in
            guard let self else { return }
            let watchStart = CACurrentMediaTime()

            // Recover state from the tail of the file (only last ~256KB).
            if FileManager.default.fileExists(atPath: path) {
                self.recoverStateFromTail(watcher: watcher)
            } else {
                // Create the file so dispatch source can watch it
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }

            // Check if the watcher was removed while we were doing I/O
            // (e.g., stopWatching called before we finished setup)
            self.watchersLock.lock()
            guard self.watchers[sessionId] === watcher else {
                self.watchersLock.unlock()
                self.cancelTranscriptWatcher(watcher)
                return
            }
            self.watchersLock.unlock()

            let fd = open(path, O_RDONLY | O_NONBLOCK)
            guard fd >= 0 else {
                self.logger.warning("Failed to open event file for watching: \(path)")
                self.watchersLock.lock()
                self.watchers.removeValue(forKey: sessionId)
                self.watchersLock.unlock()
                return
            }

            watcher.fileDescriptor = fd
            self.setupDispatchSource(watcher: watcher)

            // Emit initial status
            self.emitUpdate(watcher: watcher, event: .polledState(status: watcher._currentStatus))

            let watchElapsed = CACurrentMediaTime() - watchStart
            if watchElapsed > 0.01 {
                self.logger.warning("startWatching took \(String(format: "%.1f", watchElapsed * 1000))ms for \(sessionId)")
            }
        }
    }

    /// Read only the tail of the event file to recover the latest agent state.
    /// Avoids reading multi-megabyte files on the main thread when only the
    /// last few events are needed for state derivation.
    private func recoverStateFromTail(watcher: SessionWatcher) {
        let recoverStart = CACurrentMediaTime()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: watcher.path),
              let fileSize = attrs[.size] as? UInt64,
              fileSize > 0 else { return }

        // 256KB covers the largest observed events (~38KB) with generous headroom.
        // State recovery only needs the last event.
        let tailSize: UInt64 = min(fileSize, 256 * 1024)
        let readOffset = fileSize - tailSize

        guard let fh = FileHandle(forReadingAtPath: watcher.path) else { return }
        defer { fh.closeFile() }

        fh.seek(toFileOffset: readOffset)
        let data = fh.readData(ofLength: Int(tailSize))
        watcher.lastOffset = fileSize // Dispatch source reads only new content from here

        // Use lossy UTF-8 decoding: reading from an arbitrary offset can split
        // a multibyte character, and strict decoding would fail on the entire
        // buffer. The first partial line is skipped anyway.
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return }

        // If we started mid-file, skip the first (potentially partial) line
        var processText = text
        if readOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
            processText = String(text[text.index(after: firstNewline)...])
        }

        processEvents(text: processText, watcher: watcher, emitUpdate: false)

        let recoverElapsed = CACurrentMediaTime() - recoverStart
        if recoverElapsed > 0.01 {
            logger.warning("recoverStateFromTail took \(String(format: "%.1f", recoverElapsed * 1000))ms for \(watcher.sessionId) (read \(tailSize) of \(fileSize) bytes)")
        }

        if watcher.latestEventType == nil {
            logger.warning("recoverStateFromTail: no events parsed from \(watcher.path) (tail \(tailSize) bytes of \(fileSize))")
        }
    }

    /// Stop watching events for a session.
    /// Safe to call even if the watcher is still being set up on the queue —
    /// removing it from `watchers` causes the pending setup to bail out.
    func stopWatching(sessionId: String) {
        watchersLock.lock()
        guard let watcher = watchers.removeValue(forKey: sessionId) else {
            watchersLock.unlock()
            return
        }
        watchersLock.unlock()
        if let source = watcher.source {
            source.cancel()
            // FD is closed in setCancelHandler (set up in setupDispatchSource)
        } else if watcher.fileDescriptor >= 0 {
            // Setup was interrupted before dispatch source was created
            Darwin.close(watcher.fileDescriptor)
        }
        watcherQueue.async { [weak self] in
            guard let self else { return }
            self.cancelTranscriptWatcher(watcher)
        }
    }

    /// Stop all watchers.
    func stopAll() {
        watchersLock.lock()
        let allWatchers = watchers
        watchers.removeAll()
        watchersLock.unlock()
        for (_, watcher) in allWatchers {
            watcher.source?.cancel()
            cancelTranscriptWatcher(watcher)
            // FD is closed in setCancelHandler
        }
        continuationsLock.lock()
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
        continuationsLock.unlock()
    }

    /// Get the current cached status for a session (thread-safe).
    /// Reads through a per-watcher lock instead of dispatching to the queue,
    /// avoiding main-thread blocking when the watcher queue is busy.
    func cachedStatus(for sessionId: String) -> AgentStatus? {
        watchersLock.lock()
        let watcher = watchers[sessionId]
        watchersLock.unlock()
        return watcher?.currentStatus
    }

    /// Set cached status for a session to a specific value.
    /// Called for optimistic state transitions (e.g., permission accepted)
    /// to prevent tmux polling from reverting the status.
    func setCachedStatus(for sessionId: String, to status: AgentStatus) {
        watchersLock.lock()
        let watcher = watchers[sessionId]
        watchersLock.unlock()
        guard let watcher else { return }
        watcher.currentStatus = status
    }

    /// Reset cached status for a session to idle.
    /// Called when the user cancels an agent to prevent stale working status
    /// from being re-applied by tmux polling.
    func resetCachedStatus(for sessionId: String) {
        watchersLock.lock()
        let watcher = watchers[sessionId]
        watchersLock.unlock()
        guard let watcher else { return }
        // Set idle status immediately (thread-safe via stateLock)
        watcher.currentStatus = .idle
        // Clear watcher internals on the correct queue to prevent re-derivation
        watcherQueue.async {
            watcher.latestEventType = nil
            watcher.latestSummary = nil
            watcher.waitingReason = nil
            watcher.waitingSummary = nil
        }
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

    /// Block until all pending work on the watcher queue has completed.
    /// Used by tests to wait for async `startWatching` setup to finish.
    func flushQueue() {
        watcherQueue.sync {}
    }

    /// Re-read event files as a safety net for missed kqueue notifications.
    /// Dispatches onto watcherQueue to serialize with dispatch source event handlers.
    func refreshStaleness() {
        watcherQueue.async { [weak self] in
            guard let self else { return }
            self.watchersLock.lock()
            let allWatchers = Array(self.watchers.values)
            self.watchersLock.unlock()
            for watcher in allWatchers {
                // Safety net: re-read the file in case a kqueue notification
                // was dropped under high system load.
                self.readNewContent(watcher: watcher)
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

        // PermissionRequest — fires when Claude Code shows a permission dialog.
        // Must be checked before the generic tool_name check (carries tool_name).
        // Maps to "permission_request" event type → waitingForInput state.
        if hookType == "PermissionRequest" && !toolName.isEmpty {
            let input = json["tool_input"] as? [String: Any] ?? [:]
            let summary = "Permission required: \(makeToolSummary(toolName: toolName, input: input))"
            return ("permission_request", summary, summary, summary)
        }

        // PreToolUse — must be checked before the generic tool_name check below,
        // because PreToolUse events also carry tool_name and would otherwise be
        // parsed as "tool_use".
        if hookType == "PreToolUse" && !toolName.isEmpty {
            let input = json["tool_input"] as? [String: Any] ?? [:]
            if toolName == "AskUserQuestion" {
                // Extract question text from tool_input.questions[0].question
                let questionText: String
                if let questions = input["questions"] as? [[String: Any]],
                   let first = questions.first,
                   let text = first["question"] as? String, !text.isEmpty {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    questionText = String(trimmed.prefix(200))
                } else {
                    questionText = "Asking a question"
                }
                return ("pre_tool_use", questionText, questionText, questionText)
            }
            let summary = makeToolSummary(toolName: toolName, input: input)
            return ("pre_tool_use", summary, nil, nil)
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

        return nil
    }

    private static func extractTranscriptPath(from json: [String: Any]) -> String? {
        let keys = ["transcript_path", "transcriptPath"]
        for key in keys {
            if let path = json[key] as? String, !path.isEmpty {
                return (path as NSString).expandingTildeInPath
            }
        }

        if let session = json["session"] as? [String: Any] {
            for key in keys {
                if let path = session[key] as? String, !path.isEmpty {
                    return (path as NSString).expandingTildeInPath
                }
            }
        }

        return nil
    }

    private static func parseTranscriptRecord(_ json: [String: Any]) -> TranscriptRecordEvent? {
        guard let payload = transcriptPayload(from: json) else { return nil }
        let payloadType = payload["type"] as? String ?? ""
        let timestamp = parseTranscriptTimestamp(json: json, payload: payload)

        if payloadType == "function_call",
           payload["name"] as? String == "request_user_input",
           let callId = transcriptCallId(from: payload) {
            let summary = questionSummary(from: payload["arguments"] ?? payload["input"])
            return .questionRequest(callId: callId, summary: summary, timestamp: timestamp)
        }

        if payloadType == "function_call_output",
           let callId = transcriptCallId(from: payload) {
            return .questionAnswered(callId: callId, timestamp: timestamp)
        }

        return nil
    }

    private static func transcriptPayload(from json: [String: Any]) -> [String: Any]? {
        if json["type"] as? String == "response_item" {
            return json["payload"] as? [String: Any] ?? json["item"] as? [String: Any]
        }

        if let payload = json["payload"] as? [String: Any],
           payload["type"] as? String == "response_item" {
            return payload["payload"] as? [String: Any] ?? payload["item"] as? [String: Any]
        }

        return nil
    }

    private static func transcriptCallId(from payload: [String: Any]) -> String? {
        for key in ["call_id", "callId", "id"] {
            if let callId = payload[key] as? String, !callId.isEmpty {
                return callId
            }
        }
        return nil
    }

    private static func questionSummary(from rawArguments: Any?) -> String {
        let arguments: [String: Any]
        if let dict = rawArguments as? [String: Any] {
            arguments = dict
        } else if let string = rawArguments as? String,
                  let data = string.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = dict
        } else {
            arguments = [:]
        }

        let directQuestions = arguments["questions"] as? [[String: Any]]
        let nestedInput = arguments["input"] as? [String: Any]
        let nestedQuestions = nestedInput?["questions"] as? [[String: Any]]
        let questions = directQuestions ?? nestedQuestions
        if let text = questions?.first?["question"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(200))
            }
        }

        return "Asking a question"
    }

    private static func parseTranscriptTimestamp(json: [String: Any], payload: [String: Any]) -> Date {
        if json["timestamp"] != nil || json["ts"] != nil {
            return parseTimestamp(from: json)
        }
        return parseTimestamp(from: payload)
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
        case "apply_patch":
            return "Applied patch"
        case "web_search":
            let query = input["query"] as? String ?? ""
            guard !query.isEmpty else { return "Searched web" }
            return "Searched web for '\(query.count > 40 ? String(query.prefix(40)) + "..." : query)'"
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

    // MARK: - Event Conversion

    /// Convert a parsed hook event to a StateEvent.
    private static func makeStateEvent(
        from parsed: (eventType: String, summary: String, waitingReason: String?, waitingSummary: String?),
        toolName: String,
        timestamp: Date
    ) -> StateEvent {
        switch parsed.eventType {
        case "tool_use":
            // Sleep detection: "Ran: sleep" summary triggers sleepDetected
            if parsed.summary.hasPrefix("Ran: sleep") {
                return .sleepDetected(summary: parsed.summary, timestamp: timestamp)
            }
            return .toolUse(tool: toolName, summary: parsed.summary, timestamp: timestamp)
        case "pre_tool_use":
            return .preToolUse(tool: toolName, summary: parsed.summary, timestamp: timestamp)
        case "prompt_submit":
            return .promptSubmit(summary: parsed.summary, timestamp: timestamp)
        case "stop":
            return .stop(reason: parsed.summary, timestamp: timestamp)
        case "permission_request":
            return .permissionRequest(
                tool: toolName,
                summary: parsed.summary,
                waitingReason: parsed.waitingReason,
                waitingSummary: parsed.waitingSummary,
                timestamp: timestamp
            )
        case "session_reset":
            return .sessionReset
        default:
            return .toolUse(tool: toolName, summary: parsed.summary, timestamp: timestamp)
        }
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

    private func ensureTranscriptWatcher(path: String, watcher: SessionWatcher, emitRecovered: Bool) {
        let expandedPath = (path as NSString).expandingTildeInPath
        if watcher.transcriptPath == expandedPath, watcher.transcriptSource != nil {
            return
        }

        cancelTranscriptWatcher(watcher)
        watcher.transcriptPath = expandedPath
        watcher.transcriptLastOffset = 0
        watcher.transcriptPartialLine = ""
        watcher.openQuestionCallIds.removeAll()

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            logger.debug("Transcript path does not exist for \(watcher.sessionId): \(expandedPath)")
            return
        }

        recoverTranscriptStateFromTail(watcher: watcher, emitUpdate: emitRecovered)

        let fd = open(expandedPath, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            logger.warning("Failed to open transcript file for watching: \(expandedPath)")
            return
        }

        watcher.transcriptFileDescriptor = fd
        setupTranscriptDispatchSource(watcher: watcher)
    }

    private func recoverTranscriptStateFromTail(watcher: SessionWatcher, emitUpdate shouldEmit: Bool) {
        guard let transcriptPath = watcher.transcriptPath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
              let fileSize = attrs[.size] as? UInt64,
              fileSize > 0 else { return }

        let tailSize: UInt64 = min(fileSize, 256 * 1024)
        let readOffset = fileSize - tailSize

        guard let fh = FileHandle(forReadingAtPath: transcriptPath) else { return }
        defer { fh.closeFile() }

        fh.seek(toFileOffset: readOffset)
        let data = fh.readData(ofLength: Int(tailSize))
        watcher.transcriptLastOffset = fileSize

        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return }

        var processText = text
        if readOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
            processText = String(text[text.index(after: firstNewline)...])
        }

        processTranscriptEvents(text: processText, watcher: watcher, emitUpdate: shouldEmit)
    }

    private func setupTranscriptDispatchSource(watcher: SessionWatcher) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watcher.transcriptFileDescriptor,
            eventMask: [.write, .extend],
            queue: watcherQueue
        )

        source.setEventHandler { [weak self, weak watcher] in
            guard let self, let watcher else { return }
            self.readNewTranscriptContent(watcher: watcher)
        }

        let fd = watcher.transcriptFileDescriptor
        source.setCancelHandler {
            if fd >= 0 { Darwin.close(fd) }
        }

        watcher.transcriptSource = source
        source.resume()
    }

    private func cancelTranscriptWatcher(_ watcher: SessionWatcher) {
        if let source = watcher.transcriptSource {
            source.cancel()
        } else if watcher.transcriptFileDescriptor >= 0 {
            Darwin.close(watcher.transcriptFileDescriptor)
        }

        watcher.transcriptSource = nil
        watcher.transcriptFileDescriptor = -1
        watcher.transcriptPath = nil
        watcher.transcriptLastOffset = 0
        watcher.transcriptPartialLine = ""
        watcher.openQuestionCallIds.removeAll()
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

    private func readNewTranscriptContent(watcher: SessionWatcher) {
        guard let transcriptPath = watcher.transcriptPath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
              let fileSize = attrs[.size] as? UInt64 else { return }

        if fileSize < watcher.transcriptLastOffset {
            watcher.transcriptLastOffset = 0
            watcher.transcriptPartialLine = ""
            watcher.openQuestionCallIds.removeAll()
        }

        guard fileSize > watcher.transcriptLastOffset else { return }

        guard let fileHandle = FileHandle(forReadingAtPath: transcriptPath) else { return }
        defer { fileHandle.closeFile() }

        fileHandle.seek(toFileOffset: watcher.transcriptLastOffset)
        let data = fileHandle.readData(ofLength: Int(fileSize - watcher.transcriptLastOffset))
        watcher.transcriptLastOffset = fileSize

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

        processTranscriptEvents(text: text, watcher: watcher, emitUpdate: true)
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
                if let transcriptPath = Self.extractTranscriptPath(from: json) {
                    ensureTranscriptWatcher(path: transcriptPath, watcher: watcher, emitRecovered: shouldEmit)
                }

                guard let parsed = Self.parseHookEvent(json) else { continue }

                if parsed.eventType == "stop", !watcher.openQuestionCallIds.isEmpty {
                    logger.debug("Suppressing Stop hook while Codex question is open for \(watcher.sessionId)")
                    continue
                }

                let timestamp = Self.parseTimestamp(from: json)
                let toolName = json["tool_name"] as? String ?? ""

                // Update watcher metadata
                watcher.latestEventType = parsed.eventType
                watcher.latestEventTime = timestamp
                watcher.latestSummary = parsed.summary

                if let wr = parsed.waitingReason {
                    watcher.waitingReason = wr
                }
                if let ws = parsed.waitingSummary {
                    watcher.waitingSummary = ws
                }

                // Convert to StateEvent and run through reducer
                let stateEvent = Self.makeStateEvent(from: parsed, toolName: toolName, timestamp: timestamp)
                let transition = StateReducer.reduce(current: watcher._currentStatus, event: stateEvent, source: .eventWatcher)
                watcher._currentStatus = transition.to

                // Log first live event for launch-to-operational timing
                if shouldEmit && !watcher.firstEventLogged {
                    watcher.firstEventLogged = true
                    let sinceLaunch = SessionStore.launchTimestamps[watcher.sessionId].map {
                        " sincelaunch=\(String(format: "%.0f", (CACurrentMediaTime() - $0) * 1000))ms"
                    } ?? ""
                    PersistentLog.shared.write(
                        "AGENT_FIRST_EVENT type=\(parsed.eventType) session=\(watcher.sessionId)\(sinceLaunch)",
                        category: "EventFileWatcher"
                    )
                }

                // Emit every parsed event so metadata updates (latestEventSummary,
                // stalenessSeconds, activityLog) reach SessionStore even when
                // the status doesn't change (e.g., working → working on
                // consecutive tool_use events). Status dedup happens in
                // SessionStore's dispatchStateEvent via the reducer.
                if shouldEmit {
                    emitUpdate(watcher: watcher, event: stateEvent)
                }
            }
        }
    }

    private func processTranscriptEvents(text: String, watcher: SessionWatcher, emitUpdate shouldEmit: Bool) {
        let fullText = watcher.transcriptPartialLine + text
        let lines = fullText.split(separator: "\n", omittingEmptySubsequences: false)

        if text.hasSuffix("\n") {
            watcher.transcriptPartialLine = ""
        } else if let last = lines.last {
            watcher.transcriptPartialLine = String(last)
        }

        let completeLines = text.hasSuffix("\n") ? lines : lines.dropLast()

        for line in completeLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let jsonObjects: [[String: Any]]
            if let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                jsonObjects = [json]
            } else {
                jsonObjects = Self.splitConcatenatedJSON(trimmed)
            }

            for json in jsonObjects {
                guard let transcriptEvent = Self.parseTranscriptRecord(json) else { continue }

                let stateEvent: StateEvent
                let eventType: String
                let summary: String?
                let eventTimestamp: Date

                switch transcriptEvent {
                case .questionRequest(let callId, let questionSummary, let timestamp):
                    guard !watcher.openQuestionCallIds.contains(callId) else { continue }
                    watcher.openQuestionCallIds.insert(callId)
                    watcher.waitingReason = questionSummary
                    watcher.waitingSummary = questionSummary
                    stateEvent = .questionRequest(summary: questionSummary, timestamp: timestamp)
                    eventType = "question_request"
                    summary = questionSummary
                    eventTimestamp = timestamp

                case .questionAnswered(let callId, let timestamp):
                    guard watcher.openQuestionCallIds.remove(callId) != nil else { continue }
                    stateEvent = .questionAnswered(timestamp: timestamp)
                    eventType = "question_answered"
                    summary = "Question answered"
                    eventTimestamp = timestamp
                }

                watcher.latestEventType = eventType
                watcher.latestEventTime = eventTimestamp
                if let summary {
                    watcher.latestSummary = summary
                }

                let transition = StateReducer.reduce(current: watcher._currentStatus, event: stateEvent, source: .eventWatcher)
                watcher._currentStatus = transition.to

                if shouldEmit && !watcher.firstEventLogged {
                    watcher.firstEventLogged = true
                    let sinceLaunch = SessionStore.launchTimestamps[watcher.sessionId].map {
                        " sincelaunch=\(String(format: "%.0f", (CACurrentMediaTime() - $0) * 1000))ms"
                    } ?? ""
                    PersistentLog.shared.write(
                        "AGENT_FIRST_EVENT type=\(eventType) session=\(watcher.sessionId)\(sinceLaunch)",
                        category: "EventFileWatcher"
                    )
                }

                if shouldEmit {
                    emitUpdate(watcher: watcher, event: stateEvent)
                }
            }
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

    private func emitUpdate(watcher: SessionWatcher, event: StateEvent) {
        let update = AgentStateUpdate(sessionId: watcher.sessionId, event: event)
        continuationsLock.lock()
        let conts = Array(continuations.values)
        continuationsLock.unlock()
        for c in conts {
            c.yield(update)
        }
    }
}
