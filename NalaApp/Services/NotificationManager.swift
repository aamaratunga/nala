import Foundation
import UserNotifications
import AppKit
import os

/// Manages macOS system notifications for session state changes (needs input, done).
/// Uses UNUserNotificationCenter for banners and NSSound for reliable audio.
///
/// Deduplication is structural: callers only invoke `notify` when the reducer reports
/// `transition.didChange == true`, so there is no per-session tracking here.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let logger = Logger(subsystem: "com.nala.app", category: "Notifications")
    private let center = UNUserNotificationCenter.current()

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

    // MARK: - Notify

    /// Fire a notification for a state transition.
    /// Only call when `transition.didChange` is true and the new state is notifiable.
    func notify(session: Session, transition: StateTransition) {
        let defaults = UserDefaults.standard
        let folder = URL(fileURLWithPath: session.workingDirectory).lastPathComponent

        switch transition.to {
        case .waitingForInput:
            let enabled = defaults.object(forKey: "nala.notifications.needsInput") as? Bool ?? true
            if enabled {
                let detail = session.waitingSummary ?? ""
                let body = detail.isEmpty ? folder : "\(folder) — \(detail)"
                postNotification(
                    id: "needs-input-\(session.id)",
                    title: "\(session.displayLabel) needs input",
                    body: body,
                    soundName: "Funk"
                )
            }

        case .done:
            let enabled = defaults.object(forKey: "nala.notifications.done") as? Bool ?? true
            if enabled {
                let detail = session.latestEventSummary ?? ""
                let body = detail.isEmpty ? folder : "\(folder) — \(detail)"
                postNotification(
                    id: "done-\(session.id)",
                    title: "\(session.displayLabel) is done",
                    body: body,
                    soundName: "Glass"
                )
            }

        case .idle, .working, .sleeping, .stuck:
            break // Not notifiable states
        }
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
