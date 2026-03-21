import Foundation
import os

/// Central observable store for live session state. Owns the WebSocket
/// connection and merges diffs into a flat session list.
@Observable
final class SessionStore {
    var sessions: [Session] = []
    var selectedSessionId: String?
    var showingLaunchSheet = false
    var isConnected = false

    private(set) var apiClient = APIClient()
    private var webSocket: CoralWebSocket?
    private let logger = Logger(subsystem: "com.coral.app", category: "SessionStore")

    /// The currently selected session, if any.
    var selectedSession: Session? {
        guard let id = selectedSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    // MARK: - Connection

    func connect(port: Int) {
        apiClient = APIClient(port: port)

        let ws = CoralWebSocket(port: port)
        webSocket = ws

        ws.onFullUpdate = { [weak self] sessions in
            self?.handleFullUpdate(sessions)
        }

        ws.onDiff = { [weak self] changed, removed in
            self?.handleDiff(changed: changed, removed: removed)
        }

        ws.onDisconnect = { [weak self] in
            self?.isConnected = false
        }

        ws.connect()
    }

    func disconnect() {
        webSocket?.disconnect()
        webSocket = nil
        isConnected = false
    }

    // MARK: - Diff Merge (mirrors websocket.js logic)

    private func handleFullUpdate(_ newSessions: [Session]) {
        // Preserve commands from existing sessions (WS doesn't send them)
        let commandMap = Dictionary(
            sessions.map { ($0.id, $0.commands) },
            uniquingKeysWith: { _, last in last }
        )

        // Deduplicate by id — the server may send the same session twice
        var seen = Set<String>()
        sessions = newSessions.compactMap { session in
            guard seen.insert(session.id).inserted else { return nil }
            var s = session
            if s.commands.isEmpty, let existing = commandMap[s.id] {
                s.commands = existing
            }
            return s
        }

        isConnected = true
        logger.info("Full update: \(self.sessions.count) sessions")

        // Fetch commands via REST (WebSocket doesn't include them)
        Task { await fetchCommands() }
    }

    private func handleDiff(changed: [Session], removed: [String]) {
        // Apply removals
        if !removed.isEmpty {
            sessions.removeAll { session in
                removed.contains(session.sessionId) || removed.contains(session.name)
            }
            // Clear selection if the selected session was removed
            if let selectedId = selectedSessionId,
               removed.contains(selectedId) || sessions.first(where: { $0.id == selectedId }) == nil {
                selectedSessionId = nil
            }
        }

        // Apply changes — match by sessionId first, then fall back to name
        for change in changed {
            let idx = sessions.firstIndex(where: { $0.sessionId == change.sessionId && !change.sessionId.isEmpty })
                   ?? sessions.firstIndex(where: { $0.name == change.name })

            if let idx {
                var updated = change
                if updated.commands.isEmpty {
                    updated.commands = sessions[idx].commands
                }
                sessions[idx] = updated
            } else {
                // Only append if not already present (guard against duplicates)
                if !sessions.contains(where: { $0.id == change.id }) {
                    sessions.append(change)
                }
            }
        }

        isConnected = true
    }

    // MARK: - REST Fallback

    private func fetchCommands() async {
        do {
            let fullSessions = try await apiClient.fetchLiveSessions()
            let commandMap = Dictionary(
                fullSessions.map { ($0.id, $0.commands) },
                uniquingKeysWith: { _, last in last }
            )
            for i in sessions.indices {
                if let cmds = commandMap[sessions[i].id], !cmds.isEmpty {
                    sessions[i].commands = cmds
                }
            }
        } catch {
            logger.warning("Failed to fetch commands: \(error)")
        }
    }
}
