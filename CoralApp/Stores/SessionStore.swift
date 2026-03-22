import Foundation
import os

// MARK: - SessionGroup

struct SessionGroup: Identifiable, Equatable {
    let id: String
    let label: String
    let path: String
    let sessions: [Session]
}

// MARK: - StatusSection

struct StatusSection: Identifiable, Equatable {
    let status: FolderStatus
    let groups: [SessionGroup]

    var id: String { status.rawValue }
}

/// Central observable store for live session state. Owns the WebSocket
/// connection and merges diffs into a flat session list.
@Observable
final class SessionStore {
    var sessions: [Session] = []
    var selectedSessionId: String?
    var showingLaunchSheet = false
    var isConnected = false

    // MARK: - Ordering State (persisted via UserDefaults)

    /// Ordered array of workingDirectory paths.
    var folderOrder: [String] = [] {
        didSet { if !isSuppressingPersistence { saveFolderOrder() } }
    }

    /// Per-folder ordered arrays of session IDs.
    var sessionOrder: [String: [String]] = [:] {
        didSet { if !isSuppressingPersistence { saveSessionOrder() } }
    }

    /// Disclosure group expansion state per folder.
    var folderExpansion: [String: Bool] = [:] {
        didSet { if !isSuppressingPersistence { saveFolderExpansion() } }
    }

    /// Status assignment per folder path. Defaults to `.inProgress`.
    var folderStatus: [String: FolderStatus] = [:] {
        didSet { if !isSuppressingPersistence { saveFolderStatus() } }
    }

    /// Section collapse state per status. Defaults to expanded (`true`).
    var sectionExpansion: [FolderStatus: Bool] = [:] {
        didSet { if !isSuppressingPersistence { saveSectionExpansion() } }
    }

    /// Parent directory whose top-level subfolders appear in the sidebar
    /// regardless of active sessions. Persisted to UserDefaults.
    var parentFolderPath: String? {
        didSet {
            guard !isSuppressingPersistence else { return }
            UserDefaults.standard.set(parentFolderPath, forKey: Self.parentFolderPathKey)
            scanParentFolder()
        }
    }

    /// Subfolders discovered by scanning `parentFolderPath`. Re-derived on
    /// each scan; not persisted.
    var discoveredFolders: Set<String> = []

    private(set) var apiClient = APIClient()
    private var webSocket: CoralWebSocket?
    private let logger = Logger(subsystem: "com.coral.app", category: "SessionStore")
    private var isSuppressingPersistence = false

    private static let folderOrderKey = "coral.folderOrder"
    private static let sessionOrderKey = "coral.sessionOrder"
    private static let folderExpansionKey = "coral.folderExpansion"
    private static let folderStatusKey = "coral.folderStatus"
    private static let sectionExpansionKey = "coral.sectionExpansion"
    private static let parentFolderPathKey = "coral.parentFolderPath"

