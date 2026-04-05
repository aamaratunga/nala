import Foundation
import SwiftUI
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

/// Central observable store for live session state. Owns the native services
/// (TmuxService, PulseParser, EventFileWatcher, GitService) and merges their
/// output into a flat session list.
@Observable
final class SessionStore {
    var sessions: [Session] = []
    var selectedSessionId: String?
    var showingShortcutsPanel = false
    var showCommandPalette = false
    /// Set before showing palette to control initial mode (consumed by CommandPaletteView on appear).
    var pendingPaletteMode: PaletteMode?
    var isConnected = false
    var tmuxNotFound = false

    var pendingKillSession: Session?
    var showingKillConfirmation = false
    var renamingSessionId: String?
    var sidebarFocused = false

    /// Tracks when each session was last focused (selected), for command palette recency sort.
    var lastFocusedTimestamps: [String: Date] = [:]
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    var lastError: String?

    /// Active worktree creation states, keyed by placeholder session ID.
    var activeCreations: [String: WorktreeCreationState] = [:]

    /// Active worktree deletion states, keyed by folder path.
    var activeDeletions: [String: WorktreeDeletionState] = [:]

    /// Active session launch states, keyed by placeholder session ID.
    var activeLaunches: [String: SessionLaunchState] = [:]

    /// Active session restart states, keyed by original session ID.
    var activeRestarts: [String: SessionRestartState] = [:]

    /// Session IDs that were optimistically removed (pending tmux kill).
    /// Prevents polling from re-adding them before they actually disappear.
    private var pendingKills: Set<String> = []

    /// Session IDs whose "done" state has been acknowledged by the user.
    /// While in this set, EventFileWatcher's done=true is suppressed to false.
    private var acknowledgedSessionIds: Set<String> = []

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

    /// Recently browsed paths for the path finder, LRU max 20.
    var recentBrowsePaths: [String] = [] {
        didSet { if !isSuppressingPersistence { saveRecentBrowsePaths() } }
    }

    /// Timestamps recording when each recent browse path was last used (7-day TTL).
    var recentBrowseTimestamps: [String: Date] = [:] {
        didSet { if !isSuppressingPersistence { saveRecentBrowseTimestamps() } }
    }

    /// Configured starting directory for browse mode. Pre-fills the query field.
    var browseRoot: String = "" {
        didSet { if !isSuppressingPersistence { saveBrowseRoot() } }
    }

    /// Subfolders discovered by scanning worktree folders. Cached to
    /// UserDefaults so the sidebar loads instantly on next launch.
    var discoveredFolders: Set<String> = []

    // MARK: - Native Services

    private var tmuxService: TmuxService?
    private var pulseParser: PulseParser?
    private var eventWatcher: EventFileWatcher?
    private var autoNamer: AutoNamer?
    private var serviceTask: Task<Void, Never>?
    private var stalenessTask: Task<Void, Never>?

    /// Collected activity summaries per session for auto-naming.
    private var activityLog: [String: [String]] = [:]

    /// Sessions explicitly renamed by the user (auto-naming won't touch these).
    private var userRenamedSessions: Set<String> = []

    /// Persisted display names (keyed by sessionId)
    private static let displayNamesKey = "nala.displayNames"
    private static let acknowledgedSessionsKey = "nala.acknowledgedSessions"

    private let logger = Logger(subsystem: "com.nala.app", category: "SessionStore")
    private let defaults: UserDefaults
    private var isSuppressingPersistence = false
    private var lastScannedWorktreePaths: Set<String> = []
    private var scanTask: Task<Void, Never>?
    private var hasPerformedStartupCleanup = false

    /// True when running as a test host — skip service connections.
    static let isTestHost = NSClassFromString("XCTestCase") != nil

