import Foundation
import AppKit
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
    var showingTerminalLaunchSheet = false
    var showingCreateWorktreeSheet = false
    var isConnected = false

    /// Active worktree creation states, keyed by placeholder session ID.
    var activeCreations: [String: WorktreeCreationState] = [:]

    /// Active worktree deletion states, keyed by folder path.
    var activeDeletions: [String: WorktreeDeletionState] = [:]

    /// Active session launch states, keyed by placeholder session ID.
    var activeLaunches: [String: SessionLaunchState] = [:]

    /// Active session restart states, keyed by original session ID.
    var activeRestarts: [String: SessionRestartState] = [:]

    /// Session IDs that were optimistically removed (pending server-side kill).
    /// Prevents handleDiff from re-adding them before the removal diff arrives.
    private var pendingKills: Set<String> = []

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

    /// Configured repositories for worktree management.
    var repoConfigs: [RepoConfig] = [] {
        didSet {
            if !isSuppressingPersistence {
                saveRepoConfigs()
                // Only rescan if the set of worktree folder paths changed
                let newPaths = Set(repoConfigs.compactMap { config -> String? in
                    guard !config.repoPath.isEmpty, !config.worktreeFolderPath.isEmpty else { return nil }
                    return config.worktreeFolderPath
                })
                if newPaths != lastScannedWorktreePaths {
                    scanWorktreeFolders()
                }
            }
        }
    }

    /// Subfolders discovered by scanning worktree folders. Cached to
    /// UserDefaults so the sidebar loads instantly on next launch.
    var discoveredFolders: Set<String> = []

    private(set) var apiClient = APIClient()
    private var webSocket: CoralWebSocket?
    private let logger = Logger(subsystem: "com.coral.app", category: "SessionStore")
    private var isSuppressingPersistence = false
    private var lastScannedWorktreePaths: Set<String> = []
    private var scanTask: Task<Void, Never>?

    /// Cache: workingDirectory → resolved git root (or self if not in a git repo).
    private var gitRootCache: [String: String] = [:]

    /// Returns the git root for a working directory, falling back to the path itself.
    func groupingPath(for workingDirectory: String) -> String {
        if let cached = gitRootCache[workingDirectory] { return cached }
        let resolved = GitService.findGitRoot(from: workingDirectory) ?? workingDirectory
        gitRootCache[workingDirectory] = resolved
        return resolved
    }

    private static let folderOrderKey = "coral.folderOrder"
    private static let sessionOrderKey = "coral.sessionOrder"
    private static let folderExpansionKey = "coral.folderExpansion"
    private static let folderStatusKey = "coral.folderStatus"
    private static let sectionExpansionKey = "coral.sectionExpansion"
    private static let repoConfigsKey = "coral.repoConfigs"
    private static let discoveredFoldersKey = "coral.discoveredFolders"

    /// The currently selected session, if any.
    var selectedSession: Session? {
        guard let id = selectedSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    /// The creation state for the currently selected placeholder, if any.
    var selectedCreationState: WorktreeCreationState? {
        guard let id = selectedSessionId else { return nil }
        return activeCreations[id]
    }

    /// The deletion state for the currently selected session's folder, if any.
    var selectedDeletionState: WorktreeDeletionState? {
        guard let id = selectedSessionId else { return nil }
        if let state = activeDeletions[id] { return state }
        if let session = sessions.first(where: { $0.id == id }) {
            return activeDeletions[session.workingDirectory]
                ?? activeDeletions[groupingPath(for: session.workingDirectory)]
        }
        return nil
    }

    /// The launch state for the currently selected placeholder, if any.
    var selectedLaunchState: SessionLaunchState? {
        guard let id = selectedSessionId else { return nil }
        return activeLaunches[id]
    }

    /// The restart state for the currently selected session, if any.
    var selectedRestartState: SessionRestartState? {
        guard let id = selectedSessionId else { return nil }
        return activeRestarts[id]
    }

    func isDeleting(folderPath: String) -> Bool {
        activeDeletions[folderPath] != nil
    }

    func isRestarting(sessionId: String) -> Bool {
        activeRestarts[sessionId] != nil
    }

    // MARK: - Ordered Groups

    /// Groups sessions by workingDirectory, ordered by folderOrder,
    /// with sessions within each group ordered by sessionOrder.
    var orderedGroups: [SessionGroup] {
        let grouped = Dictionary(grouping: sessions) { groupingPath(for: $0.workingDirectory) }

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

    /// Computed list of repo configs that have both required fields set.
    var validRepoConfigs: [RepoConfig] {
        repoConfigs.filter { !$0.repoPath.isEmpty && !$0.worktreeFolderPath.isEmpty }
    }

    /// Scan all configured worktree folders for top-level subdirectories
    /// in the background, then update `discoveredFolders` and reconcile
    /// on the main thread. Results are cached to UserDefaults.
    func scanWorktreeFolders() {
        let folders = validRepoConfigs.map(\.worktreeFolderPath)
        let folderSet = Set(folders)
        lastScannedWorktreePaths = folderSet

        guard !folders.isEmpty else {
            if !discoveredFolders.isEmpty {
                discoveredFolders = []
                saveDiscoveredFolders()
                reconcileOrder()
            }
            return
        }

        // Cancel any in-flight scan
        scanTask?.cancel()
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let fm = FileManager.default
            var allDiscovered = Set<String>()
            for folder in folders {
                guard !Task.isCancelled else { return }
                let url = URL(fileURLWithPath: folder)
                do {
                    let contents = try fm.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
                    for item in contents {
                        let values = try item.resourceValues(forKeys: [.isDirectoryKey])
                        if values.isDirectory == true {
                            allDiscovered.insert(item.path)
                        }
                    }
                } catch {
                    // Logged on main thread below
                }
            }

            guard !Task.isCancelled else { return }
            let discovered = allDiscovered
            await MainActor.run { [weak self, discovered] in
                guard let self, !Task.isCancelled else { return }
                if self.discoveredFolders != discovered {
                    self.discoveredFolders = discovered
                    self.saveDiscoveredFolders()
                    self.reconcileOrder()
                }
            }
        }
    }

    func connect(port: Int) {
        apiClient = APIClient(port: port)
        loadSavedOrder()
        scanWorktreeFolders()

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

    func launchSession(agentType: String, in workingDir: String) {
        let state = SessionLaunchState(workingDirectory: workingDir, agentType: agentType)

        // Create placeholder session
        var placeholder = Session(
            name: state.id,
            agentType: agentType,
            sessionId: state.id,
            workingDirectory: workingDir,
            working: true
        )
        placeholder.isPlaceholder = true

        sessions.append(placeholder)
        activeLaunches[state.id] = state
        reconcileOrder()

        // Select the placeholder and ensure its folder + section are expanded
        selectedSessionId = state.id
        let resolvedDir = groupingPath(for: workingDir)
        folderExpansion[resolvedDir] = true
        let status = folderStatus[resolvedDir] ?? .inProgress
        sectionExpansion[status] = true

        Task { await performLaunch(state: state) }
    }

    func launchTerminal(in workingDir: String) {
        launchSession(agentType: "terminal", in: workingDir)
    }

    private func performLaunch(state: SessionLaunchState) async {
        let request = LaunchRequest(workingDir: state.workingDirectory, agentType: state.agentType)
        do {
            let response = try await apiClient.launchAgent(request)
            state.realSessionId = response.sessionId
            state.isFinished = true
            // If the real session already arrived via WS (unlikely), swap now
            if sessions.contains(where: { $0.id == response.sessionId }) {
                replaceLaunchPlaceholder(placeholderId: state.id, realSessionId: response.sessionId)
            }
            // Otherwise, handleDiff will do the swap when the session arrives
        } catch {
            state.error = error.localizedDescription
            handleLaunchFailure(state: state)
        }
    }

    /// Swaps a launch placeholder session for the real session once it arrives.
    private func replaceLaunchPlaceholder(placeholderId: String, realSessionId: String) {
        sessions.removeAll { $0.id == placeholderId }
        if selectedSessionId == placeholderId {
            selectedSessionId = realSessionId
        }
        activeLaunches.removeValue(forKey: placeholderId)
        reconcileOrder()
    }

    /// Cleans up after a failed session launch.
    private func handleLaunchFailure(state: SessionLaunchState) {
        sessions.removeAll { $0.id == state.id }
        if selectedSessionId == state.id {
            selectedSessionId = nil
        }
        activeLaunches.removeValue(forKey: state.id)
        reconcileOrder()

        let alert = NSAlert()
        alert.messageText = "Session Launch Failed"
        alert.informativeText = state.error ?? "An unknown error occurred."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Optimistic Kill

    func removeSessionOptimistically(_ session: Session) {
        // Move selection to next/prev session in same folder before removing
        if selectedSessionId == session.id {
            let resolvedPath = groupingPath(for: session.workingDirectory)
            if let group = orderedGroups.first(where: { $0.path == resolvedPath }) {
                let siblings = group.sessions.filter { $0.id != session.id && !$0.isPlaceholder }
                if let idx = group.sessions.firstIndex(where: { $0.id == session.id }) {
                    // Prefer next session, fall back to previous
                    let next = group.sessions[safe: idx + 1].flatMap { s in siblings.contains(where: { $0.id == s.id }) ? s : nil }
                    let prev = (idx > 0 ? group.sessions[safe: idx - 1] : nil).flatMap { s in siblings.contains(where: { $0.id == s.id }) ? s : nil }
                    selectedSessionId = next?.id ?? prev?.id
                } else {
                    selectedSessionId = siblings.first?.id
                }
            } else {
                selectedSessionId = nil
            }
        }

        pendingKills.insert(session.id)
        sessions.removeAll { $0.id == session.id }
        NotificationManager.shared.clearSession(session.id)
        reconcileOrder()
    }

    // MARK: - Restart

    func restartSession(_ session: Session) {
        let state = SessionRestartState(originalSession: session)
        activeRestarts[session.id] = state
        Task { await performRestart(state: state) }
    }

    private func performRestart(state: SessionRestartState) async {
        let session = state.originalSession

        // Phase 1: Kill the session
        state.phase = .killing
        do {
            try await apiClient.killSession(
                sessionName: session.name,
                agentType: session.agentType,
                sessionId: session.sessionId
            )
        } catch {
            state.error = error.localizedDescription
            handleRestartFailure(state: state)
            return
        }

        // Phase 2: Launch a new session
        state.phase = .launching
        let request = LaunchRequest(
            workingDir: session.workingDirectory,
            agentType: session.agentType,
            displayName: session.displayName
        )
        do {
            let response = try await apiClient.launchAgent(request)
            state.isFinished = true

            // Transfer selection to the new session
            if selectedSessionId == state.id {
                selectedSessionId = response.sessionId
            }
            activeRestarts.removeValue(forKey: state.id)
        } catch {
            state.error = error.localizedDescription
            handleRestartFailure(state: state)
        }
    }

    private func handleRestartFailure(state: SessionRestartState) {
        activeRestarts.removeValue(forKey: state.id)

        let alert = NSAlert()
        alert.messageText = "Session Restart Failed"
        alert.informativeText = state.error ?? "An unknown error occurred."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    // MARK: - Rename

    func renameSession(_ session: Session, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let originalName = sessions[idx].displayName

        // Optimistic update
        sessions[idx].displayName = trimmed

        Task {
            do {
                try await apiClient.setDisplayName(
                    sessionName: session.name,
                    sessionId: session.sessionId,
                    displayName: trimmed
                )
            } catch {
                // Rollback on failure
                if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[idx].displayName = originalName
                }
                logger.error("Failed to rename session: \(error)")
            }
        }
    }

    // MARK: - Diff Merge (mirrors websocket.js logic)

    func handleFullUpdate(_ newSessions: [Session]) {
        // Preserve commands from existing sessions (WS doesn't send them)
        let commandMap = Dictionary(
            sessions.map { ($0.id, $0.commands) },
            uniquingKeysWith: { _, last in last }
        )

        // Save active placeholder sessions before replacing (worktree creation + session launch)
        let activePlaceholders = sessions.filter {
            $0.isPlaceholder && (activeCreations[$0.id] != nil || activeLaunches[$0.id] != nil)
        }

        // Save sessions in folders being deleted before replacing
        let deletingSessions = sessions.filter {
            activeDeletions[$0.workingDirectory] != nil || activeDeletions[groupingPath(for: $0.workingDirectory)] != nil
        }

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

        // Re-append placeholders that are still being created
        for placeholder in activePlaceholders where !sessions.contains(where: { $0.id == placeholder.id }) {
            sessions.append(placeholder)
        }

        // Re-append sessions in folders being deleted that got dropped
        for session in deletingSessions where !sessions.contains(where: { $0.id == session.id }) {
            sessions.append(session)
        }

        pendingKills.removeAll()
        reconcileOrder()
        isConnected = true
        logger.info("Full update: \(self.sessions.count) sessions")

        // Fetch commands via REST (WebSocket doesn't include them)
        Task { await fetchCommands() }
    }

    func handleDiff(changed: [Session], removed: [String]) {
        // Apply removals — but never remove placeholder sessions
        if !removed.isEmpty {
            // Clear notification tracking and pending kills for removed sessions
            for id in removed {
                NotificationManager.shared.clearSession(id)
                pendingKills.remove(id)
            }

            sessions.removeAll { session in
                guard !session.isPlaceholder else { return false }
                guard activeDeletions[session.workingDirectory] == nil
                   && activeDeletions[groupingPath(for: session.workingDirectory)] == nil else { return false }
                return removed.contains(session.sessionId) || removed.contains(session.name)
            }
            // Clear selection if the selected session was removed
            // (but not if it's in a folder being deleted or being restarted)
            if let selectedId = selectedSessionId,
               removed.contains(selectedId) || sessions.first(where: { $0.id == selectedId }) == nil {
                let isInDeletingFolder = sessions.first(where: { $0.id == selectedId })
                    .map { activeDeletions[$0.workingDirectory] != nil || activeDeletions[groupingPath(for: $0.workingDirectory)] != nil } ?? false
                let isBeingRestarted = activeRestarts[selectedId] != nil
                if !isInDeletingFolder && !isBeingRestarted {
                    selectedSessionId = nil
                }
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
                let oldSession = sessions[idx]
                var updated = change
                if updated.commands.isEmpty {
                    updated.commands = oldSession.commands
                }
                sessions[idx] = updated
                NotificationManager.shared.evaluateTransition(old: oldSession, new: updated)
            } else {
                // Don't re-add sessions that were optimistically killed
                guard !pendingKills.contains(change.id) else { continue }
                // Only append if not already present (guard against duplicates)
                if !sessions.contains(where: { $0.id == change.id }) {
                    sessions.append(change)
                    NotificationManager.shared.evaluateTransition(old: nil, new: change)
                }
            }

            // Check if this new session matches a finished worktree creation placeholder
            for (placeholderId, creation) in activeCreations {
                if creation.isFinished && change.workingDirectory == creation.worktreePath {
                    replacePlaceholder(placeholderId: placeholderId, realSessionId: change.id)
                    break
                }
            }

            // Check if this new session matches a finished launch placeholder
            for (placeholderId, launch) in activeLaunches {
                if let realId = launch.realSessionId, change.id == realId {
                    replaceLaunchPlaceholder(placeholderId: placeholderId, realSessionId: change.id)
                    break
                }
            }

            // Check if this new session matches a finished restart
            for (originalId, restart) in activeRestarts {
                if restart.isFinished && change.workingDirectory == restart.originalSession.workingDirectory {
                    if selectedSessionId == originalId {
                        selectedSessionId = change.id
                    }
                    activeRestarts.removeValue(forKey: originalId)
                    break
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

        let currentFolders = Set(sessions.map { groupingPath(for: $0.workingDirectory) })
        let currentSessionsByFolder = Dictionary(grouping: sessions) { groupingPath(for: $0.workingDirectory) }
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

        if let data = defaults.data(forKey: Self.repoConfigsKey),
           let decoded = try? JSONDecoder().decode([RepoConfig].self, from: data) {
            repoConfigs = decoded
        }

        // Restore cached discovered folders for instant sidebar on launch
        if let cached = defaults.stringArray(forKey: Self.discoveredFoldersKey) {
            discoveredFolders = Set(cached)
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

    private func saveRepoConfigs() {
        if let data = try? JSONEncoder().encode(repoConfigs) {
            UserDefaults.standard.set(data, forKey: Self.repoConfigsKey)
        }
    }

    private func saveDiscoveredFolders() {
        UserDefaults.standard.set(Array(discoveredFolders), forKey: Self.discoveredFoldersKey)
    }

    // MARK: - Worktree Helpers

    /// Finds the matching repo config for a given worktree path.
    func repoConfigForWorktree(path: String) -> RepoConfig? {
        // First check if the path is under a configured worktree folder
        for config in repoConfigs {
            if !config.worktreeFolderPath.isEmpty && path.hasPrefix(config.worktreeFolderPath) {
                return config
            }
        }
        // Fall back to parsing the .git file to find the parent repo
        if let parentRepo = GitService.findParentRepoPath(worktreePath: path) {
            return repoConfigs.first { $0.repoPath == parentRepo }
        }
        return nil
    }

    /// Synchronous entry point: creates deletion state, starts async deletion pipeline.
    func beginWorktreeDeletion(folderPath: String) {
        let sessionsInFolder = sessions.filter { groupingPath(for: $0.workingDirectory) == folderPath }
        let repoPath = repoConfigForWorktree(path: folderPath)?.repoPath ?? ""
        let state = WorktreeDeletionState(folderPath: folderPath, sessionCount: sessionsInFolder.count, repoPath: repoPath)

        activeDeletions[folderPath] = state

        // Select the first session in the folder and ensure visible
        if let first = sessionsInFolder.first {
            selectedSessionId = first.id
        } else {
            // No sessions — create a placeholder so the sidebar shows a "Removing..." row
            var placeholder = Session(
                name: "deleting-\(folderPath)",
                sessionId: "deleting-\(folderPath)",
                workingDirectory: folderPath,
                working: false
            )
            placeholder.isPlaceholder = true
            sessions.append(placeholder)
            reconcileOrder()
            selectedSessionId = placeholder.id
        }
        folderExpansion[folderPath] = true
        let status = folderStatus[folderPath] ?? .inProgress
        sectionExpansion[status] = true

        Task { await performWorktreeDeletion(state: state) }
    }

    /// Async pipeline: kills sessions, runs pre-delete script, removes worktree, deletes branch.
    private func performWorktreeDeletion(state: WorktreeDeletionState) async {
        let folderPath = state.folderPath
        logger.info("deleteWorktree: starting for \(folderPath)")

        // Step 1: Kill all real sessions in this folder (exclude placeholders)
        let sessionsInFolder = sessions.filter { groupingPath(for: $0.workingDirectory) == folderPath && !$0.isPlaceholder }
        logger.info("deleteWorktree: found \(sessionsInFolder.count) sessions to kill")

        if sessionsInFolder.isEmpty {
            state.skipStep(.killingSessions)
        } else {
            state.advance(to: .killingSessions)
            for session in sessionsInFolder {
                logger.info("deleteWorktree: killing session \(session.name) (id=\(session.sessionId), type=\(session.agentType))")
                try? await apiClient.killSession(
                    sessionName: session.name,
                    agentType: session.agentType,
                    sessionId: session.sessionId
                )
            }
            state.completeCurrentStep()
        }

        // Step 2: Find the repo config and run pre-delete script
        let repoPath: String
        if let config = repoConfigForWorktree(path: folderPath) {
            logger.info("deleteWorktree: matched repo config '\(config.displayName)' (repoPath=\(config.repoPath))")
            if let script = config.preDeleteScript, !script.isEmpty {
                state.advance(to: .runningPreDeleteScript)
                let branchName = URL(fileURLWithPath: folderPath).lastPathComponent
                logger.info("deleteWorktree: running pre-delete script: \(script)")
                let scriptResult = await GitService.runScript(
                    scriptPath: script,
                    worktreePath: folderPath,
                    branchName: branchName,
                    repoPath: config.repoPath
                )
                if !scriptResult.succeeded {
                    logger.warning("deleteWorktree: pre-delete script failed: \(scriptResult.errorMessage)")
                } else {
                    logger.info("deleteWorktree: pre-delete script succeeded")
                }
                state.completeCurrentStep()
            } else {
                state.skipStep(.runningPreDeleteScript)
            }
            repoPath = config.repoPath
        } else if let parsed = GitService.findParentRepoPath(worktreePath: folderPath) {
            logger.info("deleteWorktree: no repo config match, parsed parent repo from .git file: \(parsed)")
            state.skipStep(.runningPreDeleteScript)
            repoPath = parsed
        } else {
            logger.error("deleteWorktree: cannot determine parent repo for \(folderPath) — aborting")
            state.fail(at: .runningPreDeleteScript, message: "Cannot determine parent repository")
            handleDeletionFailure(state: state)
            return
        }

        // Step 3: Remove the worktree
        state.advance(to: .removingWorktree)
        logger.info("deleteWorktree: removing worktree (repo=\(repoPath), path=\(folderPath))")
        var result = await GitService.removeWorktree(repoPath: repoPath, worktreePath: folderPath)
        if !result.succeeded {
            logger.warning("deleteWorktree: normal remove failed, retrying with --force")
            result = await GitService.removeWorktree(repoPath: repoPath, worktreePath: folderPath, force: true)
        }

        guard result.succeeded else {
            logger.error("deleteWorktree: failed to remove worktree even with force: \(result.errorMessage)")
            state.fail(at: .removingWorktree, message: result.errorMessage)
            handleDeletionFailure(state: state)
            return
        }
        logger.info("deleteWorktree: worktree removed successfully")
        state.completeCurrentStep()

        // Step 4: Delete the branch
        state.advance(to: .deletingBranch)
        let branchName = URL(fileURLWithPath: folderPath).lastPathComponent
        logger.info("deleteWorktree: deleting branch '\(branchName)'")
        let branchResult = await GitService.deleteBranch(repoPath: repoPath, branchName: branchName)
        if !branchResult.succeeded {
            logger.warning("deleteWorktree: branch deletion failed (may not exist or is current): \(branchResult.errorMessage)")
        }
        state.completeCurrentStep()

        handleDeletionSuccess(state: state)
    }

    /// Cleans up after a successful deletion.
    private func handleDeletionSuccess(state: WorktreeDeletionState) {
        state.isFinished = true

        // Remove sessions belonging to this folder
        sessions.removeAll { groupingPath(for: $0.workingDirectory) == state.folderPath }

        // Remove from discovered folders
        discoveredFolders.remove(state.folderPath)
        saveDiscoveredFolders()

        // Clean up deletion state
        activeDeletions.removeValue(forKey: state.folderPath)

        // Clear selection if it pointed to the deleted folder
        if let id = selectedSessionId {
            if id == state.folderPath || sessions.first(where: { $0.id == id }) == nil {
                selectedSessionId = nil
            }
        }

        reconcileOrder()

        logger.info("deleteWorktree: triggering folder rescan")
        scanWorktreeFolders()
    }

    /// Cleans up after a failed deletion attempt.
    private func handleDeletionFailure(state: WorktreeDeletionState) {
        activeDeletions.removeValue(forKey: state.folderPath)

        let alert = NSAlert()
        alert.messageText = "Worktree Deletion Failed"
        alert.informativeText = state.error ?? "An unknown error occurred."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Async Worktree Creation

    /// Synchronous entry point: creates placeholder session, starts async creation.
    func beginWorktreeCreation(config: RepoConfig, branchName: String) {
        let worktreePath = (config.worktreeFolderPath as NSString).appendingPathComponent(branchName)

        let state = WorktreeCreationState(
            branchName: branchName,
            repoDisplayName: config.displayName,
            worktreePath: worktreePath,
            repoPath: config.repoPath
        )

        // Insert worktree path into discovered folders immediately
        discoveredFolders.insert(worktreePath)
        saveDiscoveredFolders()

        // Create placeholder session
        var placeholder = Session(
            name: state.id,
            sessionId: state.id,
            workingDirectory: worktreePath,
            working: true
        )
        placeholder.displayName = branchName
        placeholder.branch = branchName
        placeholder.isPlaceholder = true

        sessions.append(placeholder)
        activeCreations[state.id] = state
        reconcileOrder()

        // Select the placeholder and ensure its folder + section are expanded
        selectedSessionId = state.id
        folderExpansion[worktreePath] = true
        let status = folderStatus[worktreePath] ?? .inProgress
        sectionExpansion[status] = true

        Task { await performWorktreeCreation(state: state, config: config) }
    }

    /// Async pipeline: creates worktree, runs setup script, launches agent.
    private func performWorktreeCreation(state: WorktreeCreationState, config: RepoConfig) async {
        // Step 1: Create worktree
        state.advance(to: .creatingWorktree)
        let result = await GitService.createWorktree(
            repoPath: config.repoPath,
            worktreeFolder: config.worktreeFolderPath,
            branchName: state.branchName
        )
        guard result.succeeded else {
            state.fail(at: .creatingWorktree, message: result.errorMessage)
            handleCreationFailure(state: state, removeDiscoveredFolder: true)
            return
        }
        state.completeCurrentStep()

        // Step 2: Run post-create script (if configured)
        if let script = config.postCreateScript, !script.isEmpty {
            state.advance(to: .runningSetupScript)
            let scriptResult = await GitService.runScript(
                scriptPath: script,
                worktreePath: state.worktreePath,
                branchName: state.branchName,
                repoPath: config.repoPath
            )
            if !scriptResult.succeeded {
                logger.warning("Post-create script failed: \(scriptResult.errorMessage)")
                // Non-fatal — continue with agent launch
            }
            state.completeCurrentStep()
        } else {
            state.skipStep(.runningSetupScript)
        }

        // Rescan so sidebar picks up the new folder from disk
        scanWorktreeFolders()

        // Step 3: Launch agent
        state.advance(to: .launchingAgent)
        let request = LaunchRequest(workingDir: state.worktreePath, agentType: "claude")
        do {
            let response = try await apiClient.launchAgent(request)
            state.completeCurrentStep()
            state.isFinished = true
            replacePlaceholder(placeholderId: state.id, realSessionId: response.sessionId)
        } catch {
            state.fail(at: .launchingAgent, message: error.localizedDescription)
            handleCreationFailure(state: state, removeDiscoveredFolder: false)
        }
    }

    /// Swaps a placeholder session for the real session once it arrives.
    private func replacePlaceholder(placeholderId: String, realSessionId: String) {
        sessions.removeAll { $0.id == placeholderId }
        if selectedSessionId == placeholderId {
            selectedSessionId = realSessionId
        }
        activeCreations.removeValue(forKey: placeholderId)
        reconcileOrder()
    }

    /// Cleans up after a failed creation attempt.
    private func handleCreationFailure(state: WorktreeCreationState, removeDiscoveredFolder: Bool) {
        sessions.removeAll { $0.id == state.id }
        if removeDiscoveredFolder {
            discoveredFolders.remove(state.worktreePath)
            saveDiscoveredFolders()
        }
        if selectedSessionId == state.id {
            selectedSessionId = nil
        }
        activeCreations.removeValue(forKey: state.id)
        reconcileOrder()

        // Show error alert
        let alert = NSAlert()
        alert.messageText = "Worktree Creation Failed"
        alert.informativeText = state.error ?? "An unknown error occurred."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
