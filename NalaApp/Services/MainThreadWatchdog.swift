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

    func start() {
        #if DEBUG
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
                logger.error("""
                    MAIN THREAD HANG DETECTED: unresponsive for >\(String(format: "%.1f", elapsed))s. \
                    Use Instruments (System Trace or App Hang template) to capture the blocking call stack. \
                    Check 'handleTmuxUpdate', 'reconcileOrder', 'startWatching' signposts.
                    """)
            } else {
                let totalHang = CACurrentMediaTime() - hangStartTime
                logger.error("MAIN THREAD STILL HUNG: \(String(format: "%.1f", totalHang))s total")
            }
        } else {
            if hangStartTime != 0 {
                let totalHang = CACurrentMediaTime() - hangStartTime
                logger.warning("Main thread hang resolved after \(String(format: "%.1f", totalHang))s")
                hangStartTime = 0
            }
        }
    }
}
