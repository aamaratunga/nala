import Foundation
import os

/// Thread-safe file logger that writes to `~/.nala/hang.log`.
///
/// Unlike `os.Logger`, entries written here survive force-quit because each
/// write is followed by `synchronizeFile()`. This makes it the right place
/// for operational breadcrumbs that need to be available in post-mortem
/// hang investigation.
///
/// Usage:
/// ```
/// PersistentLog.shared.write("SESSION_LAUNCH agentType=claude dir=/foo", category: "SessionStore")
/// ```
///
/// The log file is automatically truncated when it exceeds 256KB (keeps the
/// last 128KB) to prevent unbounded growth.
final class PersistentLog: @unchecked Sendable {
    static let shared = PersistentLog()

    private let queue = DispatchQueue(label: "com.nala.persistent-log", qos: .utility)
    private var handle: FileHandle?
    private let logger = Logger(subsystem: "com.nala.app", category: "PersistentLog")

    private static let maxSize: UInt64 = 256 * 1024
    private static let keepSize: UInt64 = 128 * 1024

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let pid = ProcessInfo.processInfo.processIdentifier

    private init() {}

    /// Opens the log file, truncating if over size limit.
    /// Must be called on `queue`.
    func open() {
        queue.async { [self] in
            guard handle == nil else { return }
            performOpen()
        }
    }

    /// Appends a timestamped, PID-tagged line to the log and forces a disk sync.
    /// Safe to call from any thread.
    func write(_ message: String, category: String) {
        queue.async { [self] in
            ensureOpen()
            let timestamp = Self.timestampFormatter.string(from: Date())
            let line = "[\(timestamp)] [PID \(Self.pid)] [\(category)] \(message)\n"
            if let data = line.data(using: .utf8) {
                handle?.write(data)
                handle?.synchronizeFile()
            }
        }
    }

    /// Closes the file handle. Call on app termination.
    func close() {
        queue.async { [self] in
            handle?.closeFile()
            handle = nil
        }
    }

    // MARK: - Private

    private func ensureOpen() {
        // Called on queue
        if handle == nil {
            performOpen()
        }
    }

    private func performOpen() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.nala"
        let path = "\(dir)/hang.log"
        let fm = FileManager.default

        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        // Truncate if over limit — keep the tail
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64,
           size > Self.maxSize {
            if let fh = FileHandle(forReadingAtPath: path) {
                fh.seek(toFileOffset: size - Self.keepSize)
                let tail = fh.readDataToEndOfFile()
                fh.closeFile()
                fm.createFile(atPath: path, contents: tail, attributes: [.posixPermissions: 0o600])
            }
        }

        handle = FileHandle(forWritingAtPath: path)
        if handle == nil {
            logger.error("Failed to open hang log at: \(path)")
        }
        handle?.seekToEndOfFile()
    }
}
