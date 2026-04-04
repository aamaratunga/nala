import Foundation
import UserNotifications
import AppKit
import os

/// Manages macOS system notifications for session state changes (needs input, done).
/// Uses UNUserNotificationCenter for banners and NSSound for reliable audio.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let logger = Logger(subsystem: "com.nala.app", category: "Notifications")
    private let center = UNUserNotificationCenter.current()

    /// Tracks the last notified state per session to prevent duplicate notifications
    /// when the native services re-send the same state.
    private struct NotifiedState {
        var waitingForInput: Bool
        var done: Bool
    }

    private var lastNotifiedState: [String: NotifiedState] = [:]

    private override init() {
        super.init()
        center.delegate = self
    }

    // MARK: - Permission

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                self.logger.warning("Notification permission error: \(error)")
            } else {
                self.logger.info("Notification permission granted: \(granted)")
            }
        }
    }

    // MARK: - State Evaluation

    /// Evaluate a session transition and fire notifications when appropriate.
    /// - Parameters:
    ///   - old: The previous session state (nil for newly appeared sessions).
    ///   - new: The current session state.
    func evaluateTransition(old: Session?, new: Session) {
        let defaults = UserDefaults.standard
        let previous = lastNotifiedState[new.id]

        let wasWaiting = old?.waitingForInput ?? previous?.waitingForInput ?? false
        let wasDone = old?.done ?? previous?.done ?? false

        // Update tracking state
        lastNotifiedState[new.id] = NotifiedState(
            waitingForInput: new.waitingForInput,
            done: new.done
        )

        let folder = URL(fileURLWithPath: new.workingDirectory).lastPathComponent

        // Needs input: false → true
        if new.waitingForInput && !wasWaiting {
            let enabled = defaults.object(forKey: "nala.notifications.needsInput") as? Bool ?? true
            if enabled {
                let detail = new.waitingSummary ?? new.status ?? ""
                let body = detail.isEmpty ? folder : "\(folder) — \(detail)"
                postNotification(
                    id: "needs-input-\(new.id)",
                    title: "\(new.displayLabel) needs input",
                    body: body,
                    soundName: "Funk"
                )
            }
        }

        // Done: false → true
        if new.done && !wasDone {
            let enabled = defaults.object(forKey: "nala.notifications.done") as? Bool ?? true
            if enabled {
                let detail = new.summary ?? new.status ?? ""
                let body = detail.isEmpty ? folder : "\(folder) — \(detail)"
                postNotification(
                    id: "done-\(new.id)",
                    title: "\(new.displayLabel) is done",
                    body: body,
                    soundName: "Glass"
                )
            }
        }
    }

    /// Clear tracked state for a removed session.
    func clearSession(_ id: String) {
        lastNotifiedState.removeValue(forKey: id)
    }

    // MARK: - Notification Posting

    private func postNotification(id: String, title: String, body: String, soundName: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil // deliver immediately
        )

        center.add(request) { error in
            if let error {
                self.logger.warning("Failed to post notification: \(error)")
            }
        }

        // Play sound via NSSound (works reliably in foreground and background)
        if let sound = NSSound(named: NSSound.Name(soundName)) {
            sound.play()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Controls whether banners appear when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Suppress banners when the app is focused (sound is already played via NSSound)
        if NSApp.isActive {
            completionHandler([])
        } else {
            completionHandler([.banner])
        }
    }
}
