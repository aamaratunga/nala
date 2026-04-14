import Foundation
import QuartzCore
import os

/// Detects main-thread hangs by periodically checking if the main run loop
/// is responsive. When a hang is detected, logs the duration and diagnostic
/// context to help identify the blocking code path.
///
/// Uses a background timer that dispatches a lightweight ping to the main
/// queue. If the ping isn't serviced within `hangThreshold`, the main thread
/// is considered hung and a warning is logged.
///
/// Hang events are written to `~/.nala/hang.log` in addition to os.Logger
/// because macOS unified logging is asynchronous — when the user force-quits
/// a hung process, in-flight os.Logger entries that haven't been flushed to
/// the log store are lost. Direct file writes survive force-quit.
///
/// Only active in DEBUG builds to avoid any overhead in release.
final class MainThreadWatchdog: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.nala.app", category: "Watchdog")
    private var timer: DispatchSourceTimer?

    /// How often the watchdog checks the main thread (seconds).
    private static let checkInterval: TimeInterval = 2.0

    /// How long the main thread must be unresponsive before logging (seconds).
    private static let hangThreshold: TimeInterval = 3.0

    /// Tracks whether we're currently in a detected hang to avoid spamming logs.
    private var hangStartTime: TimeInterval = 0

    /// File handle for the persistent hang log, kept open to avoid open/close
    /// overhead on each write. Writes are followed by `synchronizeFile()` to
    /// ensure data reaches disk before a potential force-quit.
    private var hangLogHandle: FileHandle?

    /// ISO 8601 formatter for hang log timestamps.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func start() {
        #if DEBUG
        openHangLog()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + Self.checkInterval,
            repeating: Self.checkInterval
        )
        timer.setEventHandler { [weak self] in
            self?.checkMainThread()
        }
        timer.resume()
        self.timer = timer
        logger.debug("MainThreadWatchdog started (check=\(Self.checkInterval)s, threshold=\(Self.hangThreshold)s)")
        #endif
    }

    func stop() {
        timer?.cancel()
        timer = nil
        hangLogHandle?.closeFile()
        hangLogHandle = nil
    }

    private func checkMainThread() {
        let pingStart = CACurrentMediaTime()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + Self.hangThreshold)
        if result == .timedOut {
            let elapsed = CACurrentMediaTime() - pingStart
            if hangStartTime == 0 {
                hangStartTime = pingStart
                let message = "MAIN THREAD HANG DETECTED: unresponsive for >\(String(format: "%.1f", elapsed))s. " +
                    "Check 'handleTmuxUpdate', 'reconcileOrder', 'startWatching', 'flushPendingData' signposts."
                logger.error("\(message)")
                writeToHangLog(message)
            } else {
                let totalHang = CACurrentMediaTime() - hangStartTime
                let message = "MAIN THREAD STILL HUNG: \(String(format: "%.1f", totalHang))s total"
                logger.error("\(message)")
                writeToHangLog(message)
            }
        } else {
            if hangStartTime != 0 {
                let totalHang = CACurrentMediaTime() - hangStartTime
                let message = "Main thread hang resolved after \(String(format: "%.1f", totalHang))s"
                logger.warning("\(message)")
                writeToHangLog(message)
                hangStartTime = 0
            }
        }
    }

    // MARK: - Persistent Hang Log

    /// Opens (or creates) the hang log file and seeks to the end for appending.
    private func openHangLog() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.nala"
        let path = "\(dir)/hang.log"
        let fm = FileManager.default

        // Ensure directory exists
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Create the file if it doesn't exist
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        // Truncate if over 256KB to prevent unbounded growth
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64,
           size > 256 * 1024 {
            // Keep last 128KB
            if let fh = FileHandle(forReadingAtPath: path) {
                fh.seek(toFileOffset: size - 128 * 1024)
                let tail = fh.readDataToEndOfFile()
                fh.closeFile()
                fm.createFile(atPath: path, contents: tail, attributes: [.posixPermissions: 0o600])
            }
        }

        hangLogHandle = FileHandle(forWritingAtPath: path)
        hangLogHandle?.seekToEndOfFile()
    }

    /// Appends a timestamped line to the hang log and forces a disk sync.
    /// Uses direct file I/O so the entry survives even if the process is
    /// force-quit immediately after.
    private func writeToHangLog(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let pid = ProcessInfo.processInfo.processIdentifier
        let line = "[\(timestamp)] [PID \(pid)] \(message)\n"
        if let data = line.data(using: .utf8) {
            hangLogHandle?.write(data)
            hangLogHandle?.synchronizeFile()
        }
    }
}
