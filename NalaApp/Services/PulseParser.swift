import Foundation
import os

// MARK: - Data Types

struct PulseResult: Equatable {
    var status: String?
    var summary: String?
    var confidence: String?
}

struct PulseUpdate: Equatable {
    let sessionName: String
    let result: PulseResult
}

// MARK: - PulseParser

final class PulseParser: @unchecked Sendable {
    private let logger = os.Logger(subsystem: "com.nala.app", category: "PulseParser")

    // MARK: - ANSI Stripping

    /// Matches ANSI escape sequences: OSC, CSI, and Fe sequences.
    /// Ported from Python session_manager.py lines 30-36.
    static let ansiPattern = try! NSRegularExpression(
        pattern: #"\x1B(?:\][^\x07\x1B]*(?:\x07|\x1B\\)?|\[[0-?]*[ -/]*[@-~]|[@-Z\\-_])"#
    )

    /// Matches stray control characters left after partial sequences.
    static let controlCharPattern = try! NSRegularExpression(
        pattern: #"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]"#
    )

    /// Remove ANSI escape sequences and control characters from text.
    static func stripANSI(_ input: String) -> String {
        let mutable = NSMutableString(string: input)
        ansiPattern.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length), withTemplate: " ")
        controlCharPattern.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length), withTemplate: "")
        return mutable as String
    }

    // MARK: - PULSE Regex Matchers

    static let statusPattern = try! NSRegularExpression(pattern: #"\|\|PULSE:STATUS (.*?)\|\|"#, options: .dotMatchesLineSeparators)
    static let summaryPattern = try! NSRegularExpression(pattern: #"\|\|PULSE:SUMMARY (.*?)\|\|"#, options: .dotMatchesLineSeparators)
    static let confidencePattern = try! NSRegularExpression(pattern: #"\|\|PULSE:CONFIDENCE (.*?)\|\|"#, options: .dotMatchesLineSeparators)

    /// Parse PULSE events from text, returning the latest status, summary, and confidence.
    static func parsePulseEvents(from text: String) -> PulseResult {
        var result = PulseResult()

        // Find the last match for each pattern
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        let statusMatches = statusPattern.matches(in: text, range: range)
        if let last = statusMatches.last {
            result.status = cleanMatch(nsText.substring(with: last.range(at: 1)))
        }

        let summaryMatches = summaryPattern.matches(in: text, range: range)
        if let last = summaryMatches.last {
            result.summary = cleanMatch(nsText.substring(with: last.range(at: 1)))
        }

        let confidenceMatches = confidencePattern.matches(in: text, range: range)
        if let last = confidenceMatches.last {
            result.confidence = cleanMatch(nsText.substring(with: last.range(at: 1)))
        }

        return result
    }

    /// Collapse whitespace runs into a single space. Returns empty for template text.
    static func cleanMatch(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Skip template/instruction text with angle-bracket placeholders
        if collapsed.contains("<") && collapsed.contains(">") {
            return ""
        }
        return collapsed
    }

    // MARK: - File Watching

    /// Per-file watcher state
    private class FileWatcher {
        var path: String
        var sessionName: String
        var lastOffset: UInt64 = 0
        var fileDescriptor: Int32 = -1
        var source: DispatchSourceFileSystemObject?
        var partialLine: String = ""
        /// Internal state mutated only on watcherQueue. Use resultLock for cross-thread reads.
        var _currentResult = PulseResult()

        /// Lock protecting cross-thread reads of _currentResult.
        let resultLock = NSLock()

        /// Thread-safe getter: snapshot the current result under lock.
        var currentResult: PulseResult {
            get {
                resultLock.lock()
                defer { resultLock.unlock() }
                return _currentResult
            }
            set {
                resultLock.lock()
                _currentResult = newValue
                resultLock.unlock()
            }
        }

        init(path: String, sessionName: String) {
            self.path = path
            self.sessionName = sessionName
        }
    }

    private var watchers: [String: FileWatcher] = [:]
    private let watchersLock = NSLock()
    private let watcherQueue = DispatchQueue(label: "com.nala.pulseparser", qos: .utility)
    private var continuationIndex = 0
    private var continuations: [Int: AsyncStream<PulseUpdate>.Continuation] = [:]
    private let continuationsLock = NSLock()

    deinit {
        // DispatchSource crashes if deallocated while still resumed.
        let allWatchers = watchers
        watchers.removeAll()
        for (_, watcher) in allWatchers {
            watcher.source?.cancel()
        }
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
    }

    /// Start watching a log file for a session.
    func startWatching(sessionName: String, logPath: String) {
        watchersLock.lock()
        guard watchers[sessionName] == nil else {
            watchersLock.unlock()
            return
        }

        let watcher = FileWatcher(path: logPath, sessionName: sessionName)

        // If file already exists, start from the end (only parse new content)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? UInt64 {
            watcher.lastOffset = size
        }

        let fd = open(logPath, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            // File might not exist yet — create it so the dispatch source has something to watch
            FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
            let fd2 = open(logPath, O_RDONLY | O_NONBLOCK)
            guard fd2 >= 0 else {
                watchersLock.unlock()
                logger.warning("Failed to open log file for watching: \(logPath)")
                return
            }
            watcher.fileDescriptor = fd2
            setupDispatchSource(watcher: watcher)
            watchers[sessionName] = watcher
            watchersLock.unlock()
            return
        }

        watcher.fileDescriptor = fd
        setupDispatchSource(watcher: watcher)
        watchers[sessionName] = watcher
        watchersLock.unlock()
    }

    /// Stop watching a session's log file.
    func stopWatching(sessionName: String) {
        watchersLock.lock()
        guard let watcher = watchers.removeValue(forKey: sessionName) else {
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

    /// Get the current cached pulse result for a session (thread-safe).
    /// Reads through a per-watcher lock instead of dispatching to the queue,
    /// avoiding main-thread blocking when the watcher queue is busy.
    func cachedResult(for sessionName: String) -> PulseResult? {
        watchersLock.lock()
        let watcher = watchers[sessionName]
        watchersLock.unlock()
        return watcher?.currentResult
    }

    /// Stream of pulse updates from all watched files.
    func updates() -> AsyncStream<PulseUpdate> {
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

    // MARK: - Internal

    private func setupDispatchSource(watcher: FileWatcher) {
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

    private func readNewContent(watcher: FileWatcher) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: watcher.path),
              let fileSize = attrs[.size] as? UInt64 else { return }

        // Handle file truncation
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

        // Prepend any partial line from the previous read
        let fullText = watcher.partialLine + text

        // Split into lines, keeping the last incomplete line as partial
        let lines = fullText.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") {
            watcher.partialLine = ""
        } else if let last = lines.last {
            watcher.partialLine = String(last)
        }

        // Process complete lines
        let completeLines = text.hasSuffix("\n") ? lines : lines.dropLast()
        guard !completeLines.isEmpty else { return }

        let joined = completeLines.joined(separator: "\n")
        let stripped = Self.stripANSI(String(joined))
        let parsed = Self.parsePulseEvents(from: stripped)

        // Update cached result with any new values
        var changed = false
        if let status = parsed.status, status != watcher.currentResult.status {
            watcher.currentResult.status = status
            changed = true
        }
        if let summary = parsed.summary, summary != watcher.currentResult.summary {
            watcher.currentResult.summary = summary
            changed = true
        }
        if let confidence = parsed.confidence, confidence != watcher.currentResult.confidence {
            watcher.currentResult.confidence = confidence
            changed = true
        }

        guard changed else { return }

        let update = PulseUpdate(sessionName: watcher.sessionName, result: watcher.currentResult)
        continuationsLock.lock()
        let conts = Array(continuations.values)
        continuationsLock.unlock()
        for c in conts {
            c.yield(update)
        }
    }
}