    /// The currently selected session, if any.
    var selectedSession: Session? {
        guard let id = selectedSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    // MARK: - Ordered Groups

    /// Groups sessions by workingDirectory, ordered by folderOrder,
    /// with sessions within each group ordered by sessionOrder.
    var orderedGroups: [SessionGroup] {
        let grouped = Dictionary(grouping: sessions) { $0.workingDirectory }

        // Build groups for every folder in folderOrder that has sessions
        // or is a discovered folder from the parent directory
        var result: [SessionGroup] = []
        for path in folderOrder {
            let folderSessions = grouped[path] ?? []
            if folderSessions.isEmpty && !discoveredFolders.contains(path) { continue }
            let label = path.isEmpty
                ? "Other"
                : URL(fileURLWithPath: path).lastPathComponent
            let orderedIds = sessionOrder[path] ?? []
            let sorted = folderSessions.sorted { a, b in
                let idxA = orderedIds.firstIndex(of: a.id) ?? Int.max
                let idxB = orderedIds.firstIndex(of: b.id) ?? Int.max
                return idxA < idxB
            }
            result.append(SessionGroup(id: path, label: label, path: path, sessions: sorted))
        }

        // Append any folders not yet in folderOrder (shouldn't happen after reconcile, but safety net)
        for (path, folderSessions) in grouped where !folderOrder.contains(path) {
            let label = path.isEmpty
                ? "Other"
                : URL(fileURLWithPath: path).lastPathComponent
            result.append(SessionGroup(id: path, label: label, path: path, sessions: folderSessions))
        }

        return result
    }

    // MARK: - Status Sections

    /// Groups orderedGroups by folder status, always including all statuses
    /// in display order. Folders without an explicit status default to `.inProgress`.
    var orderedSections: [StatusSection] {
        let groups = orderedGroups
        let groupedByStatus = Dictionary(grouping: groups) { group in
            folderStatus[group.path] ?? .inProgress
        }

        return FolderStatus.displayOrder.map { status in
            StatusSection(
                status: status,
                groups: groupedByStatus[status] ?? []
            )
        }
    }

    /// Assign a folder to a new status section.
    func setFolderStatus(_ path: String, to status: FolderStatus) {
        folderStatus[path] = status
    }

    // MARK: - Connection

    /// Scan `parentFolderPath` for top-level subdirectories and update
    /// `discoveredFolders`, then reconcile sidebar order.
    func scanParentFolder() {
        guard let parent = parentFolderPath else {
            discoveredFolders = []
            reconcileOrder()
            return
        }

        let url = URL(fileURLWithPath: parent)
        let fm = FileManager.default
        do {
            let contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            var folders = Set<String>()
            for item in contents {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true {
                    folders.insert(item.path)
                }
            }
            discoveredFolders = folders
        } catch {
            logger.warning("Failed to scan parent folder: \(error)")
            discoveredFolders = []
        }
        reconcileOrder()
    }

    func connect(port: Int) {
        apiClient = APIClient(port: port)
        loadSavedOrder()
        scanParentFolder()

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

    func launchTerminal(in workingDir: String) {
        let request = LaunchRequest(workingDir: workingDir, agentType: "terminal")
        Task {
            do {
                let response = try await apiClient.launchAgent(request)
                selectedSessionId = response.sessionId
            } catch {
                logger.error("Failed to launch terminal: \(error)")
            }
        }
    }

    // MARK: - Move Handlers

    func moveFolders(from source: IndexSet, to destination: Int) {
        folderOrder.move(fromOffsets: source, toOffset: destination)
    }

    func moveSessions(in folderPath: String, from source: IndexSet, to destination: Int) {
        guard var ids = sessionOrder[folderPath] else { return }
        ids.move(fromOffsets: source, toOffset: destination)
        sessionOrder[folderPath] = ids
    }

    /// Move a session to the position of another session within the same folder.
    /// Used by the drag-and-drop `isTargeted` handler for fluid reordering.
    func moveSessionToPosition(_ sessionId: String, targetId: String, in folderPath: String) {
        guard var ids = sessionOrder[folderPath],
              let fromIndex = ids.firstIndex(of: sessionId),
              let toIndex = ids.firstIndex(of: targetId),
              fromIndex != toIndex
        else { return }

        let offset = fromIndex < toIndex ? toIndex + 1 : toIndex
        ids.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
        sessionOrder[folderPath] = ids
    }

    /// Move a folder to the position of another folder.
    /// Used by the drag-and-drop `isTargeted` handler for fluid reordering.
    func moveFolderToPosition(_ path: String, targetPath: String) {
        guard let fromIndex = folderOrder.firstIndex(of: path),
              let toIndex = folderOrder.firstIndex(of: targetPath),
              fromIndex != toIndex
        else { return }

        let offset = fromIndex < toIndex ? toIndex + 1 : toIndex
        folderOrder.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
    }

    // MARK: - Diff Merge (mirrors websocket.js logic)

    func handleFullUpdate(_ newSessions: [Session]) {
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

        reconcileOrder()
        isConnected = true
        logger.info("Full update: \(self.sessions.count) sessions")

        // Fetch commands via REST (WebSocket doesn't include them)
        Task { await fetchCommands() }
    }

    func handleDiff(changed: [Session], removed: [String]) {
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

        // Apply changes — match by composite key (sessionId if present, else name)
        // to mirror the JavaScript diff logic: `(s.session_id || s.name) === key`
        for change in changed {
            let changeKey = change.sessionId.isEmpty ? change.name : change.sessionId
            let idx = sessions.firstIndex(where: {
                let key = $0.sessionId.isEmpty ? $0.name : $0.sessionId
                return key == changeKey
            })

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

        reconcileOrder()
        isConnected = true
    }

    // MARK: - Order Reconciliation

    /// Prunes stale entries and appends newly discovered folders/sessions.
    func reconcileOrder() {
        isSuppressingPersistence = true
        defer {
            isSuppressingPersistence = false
            saveFolderOrder()
            saveSessionOrder()
            saveFolderStatus()
        }

        let currentFolders = Set(sessions.map(\.workingDirectory))
        let currentSessionsByFolder = Dictionary(grouping: sessions) { $0.workingDirectory }
        let keepFolders = currentFolders.union(discoveredFolders)

        // Prune folders that no longer exist (in sessions or discovered)
        folderOrder.removeAll { !keepFolders.contains($0) }

        // Append new folders to the end
        for folder in keepFolders where !folderOrder.contains(folder) {
            folderOrder.append(folder)
        }

        // Prune stale session ordering keys
        for key in sessionOrder.keys where !keepFolders.contains(key) {
            sessionOrder.removeValue(forKey: key)
        }

        // Reconcile per-folder session ordering
        for (folder, folderSessions) in currentSessionsByFolder {
            let currentIds = Set(folderSessions.map(\.id))
            var orderedIds = sessionOrder[folder] ?? []

            // Prune sessions that no longer exist in this folder
            orderedIds.removeAll { !currentIds.contains($0) }

            // Append new sessions to the end
            for id in folderSessions.map(\.id) where !orderedIds.contains(id) {
                orderedIds.append(id)
            }

            sessionOrder[folder] = orderedIds
        }

        // Prune stale folder status entries
        for key in folderStatus.keys where !keepFolders.contains(key) {
            folderStatus.removeValue(forKey: key)
        }
    }

    // MARK: - Persistence

    private func loadSavedOrder() {
        isSuppressingPersistence = true
        defer { isSuppressingPersistence = false }

        let defaults = UserDefaults.standard
        folderOrder = defaults.stringArray(forKey: Self.folderOrderKey) ?? []
        parentFolderPath = defaults.string(forKey: Self.parentFolderPathKey)

        if let data = defaults.data(forKey: Self.sessionOrderKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            sessionOrder = decoded
        }

        if let data = defaults.data(forKey: Self.folderExpansionKey),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            folderExpansion = decoded
        }

        if let data = defaults.data(forKey: Self.folderStatusKey),
           let decoded = try? JSONDecoder().decode([String: FolderStatus].self, from: data) {
            folderStatus = decoded
        }

        if let data = defaults.data(forKey: Self.sectionExpansionKey),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            // Convert String keys back to FolderStatus
            sectionExpansion = decoded.reduce(into: [:]) { result, pair in
                if let status = FolderStatus(rawValue: pair.key) {
                    result[status] = pair.value
                }
            }
        }
    }

    private func saveFolderOrder() {
        UserDefaults.standard.set(folderOrder, forKey: Self.folderOrderKey)
    }

    private func saveSessionOrder() {
        if let data = try? JSONEncoder().encode(sessionOrder) {
            UserDefaults.standard.set(data, forKey: Self.sessionOrderKey)
        }
    }

    private func saveFolderExpansion() {
        if let data = try? JSONEncoder().encode(folderExpansion) {
            UserDefaults.standard.set(data, forKey: Self.folderExpansionKey)
        }
    }

    private func saveFolderStatus() {
        if let data = try? JSONEncoder().encode(folderStatus) {
            UserDefaults.standard.set(data, forKey: Self.folderStatusKey)
        }
    }

    private func saveSectionExpansion() {
        // Convert FolderStatus keys to String for JSONEncoder
        let stringKeyed = sectionExpansion.reduce(into: [String: Bool]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }
        if let data = try? JSONEncoder().encode(stringKeyed) {
            UserDefaults.standard.set(data, forKey: Self.sectionExpansionKey)
        }
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
