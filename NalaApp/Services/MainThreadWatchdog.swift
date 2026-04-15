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
/// Detects two classes of hang:
/// 1. **Full block** — main thread completely unresponsive for >3s (the ping
///    times out). Logged as `MAIN THREAD HANG DETECTED`.
/// 2. **Busy-hung** — main thread processes the ping but with high latency
///    (>200ms), indicating the run loop is saturated with work items and
///    user events are being starved. Logged as `MAIN THREAD OVERLOADED`.
///
/// All events are written to `~/.nala/hang.log` via `PersistentLog` because
/// macOS unified logging is asynchronous — when the user force-quits a hung
/// process, in-flight os.Logger entries are lost. File writes survive.
///
/// Only active in DEBUG builds to avoid any overhead in release.
final class MainThreadWatchdog: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.nala.app", category: "Watchdog")
    private var timer: DispatchSourceTimer?

    /// How often the watchdog checks the main thread (seconds).
    private static let checkInterval: TimeInterval = 2.0

    /// How long the main thread must be unresponsive before logging (seconds).
    private static let hangThreshold: TimeInterval = 3.0

    /// Dispatch latency above this threshold triggers an overloaded warning (seconds).
    /// 200ms means the main thread took >200ms to service a simple async block.
    private static let overloadThreshold: TimeInterval = 0.2

    /// How often to write a heartbeat to hang.log (in check intervals).
    /// 15 checks × 2s = every 30 seconds.
    private static let heartbeatInterval: Int = 15

    /// Tracks whether we're currently in a detected hang to avoid spamming logs.
    private var hangStartTime: TimeInterval = 0

    /// Counter for heartbeat cadence.
    private var checkCount: Int = 0

    /// Closure that returns a snapshot of app state for heartbeat logging.
    /// Called on the main thread (inside the semaphore signal block) to avoid
    /// data races. The result is cached in `lastSnapshot` for use by the
    /// background timer thread.
    var stateSnapshot: (() -> String)?

    /// Last state snapshot captured on the main thread. Read from the timer
    /// thread for hang detection and heartbeat logging. Updated every check
    /// cycle when the main thread is responsive.
    private var lastSnapshot: String = ""

    /// Consecutive overloaded checks — only log after multiple to reduce noise.
    private var consecutiveOverloads: Int = 0

    func start() {
        #if DEBUG
        PersistentLog.shared.write("Watchdog started (check=\(Self.checkInterval)s, threshold=\(Self.hangThreshold)s)", category: "Watchdog")

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
        #if DEBUG
        PersistentLog.shared.write("Watchdog stopped (clean shutdown)", category: "Watchdog")
        #endif
        timer?.cancel()
        timer = nil
    }

    private func checkMainThread() {
        checkCount += 1
        let pingStart = CACurrentMediaTime()
        let semaphore = DispatchSemaphore(value: 0)

        // Record when the async block actually executes on the main thread.
        // The semaphore signal provides happens-before ordering, so reading
        // dispatchTime after wait() returns is safe.
        var dispatchTime: TimeInterval = 0

        let snapshotProvider = stateSnapshot
        DispatchQueue.main.async { [weak self] in
            dispatchTime = CACurrentMediaTime()
            self?.lastSnapshot = snapshotProvider?() ?? ""
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + Self.hangThreshold)
        if result == .timedOut {
            let elapsed = CACurrentMediaTime() - pingStart
            consecutiveOverloads = 0
            if hangStartTime == 0 {
                hangStartTime = pingStart
                let snapshot = lastSnapshot
                let message = "MAIN THREAD HANG DETECTED: unresponsive for >\(String(format: "%.1f", elapsed))s. " +
                    "Check 'handleTmuxUpdate', 'reconcileOrder', 'startWatching' signposts." +
                    (snapshot.isEmpty ? "" : " Last known state: \(snapshot)")
                logger.error("\(message)")
                PersistentLog.shared.write(message, category: "Watchdog")
            } else {
                let totalHang = CACurrentMediaTime() - hangStartTime
                let message = "MAIN THREAD STILL HUNG: \(String(format: "%.1f", totalHang))s total"
                logger.error("\(message)")
                PersistentLog.shared.write(message, category: "Watchdog")
            }
        } else {
            // Main thread responded — check for full-hang resolution
            if hangStartTime != 0 {
                let totalHang = CACurrentMediaTime() - hangStartTime
                let message = "Main thread hang resolved after \(String(format: "%.1f", totalHang))s"
                logger.warning("\(message)")
                PersistentLog.shared.write(message, category: "Watchdog")
                hangStartTime = 0
            }

            // Check for busy-hung (main thread responsive but overloaded)
            let latency = dispatchTime - pingStart
            if latency > Self.overloadThreshold {
                consecutiveOverloads += 1
                // Log on first detection and every 5th consecutive to avoid spam
                if consecutiveOverloads == 1 || consecutiveOverloads % 5 == 0 {
                    let message = "MAIN THREAD OVERLOADED: dispatch latency \(String(format: "%.0f", latency * 1000))ms " +
                        "(streak: \(consecutiveOverloads)). \(lastSnapshot)"
                    logger.warning("\(message)")
                    PersistentLog.shared.write(message, category: "Watchdog")
                }
            } else {
                if consecutiveOverloads > 0 {
                    let message = "Main thread overload resolved after \(consecutiveOverloads) checks"
                    logger.info("\(message)")
                    PersistentLog.shared.write(message, category: "Watchdog")
                }
                consecutiveOverloads = 0
            }

            // Periodic heartbeat — only when main thread is responsive
            if checkCount % Self.heartbeatInterval == 0 {
                PersistentLog.shared.write("heartbeat: \(lastSnapshot)", category: "Watchdog")
            }
        }
    }
}