    /// Cache: workingDirectory → resolved git root (or self if not in a git repo).
    private var gitRootCache: [String: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the git root for a working directory, falling back to the path itself.
    func groupingPath(for workingDirectory: String) -> String {
        if let cached = gitRootCache[workingDirectory] { return cached }
        let resolved = GitService.findGitRoot(from: workingDirectory) ?? workingDirectory
        gitRootCache[workingDirectory] = resolved
        return resolved
    }

    private static let folderOrderKey = "nala.folderOrder"
    private static let sessionOrderKey = "nala.sessionOrder"
    private static let folderExpansionKey = "nala.folderExpansion"
    private static let folderStatusKey = "nala.folderStatus"
    private static let sectionExpansionKey = "nala.sectionExpansion"
    private static let repoConfigsKey = "nala.repoConfigs"
    private static let discoveredFoldersKey = "nala.discoveredFolders"
    private static let recentBrowsePathsKey = "nala.recentBrowsePaths"
    private static let recentBrowseTimestampsKey = "nala.recentBrowseTimestamps"
    private static let browseRootKey = "nala.browseRoot"

    /// The currently selected session, if any.
    var selectedSession: Session? {
        guard let id = selectedSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    /// Flat list of visible session IDs in sidebar order, for keyboard navigation.
    var navigableSessionIds: [String] {
        orderedSections.flatMap { section -> [String] in
            guard sectionExpansion[section.status] ?? true else { return [] }
            return section.groups.flatMap { group -> [String] in
                guard folderExpansion[group.path] ?? true else { return [] }
                return group.sessions.map(\.id)
            }
        }
    }

    /// The folder path containing the currently selected session.
    var focusedFolderPath: String? {
        guard let id = selectedSessionId,
              let session = sessions.first(where: { $0.id == id }) else { return nil }
        return groupingPath(for: session.workingDirectory)
    }

    /// Jump to the Nth visible folder (0-indexed) and select its first session.
    func jumpToFolder(at index: Int) {
        let visibleFolders = orderedSections.flatMap { section -> [SessionGroup] in
            guard sectionExpansion[section.status] ?? true else { return [] }
            return section.groups
        }
        guard index < visibleFolders.count else { return }
        let folder = visibleFolders[index]
        folderExpansion[folder.path] = true
        if let firstSession = folder.sessions.first {
            selectedSessionId = firstSession.id
        }
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

    // MARK: - Error Alerts

    func showErrorAlert(title: String, message: String?) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message ?? "An unknown error occurred."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Dismiss / Retry Progress

    func dismissLaunchProgress() {
        if let id = selectedSessionId {
            sessions.removeAll { $0.id == id && $0.isPlaceholder }
            activeLaunches.removeValue(forKey: id)
            selectedSessionId = nil
            reconcileOrder()
        }
    }

    func dismissRestartProgress() {
        if let id = selectedSessionId {
            activeRestarts.removeValue(forKey: id)
        }
    }

    func dismissCreationProgress() {
        if let id = selectedSessionId, let state = activeCreations[id] {
            sessions.removeAll { $0.id == id }
            activeCreations.removeValue(forKey: id)
            discoveredFolders.remove(state.worktreePath)
            saveDiscoveredFolders()
            selectedSessionId = nil
            reconcileOrder()
        }
    }

    func dismissDeletionProgress() {
        if let id = selectedSessionId {
            activeDeletions.removeValue(forKey: id)
            // Also check if the id is a folder path
            for (key, state) in activeDeletions {
                if state.folderPath == id || sessions.first(where: { $0.id == id })?.workingDirectory == key {
                    activeDeletions.removeValue(forKey: key)
                    break
                }
            }
        }
    }

    func retryWorktreeCreation(state: WorktreeCreationState) {
        let branchName = state.branchName
        let repoPath = state.repoPath
        dismissCreationProgress()
        if let config = repoConfigs.first(where: { $0.repoPath == repoPath }) {
            beginWorktreeCreation(config: config, branchName: branchName)
        }
    }

    func retryWorktreeDeletion(state: WorktreeDeletionState) {
        let folderPath = state.folderPath
        activeDeletions.removeValue(forKey: folderPath)
        beginWorktreeDeletion(folderPath: folderPath)
    }

    // MARK: - Recent Browse Paths

    /// Add a path to the recent browse paths list (LRU, max 20).
    func addRecentBrowsePath(_ path: String) {
        recentBrowsePaths.removeAll { $0 == path }
        recentBrowsePaths.insert(path, at: 0)
        if recentBrowsePaths.count > 20 {
            let evicted = Set(recentBrowsePaths.suffix(from: 20))
            recentBrowsePaths = Array(recentBrowsePaths.prefix(20))
            for path in evicted { recentBrowseTimestamps.removeValue(forKey: path) }
        }
        recentBrowseTimestamps[path] = Date()
    }

    // MARK: - Native Service Lifecycle

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

    /// Start native services for session discovery and monitoring.
    func startServices() {
        loadSavedOrder()
        scanWorktreeFolders()

        guard !Self.isTestHost else { return }

        let tmux = TmuxService()
        let pulse = PulseParser()
        let events = EventFileWatcher()
        let namer = AutoNamer()

        tmuxService = tmux
        if !tmux.tmuxAvailable {
            tmuxNotFound = true
            logger.error("tmux not found — sessions will not be discovered")
        }
        pulseParser = pulse
        eventWatcher = events
        autoNamer = namer

        // Start consuming streams from all services
        serviceTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                // TmuxService polling (1-second cadence)
                group.addTask { [weak self] in
                    for await update in tmux.updates(interval: 1.0) {
                        guard let self else { return }
                        await MainActor.run {
                            self.handleTmuxUpdate(update)
                        }
                    }
                }

                // PulseParser updates
                group.addTask { [weak self] in
                    for await update in pulse.updates() {
                        guard let self else { return }
                        await MainActor.run {
                            self.handlePulseUpdate(update)
                        }
                    }
                }

                // EventFileWatcher updates
                group.addTask { [weak self] in
                    for await update in events.updates() {
                        guard let self else { return }
                        await MainActor.run {
                            self.handleAgentStateUpdate(update)
                        }
                    }
                }

            }
        }

        // Staleness refresh (every 30 seconds)
        stalenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                guard let self else { return }
                self.eventWatcher?.refreshStaleness()
            }
        }
    }

    /// Stop all services. Called on app termination.
    func stopServices() {
        serviceTask?.cancel()
        serviceTask = nil
        stalenessTask?.cancel()
        stalenessTask = nil
        tmuxService?.stop()
        pulseParser?.stopAll()
        eventWatcher?.stopAll()
    }

    // MARK: - Agent State Application

    /// Apply agent state fields to a session at the given index.
    /// Handles acknowledgement clearing, done suppression, and auto-acknowledge.
    private func applyAgentState(_ state: AgentState, toSessionAt idx: Int) {
        let sessionId = sessions[idx].sessionId

        // Auto-clear acknowledgement when agent becomes active again
        if state.working && !state.done {
            if acknowledgedSessionIds.remove(sessionId) != nil {
                saveAcknowledgedSessions()
            }
        }

        sessions[idx].working = state.working
        sessions[idx].done = state.done
        sessions[idx].waitingForInput = state.waitingForInput
        sessions[idx].stuck = state.stuck
        sessions[idx].sleeping = state.sleeping
        sessions[idx].waitingReason = state.waitingReason
        sessions[idx].waitingSummary = state.waitingSummary
        if state.latestEventType != "prompt_submit" {
            sessions[idx].latestEventSummary = state.latestEventSummary
        }
        if let lastTime = state.lastEventTime {
            sessions[idx].stalenessSeconds = Date().timeIntervalSince(lastTime)
        }

        // Suppress done if acknowledged
        if acknowledgedSessionIds.contains(sessionId) {
            sessions[idx].done = false
        }

        // Auto-acknowledge if this session is currently selected
        if sessions[idx].done && selectedSessionId == sessions[idx].id {
            acknowledgedSessionIds.insert(sessionId)
            sessions[idx].done = false
            saveAcknowledgedSessions()
        }
    }

    // MARK: - Tmux Update Handler

    func handleTmuxUpdate(_ update: TmuxUpdate) {
        // Process removals
        let removedNames = Set(update.removed)
        if !removedNames.isEmpty {
            for name in removedNames {
                // Find the session ID for this tmux session name
                if let session = sessions.first(where: { $0.name == name }) {
                    NotificationManager.shared.clearSession(session.id)
                    pendingKills.remove(session.id)
                    pulseParser?.stopWatching(sessionName: name)
                    eventWatcher?.stopWatching(sessionId: session.sessionId)
                    autoNamer?.reset(sessionId: session.sessionId)
                    activityLog.removeValue(forKey: session.sessionId)
                    userRenamedSessions.remove(session.sessionId)
                    acknowledgedSessionIds.remove(session.sessionId)
                }
            }

            sessions.removeAll { session in
                guard !session.isPlaceholder else { return false }
                guard activeDeletions[session.workingDirectory] == nil
                   && activeDeletions[groupingPath(for: session.workingDirectory)] == nil else { return false }
                return removedNames.contains(session.name)
            }

            // Clear selection if needed
            if let selectedId = selectedSessionId,
               sessions.first(where: { $0.id == selectedId }) == nil {
                let isInDeletingFolder = false // Already filtered above
                let isBeingRestarted = activeRestarts[selectedId] != nil
                if !isInDeletingFolder && !isBeingRestarted {
                    selectedSessionId = nil
                }
            }
        }

        // Process additions and current state
        for info in update.current {
            let sessionId = info.sessionId
            let compositeKey = sessionId

            // Skip sessions that were optimistically killed
            guard !pendingKills.contains(compositeKey) else { continue }

            // Start watchers for new sessions
            let logPath = "/tmp/nala_\(info.sessionName).log"
            if pulseParser?.cachedResult(for: info.sessionName) == nil {
                pulseParser?.startWatching(sessionName: info.sessionName, logPath: logPath)
            }
            if info.agentType == "claude", eventWatcher?.cachedState(for: sessionId) == nil {
                eventWatcher?.startWatching(sessionId: sessionId)
            }

            // Build or update the session
            let pulseState = pulseParser?.cachedResult(for: info.sessionName)
            let agentState = eventWatcher?.cachedState(for: sessionId)

            let existingIdx = sessions.firstIndex(where: { $0.id == compositeKey })

            if let idx = existingIdx {
                // Update existing session in place — intentionally do NOT update
                // workingDirectory or logPath here. A session's working directory is
                // set once on initial discovery and stays fixed. Updating it every
                // poll cycle causes groupingPath() → findGitRoot() to walk the
                // filesystem whenever an agent cd's to a new directory, which
                // triggers TCC prompts for protected paths like /Volumes or ~/Music.
                let old = sessions[idx]

                if let pulse = pulseState {
                    if let s = pulse.status { sessions[idx].status = s }
                    if let s = pulse.summary { sessions[idx].summary = s }
                }

                if let state = agentState {
                    applyAgentState(state, toSessionAt: idx)
                }

                NotificationManager.shared.evaluateTransition(old: old, new: sessions[idx])
            } else {
                // New session
                var session = Session(
                    name: info.sessionName,
                    agentType: info.agentType,
                    sessionId: sessionId,
                    tmuxSession: info.sessionName,
                    workingDirectory: info.workingDirectory,
                    logPath: logPath
                )
                session.displayName = loadDisplayName(for: sessionId)
                session.commands = defaultCommands(for: info.agentType)

                if let pulse = pulseState {
                    session.status = pulse.status
                    session.summary = pulse.summary
                }

                sessions.append(session)

                if let state = agentState {
                    applyAgentState(state, toSessionAt: sessions.count - 1)
                }

                NotificationManager.shared.evaluateTransition(old: nil, new: sessions[sessions.count - 1])
            }

            // Check if this new session matches a finished launch placeholder
            for (placeholderId, launch) in activeLaunches {
                if let realId = launch.realSessionId, compositeKey == realId {
                    replaceLaunchPlaceholder(placeholderId: placeholderId, realSessionId: compositeKey)
                    break
                }
            }

            // Check if this new session matches a finished worktree creation placeholder
            for (placeholderId, creation) in activeCreations {
                if creation.isFinished && info.workingDirectory == creation.worktreePath {
                    replacePlaceholder(placeholderId: placeholderId, realSessionId: compositeKey)
                    break
                }
            }

            // Check if this new session matches a finished restart
            for (originalId, restart) in activeRestarts {
                if restart.isFinished && info.workingDirectory == restart.originalSession.workingDirectory {
                    if selectedSessionId == originalId {
                        selectedSessionId = compositeKey
                    }
                    activeRestarts.removeValue(forKey: originalId)
                    break
                }
            }
        }

        // Ensure pipe-pane is configured (handles app restart while tmux persists)
        Task {
            for info in update.added {
                await tmuxService?.ensurePipePane(session: info)
            }
        }

        reconcileOrder()
        performStartupCleanup()
        isConnected = true
    }

    func handlePulseUpdate(_ update: PulseUpdate) {
        // Find the session by tmux session name
        guard let idx = sessions.firstIndex(where: { $0.name == update.sessionName }) else { return }
        let old = sessions[idx]
        if let status = update.result.status {
            sessions[idx].status = status
        }
        if let summary = update.result.summary {
            sessions[idx].summary = summary
        }
        NotificationManager.shared.evaluateTransition(old: old, new: sessions[idx])
    }

    func handleAgentStateUpdate(_ update: AgentStateUpdate) {
        guard let idx = sessions.firstIndex(where: { $0.sessionId == update.sessionId }) else { return }
        let old = sessions[idx]

        applyAgentState(update.state, toSessionAt: idx)

        NotificationManager.shared.evaluateTransition(old: old, new: sessions[idx])

        // Auto-naming: collect activity and trigger when ready
        if let summary = update.state.latestEventSummary, !summary.isEmpty {
            let eventType = update.state.latestEventType ?? ""
            // Capture both tool_use and prompt_submit events for naming context
            if eventType == "tool_use" || eventType == "prompt_submit" {
                let sessionId = update.sessionId
                activityLog[sessionId, default: []].append(summary)

                // Immediate naming from first prompt when session has no name yet
                if eventType == "prompt_submit",
                   sessions[idx].displayName == nil,
                   !userRenamedSessions.contains(sessionId),
                   let namer = autoNamer {
                    let promptText = summary.hasPrefix("Prompt: ") ? String(summary.dropFirst(8)) : summary
                    Task {
                        if let name = await namer.generateNameFromPrompt(promptText) {
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                if let i = self.sessions.firstIndex(where: { $0.sessionId == sessionId }),
                                   !self.userRenamedSessions.contains(sessionId),
                                   self.sessions[i].displayName == nil {
                                    self.sessions[i].displayName = name
                                    self.saveDisplayName(name, for: sessionId)
                                }
                            }
                        }
                    }
                }

                // Skip sessions the user explicitly renamed
                if !userRenamedSessions.contains(sessionId),
                   let namer = autoNamer,
                   // Only count tool_use events for triggering (prompts alone aren't enough signal)
                   eventType == "tool_use",
                   namer.recordEvent(sessionId: sessionId) {
                    let activities = activityLog[sessionId] ?? []
                    let currentName = sessions[idx].displayName
                    Task {
                        if let name = await namer.generateName(activities: activities, currentName: currentName) {
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                // Re-check: user may have renamed during the API call
                                if let i = self.sessions.firstIndex(where: { $0.sessionId == sessionId }),
                                   !self.userRenamedSessions.contains(sessionId) {
                                    self.sessions[i].displayName = name
                                    self.saveDisplayName(name, for: sessionId)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Default Commands

    private func defaultCommands(for agentType: String) -> [SessionCommand] {
        switch agentType {
        case "claude":
            return [
                SessionCommand(name: "compact", description: "Compress conversation history"),
                SessionCommand(name: "clear", description: "Clear conversation and start fresh"),
                SessionCommand(name: "review", description: "Review code changes"),
                SessionCommand(name: "cost", description: "Show token usage and cost"),
                SessionCommand(name: "diff", description: "View changes made in session"),
            ]
        default:
            return []
        }
    }

    // MARK: - Session Launch (Native)

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
        sidebarFocused = false
        let resolvedDir = groupingPath(for: workingDir)
        folderExpansion[resolvedDir] = true
        let status = folderStatus[resolvedDir] ?? .inProgress
        sectionExpansion[status] = true

        guard !Self.isTestHost else { return }
        Task { await performLaunch(state: state) }
    }

    func launchTerminal(in workingDir: String) {
        launchSession(agentType: "terminal", in: workingDir)
    }

    private func performLaunch(state: SessionLaunchState) async {
        guard let tmux = tmuxService else {
            await MainActor.run {
                state.error = "TmuxService not available"
                handleLaunchFailure(state: state)
            }
            return
        }

        do {
            let sessionName = try await tmux.createSession(
                agentType: state.agentType,
                workingDirectory: state.workingDirectory
            )
            // Extract session ID from session name (format: {type}-{uuid})
            await MainActor.run {
                if let parsed = TmuxService.parseSessionName(sessionName) {
                    state.realSessionId = parsed.uuid
                    state.isFinished = true
                    // If the real session already arrived via polling (unlikely), swap now
                    if sessions.contains(where: { $0.id == parsed.uuid }) {
                        replaceLaunchPlaceholder(placeholderId: state.id, realSessionId: parsed.uuid)
                    }
                }
            }
        } catch {
            await MainActor.run {
                state.error = error.localizedDescription
                handleLaunchFailure(state: state)
            }
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
        showErrorAlert(title: "Session Launch Failed", message: state.error)
    }

    // MARK: - Session Kill (Native)

    func killSession(_ session: Session) {
        let snapshot = session
        removeSessionOptimistically(session)

        guard !Self.isTestHost else { return }
        Task {
            await tmuxService?.killSession(name: snapshot.name)
        }
    }

    // MARK: - Send Keys / Command (Native)

    func sendCommand(to session: Session, command: String) {
        guard !Self.isTestHost else { return }
        Task {
            await tmuxService?.sendCommand(session: session.name, command: command)
        }
    }

    func sendKeys(to session: Session, keys: [String]) {
        guard !Self.isTestHost else { return }
        Task {
            await tmuxService?.sendKeys(session: session.name, keys: keys)
        }
    }

    // MARK: - Optimistic Kill

    func restoreSession(_ session: Session) {
        pendingKills.remove(session.id)
        if !sessions.contains(where: { $0.id == session.id }) {
            sessions.append(session)
            reconcileOrder()
        }
    }

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

    // MARK: - Restart (Native)

    func restartSession(_ session: Session) {
        let state = SessionRestartState(originalSession: session)
        activeRestarts[session.id] = state
        guard !Self.isTestHost else { return }
        Task { await performRestart(state: state) }
    }

    private func performRestart(state: SessionRestartState) async {
        let session = state.originalSession
        guard let tmux = tmuxService else {
            await MainActor.run {
                state.error = "TmuxService not available"
                handleRestartFailure(state: state)
            }
            return
        }

        // Phase 1: Kill the session
        await MainActor.run { state.phase = .killing }
        await tmux.killSession(name: session.name)

        // Phase 2: Launch a new session
        await MainActor.run { state.phase = .launching }
        do {
            let sessionName = try await tmux.createSession(
                agentType: session.agentType,
                workingDirectory: session.workingDirectory,
                displayName: session.displayName
            )
            await MainActor.run {
                state.isFinished = true

                // Transfer selection and display name to the new session
                if let parsed = TmuxService.parseSessionName(sessionName) {
                    if selectedSessionId == state.id {
                        selectedSessionId = parsed.uuid
                    }
                    // Preserve display name under the new session ID
                    if let displayName = session.displayName {
                        saveDisplayName(displayName, for: parsed.uuid)
                    }
                }
                activeRestarts.removeValue(forKey: state.id)
            }
        } catch {
            await MainActor.run {
                state.error = error.localizedDescription
                handleRestartFailure(state: state)
            }
        }
    }

    private func handleRestartFailure(state: SessionRestartState) {
        activeRestarts.removeValue(forKey: state.id)
        showErrorAlert(title: "Session Restart Failed", message: state.error)
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

    // MARK: - Rename (Local Persistence)

    func renameSession(_ session: Session, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }

        // Update immediately (no API call needed — persist to UserDefaults)
        sessions[idx].displayName = trimmed
        saveDisplayName(trimmed, for: session.sessionId)
        // Block auto-naming for this session — user chose a name explicitly
        userRenamedSessions.insert(session.sessionId)
    }

    // MARK: - Acknowledge Done State

    func acknowledgeSession(_ sessionId: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }),
              sessions[idx].done else { return }
        acknowledgedSessionIds.insert(sessions[idx].sessionId)
        sessions[idx].done = false
        saveAcknowledgedSessions()
    }

    // MARK: - Display Name Persistence (UserDefaults)

    private func saveDisplayName(_ name: String, for sessionId: String) {
        var names = defaults.dictionary(forKey: Self.displayNamesKey) as? [String: String] ?? [:]
        names[sessionId] = name
        defaults.set(names, forKey: Self.displayNamesKey)
    }

    private func loadDisplayName(for sessionId: String) -> String? {
        let names = defaults.dictionary(forKey: Self.displayNamesKey) as? [String: String]
        return names?[sessionId]
    }

    // MARK: - Acknowledged Sessions Persistence (UserDefaults)

    private func saveAcknowledgedSessions() {
        defaults.set(Array(acknowledgedSessionIds), forKey: Self.acknowledgedSessionsKey)
    }

    private func loadAcknowledgedSessions() {
        if let saved = defaults.stringArray(forKey: Self.acknowledgedSessionsKey) {
            acknowledgedSessionIds = Set(saved)
        }
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
            saveFolderExpansion()
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

        // Prune stale folder expansion entries
        for key in folderExpansion.keys where !keepFolders.contains(key) {
            folderExpansion.removeValue(forKey: key)
        }

        // Prune stale acknowledged session IDs
        let currentSessionIds = Set(sessions.map(\.sessionId))
        let staleAcknowledged = acknowledgedSessionIds.subtracting(currentSessionIds)
        if !staleAcknowledged.isEmpty {
            acknowledgedSessionIds.subtract(staleAcknowledged)
            saveAcknowledgedSessions()
        }
    }

    // MARK: - Startup Cleanup

    /// One-shot cleanup on first tmux update. Prunes stale display names,
    /// event files, tmp files, and validates recent browse paths.
    func performStartupCleanup() {
        guard !hasPerformedStartupCleanup else { return }
        hasPerformedStartupCleanup = true

        let activeSessionIds = Set(sessions.map(\.sessionId))
        let activeSessionNames = Set(sessions.map(\.name))

        pruneDisplayNames(activeSessionIds: activeSessionIds)
        pruneEventFiles(activeSessionIds: activeSessionIds)
        cleanOrphanedTmpFiles(activeSessionNames: activeSessionNames, activeSessionIds: activeSessionIds)
        validateRecentBrowsePaths()

        logger.info("Startup cleanup complete (active sessions: \(activeSessionIds.count))")
    }

    /// Remove display name entries from UserDefaults for sessions that no longer exist.
    func pruneDisplayNames(activeSessionIds: Set<String>) {
        guard var names = defaults.dictionary(forKey: Self.displayNamesKey) as? [String: String] else { return }
        let before = names.count
        names = names.filter { activeSessionIds.contains($0.key) }
        if names.count != before {
            defaults.set(names, forKey: Self.displayNamesKey)
        }
    }

    /// Delete event JSONL files for sessions that no longer exist.
    func pruneEventFiles(activeSessionIds: Set<String>, eventsDirectory: String = EventFileWatcher.eventsDirectory) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: eventsDirectory) else { return }
        for file in files {
            guard file.hasSuffix(".jsonl") else { continue }
            let sessionId = String(file.dropLast(6)) // remove ".jsonl"
            if !activeSessionIds.contains(sessionId) {
                let path = (eventsDirectory as NSString).appendingPathComponent(file)
                try? fm.removeItem(atPath: path)
            }
        }
    }

    /// Remove orphaned /tmp/nala_* files that don't belong to active sessions.
    func cleanOrphanedTmpFiles(activeSessionNames: Set<String>, activeSessionIds: Set<String>, tmpDirectory: String = NSTemporaryDirectory()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: tmpDirectory) else { return }
        for file in files {
            guard file.hasPrefix("nala_") || file.hasPrefix("nala-") else { continue }
            let path = (tmpDirectory as NSString).appendingPathComponent(file)

            if file.hasPrefix("nala-attach-") && file.hasSuffix(".sh") {
                // Always delete attach scripts
                try? fm.removeItem(atPath: path)
            } else if file.hasPrefix("nala_settings_") && file.hasSuffix(".json") {
                // nala_settings_{sessionId}.json
                let stem = String(file.dropFirst("nala_settings_".count).dropLast(".json".count))
                if !activeSessionIds.contains(stem) {
                    try? fm.removeItem(atPath: path)
                }
            } else if file.hasPrefix("nala_prompt_") && file.hasSuffix(".txt") {
                // nala_prompt_{sessionId}.txt
                let stem = String(file.dropFirst("nala_prompt_".count).dropLast(".txt".count))
                if !activeSessionIds.contains(stem) {
                    try? fm.removeItem(atPath: path)
                }
            } else if file.hasPrefix("nala_") && file.hasSuffix(".log") {
                // nala_{sessionName}.log
                let stem = String(file.dropFirst("nala_".count).dropLast(".log".count))
                if !activeSessionNames.contains(stem) {
                    try? fm.removeItem(atPath: path)
                }
            }
        }
    }

    /// Remove recent browse paths that no longer exist on disk or are older than 7 days,
    /// but keep paths under /Volumes/ or /Network/ to avoid blocking on disconnected mounts.
    func validateRecentBrowsePaths() {
        let fm = FileManager.default
        let ttl: TimeInterval = 7 * 24 * 60 * 60 // 7 days
        let now = Date()
        let filtered = recentBrowsePaths.filter { path in
            // Expire paths older than 7 days
            if let timestamp = recentBrowseTimestamps[path],
               now.timeIntervalSince(timestamp) > ttl {
                return false
            }
            if path.hasPrefix("/Volumes/") || path.hasPrefix("/Network/") {
                return true
            }
            return fm.fileExists(atPath: path)
        }
        if filtered.count != recentBrowsePaths.count {
            recentBrowsePaths = filtered
        }
        // Clean up orphan timestamps for paths no longer in the list
        let validPaths = Set(recentBrowsePaths)
        let orphanKeys = recentBrowseTimestamps.keys.filter { !validPaths.contains($0) }
        if !orphanKeys.isEmpty {
            for key in orphanKeys { recentBrowseTimestamps.removeValue(forKey: key) }
        }
    }

    // MARK: - Persistence

    private func loadSavedOrder() {
        isSuppressingPersistence = true
        defer { isSuppressingPersistence = false }

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

        recentBrowsePaths = defaults.stringArray(forKey: Self.recentBrowsePathsKey) ?? []
        if let data = defaults.data(forKey: Self.recentBrowseTimestampsKey),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            recentBrowseTimestamps = decoded
        }
        browseRoot = defaults.string(forKey: Self.browseRootKey) ?? ""
        loadAcknowledgedSessions()
    }

    private func saveFolderOrder() {
        defaults.set(folderOrder, forKey: Self.folderOrderKey)
    }

    private func saveSessionOrder() {
        if let data = try? JSONEncoder().encode(sessionOrder) {
            defaults.set(data, forKey: Self.sessionOrderKey)
        }
    }

    private func saveFolderExpansion() {
        if let data = try? JSONEncoder().encode(folderExpansion) {
            defaults.set(data, forKey: Self.folderExpansionKey)
        }
    }

    private func saveFolderStatus() {
        if let data = try? JSONEncoder().encode(folderStatus) {
            defaults.set(data, forKey: Self.folderStatusKey)
        }
    }

    private func saveSectionExpansion() {
        // Convert FolderStatus keys to String for JSONEncoder
        let stringKeyed = sectionExpansion.reduce(into: [String: Bool]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }
        if let data = try? JSONEncoder().encode(stringKeyed) {
            defaults.set(data, forKey: Self.sectionExpansionKey)
        }
    }

    private func saveRepoConfigs() {
        if let data = try? JSONEncoder().encode(repoConfigs) {
            defaults.set(data, forKey: Self.repoConfigsKey)
        }
    }

    private func saveDiscoveredFolders() {
        defaults.set(Array(discoveredFolders), forKey: Self.discoveredFoldersKey)
    }

    private func saveRecentBrowsePaths() {
        defaults.set(recentBrowsePaths, forKey: Self.recentBrowsePathsKey)
    }

    private func saveRecentBrowseTimestamps() {
        if let data = try? JSONEncoder().encode(recentBrowseTimestamps) {
            defaults.set(data, forKey: Self.recentBrowseTimestampsKey)
        }
    }

    private func saveBrowseRoot() {
        defaults.set(browseRoot, forKey: Self.browseRootKey)
    }

    // MARK: - Worktree Helpers

    /// Finds the matching repo config for a given worktree path.
    func repoConfigForWorktree(path: String) -> RepoConfig? {
        // First check if the path is under a configured worktree folder
        for config in repoConfigs {
            if !config.worktreeFolderPath.isEmpty && path.hasPrefix(config.worktreeFolderPath + "/") {
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

        guard !Self.isTestHost else { return }
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
                logger.info("deleteWorktree: killing session \(session.name)")
                await tmuxService?.killSession(name: session.name)
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
        showErrorAlert(title: "Worktree Deletion Failed", message: state.error)
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

        guard !Self.isTestHost else { return }
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
        guard let tmux = tmuxService else {
            state.fail(at: .launchingAgent, message: "TmuxService not available")
            handleCreationFailure(state: state, removeDiscoveredFolder: false)
            return
        }

        do {
            let sessionName = try await tmux.createSession(
                agentType: "claude",
                workingDirectory: state.worktreePath
            )
            state.completeCurrentStep()
            state.isFinished = true
            if let parsed = TmuxService.parseSessionName(sessionName) {
                replacePlaceholder(placeholderId: state.id, realSessionId: parsed.uuid)
            }
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
        showErrorAlert(title: "Worktree Creation Failed", message: state.error)
    }

    // MARK: - List Directory (Native)

    func listDirectory(at path: String) -> [String]? {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return contents.compactMap { item in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true ? item.lastPathComponent : nil
        }.sorted()
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
