import SwiftUI
import AppKit

// MARK: - Palette Mode

enum PathBrowseOrigin: Equatable {
    case newAgent
    case newCodexAgent
    case newTerminal

    var launchAgentType: String {
        switch self {
        case .newAgent: return AgentProvider.claude.id
        case .newCodexAgent: return AgentProvider.codex.id
        case .newTerminal: return AgentProvider.terminal.id
        }
    }

    var returnMode: PaletteMode {
        switch self {
        case .newAgent: return .newAgent
        case .newCodexAgent: return .newCodexAgent
        case .newTerminal: return .newTerminal
        }
    }
}

enum PaletteMode: Equatable {
    case switchSession
    case newAgent
    case newCodexAgent
    case newTerminal
    case newWorktree
    case browsePath(origin: PathBrowseOrigin)

    var label: String {
        switch self {
        case .switchSession: return "Switch"
        case .newAgent: return "New Claude"
        case .newCodexAgent: return "New Codex"
        case .newTerminal: return "New Terminal"
        case .newWorktree: return "New Worktree"
        case .browsePath: return "Browse"
        }
    }

    var chipColor: Color {
        switch self {
        case .switchSession: return NalaTheme.coralPrimary
        case .newAgent: return NalaTheme.claudeOrange
        case .newCodexAgent: return NalaTheme.openaiGreen
        case .newTerminal: return NalaTheme.teal
        case .newWorktree: return NalaTheme.coralPrimary
        case .browsePath: return NalaTheme.blueAccent
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .switchSession: return "Search sessions..."
        case .newAgent: return "Select folder..."
        case .newCodexAgent: return "Select folder..."
        case .newTerminal: return "Select folder..."
        case .newWorktree: return "Search repos..."
        case .browsePath: return "Type a path..."
        }
    }

    var launchAgentType: String? {
        switch self {
        case .newAgent: return AgentProvider.claude.id
        case .newCodexAgent: return AgentProvider.codex.id
        case .newTerminal: return AgentProvider.terminal.id
        default: return nil
        }
    }

    var browseOrigin: PathBrowseOrigin? {
        switch self {
        case .newAgent: return .newAgent
        case .newCodexAgent: return .newCodexAgent
        case .newTerminal: return .newTerminal
        default: return nil
        }
    }
}

// MARK: - Palette Item

struct LaunchFolderItem: Identifiable, Equatable {
    let path: String
    let label: String
    let isSavedRepo: Bool

    var id: String { path }
}

func buildLaunchFolderItems(
    folderOrder: [String],
    folderLastUsed: [String: Date],
    repoConfigs: [RepoConfig],
    activePath: String? = nil
) -> [LaunchFolderItem] {
    struct SourceItem {
        let path: String
        var isSavedRepo: Bool
        let sourceIndex: Int
    }

    var sourceItems: [SourceItem] = []
    var indexByPath: [String: Int] = [:]

    for path in folderOrder where !path.isEmpty {
        guard indexByPath[path] == nil else { continue }
        indexByPath[path] = sourceItems.count
        sourceItems.append(SourceItem(path: path, isSavedRepo: false, sourceIndex: sourceItems.count))
    }

    for config in repoConfigs where !config.repoPath.isEmpty {
        if let index = indexByPath[config.repoPath] {
            sourceItems[index].isSavedRepo = true
        } else {
            indexByPath[config.repoPath] = sourceItems.count
            sourceItems.append(SourceItem(path: config.repoPath, isSavedRepo: true, sourceIndex: sourceItems.count))
        }
    }

    return sourceItems
        .sorted { lhs, rhs in
            // Active folder always first
            let lhsActive = lhs.path == activePath
            let rhsActive = rhs.path == activePath
            if lhsActive != rhsActive { return lhsActive }

            let tA = folderLastUsed[lhs.path]
            let tB = folderLastUsed[rhs.path]

            switch (tA, tB) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.sourceIndex < rhs.sourceIndex
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.sourceIndex < rhs.sourceIndex
            }
        }
        .map { item in
            LaunchFolderItem(
                path: item.path,
                label: URL(fileURLWithPath: item.path).lastPathComponent,
                isSavedRepo: item.isSavedRepo
            )
        }
}

private enum PaletteItem: Identifiable, Equatable {
    case session(Session, isCurrent: Bool)
    case folder(LaunchFolderItem)
    case action(ActionItem)
    case repo(RepoConfig)
    case pathResult(PathResult)

    var id: String {
        switch self {
        case .session(let s, _): return "session:\(s.id)"
        case .folder(let folder): return "folder:\(folder.path)"
        case .action(let a): return "action:\(a.id)"
        case .repo(let r): return "repo:\(r.id)"
        case .pathResult(let p): return "path:\(p.id)"
        }
    }
}

private struct ActionItem: Identifiable, Equatable {
    let id: String
    let label: String
    let icon: String
    let shortcut: String
}

// MARK: - Fuzzy Matching

struct FuzzyMatch {
    let item: String
    let score: Int
    let matchedIndices: [Int]
}

func fuzzyMatch(query: String, target: String) -> FuzzyMatch? {
    let queryChars = Array(query.lowercased())
    let targetChars = Array(target.lowercased())
    guard !queryChars.isEmpty else { return FuzzyMatch(item: target, score: 0, matchedIndices: []) }

    var matchedIndices: [Int] = []
    var qi = 0

    for (ti, tc) in targetChars.enumerated() {
        if qi < queryChars.count && tc == queryChars[qi] {
            matchedIndices.append(ti)
            qi += 1
        }
    }

    guard qi == queryChars.count else { return nil }

    // Score: consecutive runs get bonus, earlier matches score higher
    var score = 100
    var consecutiveBonus = 0
    for (i, idx) in matchedIndices.enumerated() {
        if i > 0 && idx == matchedIndices[i - 1] + 1 {
            consecutiveBonus += 10
        }
        // Penalize later positions slightly
        score -= idx
    }
    score += consecutiveBonus
    // Bonus for matching at start
    if matchedIndices.first == 0 { score += 20 }

    return FuzzyMatch(item: target, score: score, matchedIndices: matchedIndices)
}

// MARK: - Highlighted Text

private struct HighlightedText: View {
    let text: String
    let matchedIndices: Set<Int>
    var font: Font = .callout

    var body: some View {
        let chars = Array(text)
        Text(chars.enumerated().reduce(AttributedString()) { result, pair in
            var str = AttributedString(String(pair.element))
            if matchedIndices.contains(pair.offset) {
                str.foregroundColor = Color(NalaTheme.textPrimary)
                str.font = font.weight(.semibold)
            } else {
                str.foregroundColor = Color(NalaTheme.textSecondary)
                str.font = font
            }
            return result + str
        })
    }
}

// MARK: - CommandPaletteView

struct CommandPaletteView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var mode: PaletteMode = .switchSession
    @FocusState private var isSearchFocused: Bool

    /// Shared state for NSEvent monitor: whether the query field is currently empty.
    static var currentQueryIsEmpty = true
    /// Shared state for NSEvent monitor: whether the current mode is .switchSession.
    static var currentModeIsSwitchSession = true
    /// Shared state for NSEvent monitor: whether the branch name input is active (worktree mode).
    static var isBranchInputActive = false

    // Worktree mode state
    @State private var worktreeSelectedConfig: RepoConfig?
    @State private var branchName = ""
    @FocusState private var isBranchFocused: Bool

    // Browse mode state
    @State private var pathFinder = PathFinder()

    /// External binding for the initial mode to open with.
    var initialMode: PaletteMode = .switchSession

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
                .background(NalaTheme.textTertiary.opacity(0.3))
            resultsList
            footerHints
        }
        .frame(width: 720)
        .frame(maxHeight: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background(NalaTheme.bgSurfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(NalaTheme.coralPrimary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 40, y: 10)
        .shadow(color: NalaTheme.coralPrimary.opacity(0.08), radius: 20)
        .onAppear {
            // Use pending mode from store if set (from menu commands), otherwise use initialMode
            if let pending = store.pendingPaletteMode {
                mode = pending
                store.pendingPaletteMode = nil
            } else {
                mode = initialMode
            }
            query = ""
            selectedIndex = 0
            worktreeSelectedConfig = nil
            branchName = ""
            isSearchFocused = true
            CommandPaletteView.currentQueryIsEmpty = true
            CommandPaletteView.currentModeIsSwitchSession = (mode == .switchSession)
            CommandPaletteView.isBranchInputActive = false
        }
        .onChange(of: store.pendingPaletteMode) { _, newPending in
            // When the palette is already open and a sidebar/menu button sets a new mode
            if let newPending {
                mode = newPending
                store.pendingPaletteMode = nil
            }
        }
        .onChange(of: mode) { _, newMode in
            selectedIndex = 0
            worktreeSelectedConfig = nil
            branchName = ""
            CommandPaletteView.currentModeIsSwitchSession = (newMode == .switchSession)
            CommandPaletteView.isBranchInputActive = false
            if case .browsePath = newMode, !store.browseRoot.isEmpty {
                let root = store.browseRoot.hasSuffix("/") ? store.browseRoot : store.browseRoot + "/"
                query = root
                pathFinder.search(query: root, roots: store.folderOrder, recentPaths: store.recentBrowsePaths, browseRoot: store.browseRoot)
            } else if case .browsePath = newMode {
                query = ""
                pathFinder.search(query: "", roots: store.folderOrder, recentPaths: store.recentBrowsePaths, browseRoot: store.browseRoot)
            } else {
                query = ""
                pathFinder.cancel()
            }
        }
        .onChange(of: query) { _, newQuery in
            selectedIndex = 0
            CommandPaletteView.currentQueryIsEmpty = newQuery.isEmpty
            if case .browsePath = mode {
                pathFinder.search(query: newQuery, roots: store.folderOrder, recentPaths: store.recentBrowsePaths, browseRoot: store.browseRoot)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteMoveUp)) { _ in
            moveSelection(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteMoveDown)) { _ in
            moveSelection(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteExecuteSelected)) { _ in
            if case .newWorktree = mode, worktreeSelectedConfig != nil {
                createWorktree()
            } else {
                executeSelected()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteSwitchMode)) { notif in
            if let newMode = notif.object as? PaletteMode {
                mode = newMode
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteEscapePressed)) { _ in
            handleEscape()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteTabPressed)) { _ in
            handleTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteBackspaceEmpty)) { _ in
            handleBackspaceEmpty()
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Command palette")
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(NalaTheme.textTertiary)
                .font(.title3)

            if mode != .switchSession {
                modeChip
            }

            if case .newWorktree = mode, let config = worktreeSelectedConfig {
                // Branch input mode within worktree
                branchInputBar(config: config)
            } else {
                TextField(mode == .switchSession && store.sessions.isEmpty
                          ? "Launch a session..."
                          : mode.searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(NalaTheme.textPrimary)
                    .focused($isSearchFocused)
                    .accessibilityAddTraits(.isSearchField)
                    .accessibilityLabel("Search")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var modeChip: some View {
        Text(mode.label)
            .font(.callout)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(mode.chipColor, in: Capsule())
    }

    // MARK: - Worktree Branch Input

    private func branchInputBar(config: RepoConfig) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    worktreeSelectedConfig = nil
                    branchName = ""
                    isSearchFocused = true
                }
                CommandPaletteView.isBranchInputActive = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption)
                    .foregroundStyle(NalaTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to repo list")

            Text(config.displayName)
                .font(.callout)
                .foregroundStyle(NalaTheme.textSecondary)
                .lineLimit(1)

            TextField("Branch name", text: $branchName)
                .textFieldStyle(.plain)
                .font(.title3)
                .foregroundStyle(NalaTheme.textPrimary)
                .focused($isBranchFocused)
                .accessibilityLabel("Branch name")

            if let error = BranchValidation.validate(branchName) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(NalaTheme.red)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Results

    private var allItems: [PaletteItem] {
        switch mode {
        case .switchSession:
            return switchModeItems
        case .newAgent, .newCodexAgent, .newTerminal:
            return folderModeItems
        case .newWorktree:
            return worktreeModeItems
        case .browsePath:
            return browsePathItems
        }
    }

    private var switchModeItems: [PaletteItem] {
        // Sessions sorted by last focused timestamp (most recent first),
        // with current session second (you're already there).
        let currentId = store.selectedSessionId
        let sorted = store.sessions
            .filter { !$0.isPlaceholder }
            .sorted { a, b in
                let tA = store.lastFocusedTimestamps[a.id] ?? .distantPast
                let tB = store.lastFocusedTimestamps[b.id] ?? .distantPast
                // Current session sorts after the most recent non-current
                if a.id == currentId && b.id != currentId { return false }
                if b.id == currentId && a.id != currentId { return true }
                return tA > tB
            }

        var items: [PaletteItem] = sorted.map { .session($0, isCurrent: $0.id == currentId) }

        // Action items always at bottom
        items.append(.action(ActionItem(id: "new-agent", label: "New Claude…", icon: "sparkles", shortcut: "⌘N")))
        items.append(.action(ActionItem(id: "new-codex-agent", label: "New Codex…", icon: "chevron.left.forwardslash.chevron.right", shortcut: "⇧⌘N")))
        items.append(.action(ActionItem(id: "new-terminal", label: "New Terminal...", icon: "terminal", shortcut: "⌘T")))
        items.append(.action(ActionItem(id: "new-worktree", label: "New Worktree...", icon: "arrow.triangle.branch", shortcut: "⌥⌘N")))

        return items
    }

    private var folderModeItems: [PaletteItem] {
        var items = buildLaunchFolderItems(
            folderOrder: store.folderOrder,
            folderLastUsed: store.folderLastUsed,
            repoConfigs: store.repoConfigs,
            activePath: store.focusedFolderPath
        ).map { PaletteItem.folder($0) }

        items.append(.action(ActionItem(id: "browse-other", label: "Browse Other...", icon: "folder.badge.plus", shortcut: "")))
        return items
    }

    private var worktreeModeItems: [PaletteItem] {
        guard worktreeSelectedConfig == nil else { return [] }

        let configs = store.validRepoConfigs
        var items: [PaletteItem] = configs.map { .repo($0) }
        items.append(.action(ActionItem(id: "add-repository", label: "Add Repository...", icon: "plus.circle", shortcut: "")))
        return items
    }

    private var browsePathItems: [PaletteItem] {
        pathFinder.results.map { .pathResult($0) }
    }

    private var filteredItems: [PaletteItem] {
        let items = allItems
        guard !query.isEmpty else { return items }

        // Browse mode: PathFinder already handles filtering
        if case .browsePath = mode { return items }

        // Fuzzy filter sessions/folders/repos, always keep actions
        var scored: [(item: PaletteItem, score: Int, indices: [Int])] = []
        var actions: [PaletteItem] = []

        for item in items {
            switch item {
            case .session(let s, _):
                // Match against display label, folder name, and branch
                let targets = [
                    s.displayLabel,
                    URL(fileURLWithPath: s.workingDirectory).lastPathComponent,
                    s.branch ?? ""
                ]
                var bestMatch: FuzzyMatch?
                for target in targets {
                    if let m = fuzzyMatch(query: query, target: target) {
                        if bestMatch == nil || m.score > bestMatch!.score {
                            bestMatch = m
                        }
                    }
                }
                if let m = bestMatch {
                    scored.append((item, m.score, m.matchedIndices))
                }

            case .folder(let folder):
                let targets = [folder.label, folder.path]
                var bestMatch: FuzzyMatch?
                for target in targets {
                    if let m = fuzzyMatch(query: query, target: target) {
                        if bestMatch == nil || m.score > bestMatch!.score {
                            bestMatch = m
                        }
                    }
                }
                if let m = bestMatch {
                    scored.append((item, m.score, m.matchedIndices))
                }

            case .repo(let config):
                if let m = fuzzyMatch(query: query, target: config.displayName) {
                    scored.append((item, m.score, m.matchedIndices))
                }

            case .pathResult:
                // Already filtered by PathFinder
                scored.append((item, 0, []))

            case .action:
                actions.append(item)
            }
        }

        scored.sort { $0.score > $1.score }
        return scored.map(\.item) + actions
    }

    private var resultsList: some View {
        let items = filteredItems
        let contentItems = items.filter { if case .action = $0 { return false }; return true }
        let actionItems = items.filter { if case .action = $0 { return true }; return false }

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if case .newWorktree = mode, worktreeSelectedConfig != nil {
                        // Branch input mode: no results list needed
                        EmptyView()
                    } else if case .browsePath = mode {
                        browseResultsContent(items: contentItems, actionItems: actionItems)
                    } else if case .newWorktree = mode {
                        worktreeResultsContent(items: contentItems, actionItems: actionItems)
                    } else if mode == .switchSession {
                        switchResultsContent(items: contentItems, actionItems: actionItems)
                    } else {
                        folderResultsContent(items: contentItems, actionItems: actionItems)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 460)
            .onChange(of: selectedIndex) { _, newIndex in
                let allItems = filteredItems
                if newIndex >= 0 && newIndex < allItems.count {
                    proxy.scrollTo(allItems[newIndex].id, anchor: .center)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search results, \(items.count) items")
        }
    }

    // MARK: - Results Content by Mode

    @ViewBuilder
    private func switchResultsContent(items: [PaletteItem], actionItems: [PaletteItem]) -> some View {
        let hasNoResults = items.isEmpty && !query.isEmpty

        if store.sessions.isEmpty && query.isEmpty {
            Text("No sessions running")
                .font(.callout)
                .foregroundStyle(NalaTheme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else if hasNoResults {
            Text("No matching sessions")
                .font(.callout)
                .foregroundStyle(NalaTheme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                sessionRow(item: item, index: index)
                    .id(item.id)
            }
        }

        actionDividerAndRows(actionItems: actionItems, offset: items.count)
    }

    @ViewBuilder
    private func folderResultsContent(items: [PaletteItem], actionItems: [PaletteItem]) -> some View {
        if items.isEmpty && !query.isEmpty {
            Text("No matching folders")
                .font(.callout)
                .foregroundStyle(NalaTheme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                folderRow(item: item, index: index)
                    .id(item.id)
            }
        }

        actionDividerAndRows(actionItems: actionItems, offset: items.count)
    }

    @ViewBuilder
    private func worktreeResultsContent(items: [PaletteItem], actionItems: [PaletteItem]) -> some View {
        if items.isEmpty && query.isEmpty && store.validRepoConfigs.isEmpty {
            VStack(spacing: 8) {
                Text("No repositories configured")
                    .font(.callout)
                    .foregroundStyle(NalaTheme.textTertiary)
                Text("Add a repository in Settings to create worktrees.")
                    .font(.caption)
                    .foregroundStyle(NalaTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else if items.isEmpty && !query.isEmpty {
            Text("No matching repos")
                .font(.callout)
                .foregroundStyle(NalaTheme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                repoRow(item: item, index: index)
                    .id(item.id)
            }
        }

        actionDividerAndRows(actionItems: actionItems, offset: items.count)
    }

    @ViewBuilder
    private func browseResultsContent(items: [PaletteItem], actionItems: [PaletteItem]) -> some View {
        if items.isEmpty && query.isEmpty {
            if store.recentBrowsePaths.isEmpty {
                Text("Type a path to get started")
                    .font(.callout)
                    .foregroundStyle(NalaTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                // Show recent paths with section header
                sectionHeader("Recent")
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    pathResultRow(item: item, index: index)
                        .id(item.id)
                }
            }
        } else if items.isEmpty && !query.isEmpty {
            if pathFinder.isSearching {
                Text("Searching...")
                    .font(.callout)
                    .foregroundStyle(NalaTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                Text("No matching directories")
                    .font(.callout)
                    .foregroundStyle(NalaTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
        } else {
            // Split into recent and other results
            let recentItems = items.enumerated().filter {
                if case .pathResult(let p) = $0.element { return p.isRecent }
                return false
            }
            let otherItems = items.enumerated().filter {
                if case .pathResult(let p) = $0.element { return !p.isRecent }
                return false
            }

            if !recentItems.isEmpty {
                sectionHeader("Recent")
                ForEach(recentItems, id: \.element.id) { index, item in
                    pathResultRow(item: item, index: index)
                        .id(item.id)
                }
            }

            if !otherItems.isEmpty {
                if !recentItems.isEmpty {
                    sectionHeader("Results")
                }
                ForEach(otherItems, id: \.element.id) { index, item in
                    pathResultRow(item: item, index: index)
                        .id(item.id)
                }
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(NalaTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    // MARK: - Action Rows Helper

    @ViewBuilder
    private func actionDividerAndRows(actionItems: [PaletteItem], offset: Int) -> some View {
        if !actionItems.isEmpty {
            Divider()
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

            ForEach(Array(actionItems.enumerated()), id: \.element.id) { idx, item in
                let index = offset + idx
                actionRow(item: item, index: index)
                    .id(item.id)
            }
        }
    }

    // MARK: - Row Views

    private func sessionRow(item: PaletteItem, index: Int) -> some View {
        guard case .session(let session, let isCurrent) = item else { return AnyView(EmptyView()) }
        let isSelected = index == selectedIndex
        let matchIndices = matchedIndices(for: session.displayLabel)

        return AnyView(
            HStack(spacing: 12) {
                StatusDot(session: session)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if matchIndices.isEmpty {
                            Text(session.displayLabel)
                                .font(.callout)
                                .foregroundStyle(NalaTheme.textPrimary)
                                .lineLimit(1)
                        } else {
                            HighlightedText(text: session.displayLabel, matchedIndices: Set(matchIndices))
                                .lineLimit(1)
                        }

                        if isCurrent {
                            Image(systemName: "checkmark")
                                .font(.subheadline)
                                .foregroundStyle(NalaTheme.textSecondary)
                        }
                    }

                    HStack(spacing: 5) {
                        Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
                            .font(.subheadline)
                            .foregroundStyle(NalaTheme.textTertiary)
                        if let branch = session.branch, !branch.isEmpty {
                            Text("·")
                                .font(.subheadline)
                                .foregroundStyle(NalaTheme.textTertiary)
                            Text(branch)
                                .font(.subheadline)
                                .foregroundStyle(NalaTheme.textTertiary)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(NalaTheme.coralPrimary.opacity(0.5), lineWidth: 1.5)
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                executeItem(item)
            }
            .onHover { hovering in
                if hovering { selectedIndex = index }
            }
            .accessibilityLabel("\(session.displayLabel), \(accessibilityStatus(session))")
        )
    }

    private func folderRow(item: PaletteItem, index: Int) -> some View {
        guard case .folder(let folder) = item else { return AnyView(EmptyView()) }
        let isSelected = index == selectedIndex
        let matchIndices = matchedIndices(for: folder.label)
        let pathMatchIndices = matchedIndices(for: folder.path)

        return AnyView(
            HStack(spacing: 12) {
                Image(systemName: folder.isSavedRepo ? "arrow.triangle.branch" : "folder")
                    .foregroundStyle(folder.isSavedRepo ? NalaTheme.coralPrimary : NalaTheme.textSecondary)
                    .font(.callout)

                VStack(alignment: .leading, spacing: 2) {
                    if matchIndices.isEmpty {
                        Text(folder.label)
                            .font(.callout)
                            .foregroundStyle(NalaTheme.textPrimary)
                            .lineLimit(1)
                    } else {
                        HighlightedText(text: folder.label, matchedIndices: Set(matchIndices))
                            .lineLimit(1)
                    }

                    if pathMatchIndices.isEmpty {
                        Text(folder.path)
                            .font(.caption)
                            .foregroundStyle(NalaTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    } else {
                        HighlightedText(text: folder.path, matchedIndices: Set(pathMatchIndices), font: .caption)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(NalaTheme.coralPrimary.opacity(0.5), lineWidth: 1.5)
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                executeItem(item)
            }
            .onHover { hovering in
                if hovering { selectedIndex = index }
            }
            .accessibilityLabel("\(folder.label), \(folder.isSavedRepo ? "saved repository" : "folder"), \(folder.path)")
        )
    }

    private func repoRow(item: PaletteItem, index: Int) -> some View {
        guard case .repo(let config) = item else { return AnyView(EmptyView()) }
        let isSelected = index == selectedIndex
        let matchIndices = matchedIndices(for: config.displayName)

        return AnyView(
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .foregroundStyle(NalaTheme.textSecondary)
                    .font(.callout)

                if matchIndices.isEmpty {
                    Text(config.displayName)
                        .font(.callout)
                        .foregroundStyle(NalaTheme.textPrimary)
                        .lineLimit(1)
                } else {
                    HighlightedText(text: config.displayName, matchedIndices: Set(matchIndices))
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(NalaTheme.coralPrimary.opacity(0.5), lineWidth: 1.5)
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                executeItem(item)
            }
            .onHover { hovering in
                if hovering { selectedIndex = index }
            }
            .accessibilityLabel("Repository \(config.displayName)")
        )
    }

    private func pathResultRow(item: PaletteItem, index: Int) -> some View {
        guard case .pathResult(let result) = item else { return AnyView(EmptyView()) }
        let isSelected = index == selectedIndex
        let matchIndices = matchedIndices(for: result.displayName)

        return AnyView(
            HStack(spacing: 12) {
                Image(systemName: result.isGitRepo ? "arrow.triangle.branch" : "folder")
                    .foregroundStyle(result.isGitRepo ? NalaTheme.coralPrimary : NalaTheme.textSecondary)
                    .font(.callout)

                VStack(alignment: .leading, spacing: 2) {
                    if matchIndices.isEmpty {
                        Text(result.displayName)
                            .font(.callout)
                            .foregroundStyle(NalaTheme.textPrimary)
                            .lineLimit(1)
                    } else {
                        HighlightedText(text: result.displayName, matchedIndices: Set(matchIndices))
                            .lineLimit(1)
                    }

                    Text(result.path)
                        .font(.caption)
                        .foregroundStyle(NalaTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(NalaTheme.coralPrimary.opacity(0.5), lineWidth: 1.5)
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                executeItem(item)
            }
            .onHover { hovering in
                if hovering { selectedIndex = index }
            }
            .accessibilityLabel("\(result.displayName), \(result.isGitRepo ? "git repository" : "directory")")
        )
    }

    private func actionRow(item: PaletteItem, index: Int) -> some View {
        guard case .action(let action) = item else { return AnyView(EmptyView()) }
        let isSelected = index == selectedIndex

        return AnyView(
            HStack(spacing: 12) {
                Image(systemName: action.icon)
                    .foregroundStyle(NalaTheme.textSecondary)
                    .font(.callout)
                    .frame(width: 20)

                Text(action.label)
                    .font(.callout)
                    .foregroundStyle(NalaTheme.textSecondary)

                Spacer()

                if !action.shortcut.isEmpty {
                    Text(action.shortcut)
                        .font(.subheadline)
                        .foregroundStyle(NalaTheme.textTertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(NalaTheme.coralPrimary.opacity(0.5), lineWidth: 1.5)
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                executeItem(item)
            }
            .onHover { hovering in
                if hovering { selectedIndex = index }
            }
        )
    }

    // MARK: - Footer

    private var footerHints: some View {
        HStack(spacing: 16) {
            switch mode {
            case .browsePath:
                hintLabel("↑↓", "navigate")
                hintLabel("↵", "select")
                hintLabel("tab", "drill down")
                hintLabel("⌫", "up")
                hintLabel("esc", "close")
            case .newWorktree where worktreeSelectedConfig != nil:
                hintLabel("↵", "create")
                hintLabel("esc", "back")
            default:
                hintLabel("↑↓", "navigate")
                hintLabel("↵", "select")
                hintLabel("esc", "close")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(NalaTheme.bgSurface.opacity(0.5))
    }

    private func hintLabel(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(NalaTheme.textTertiary)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(NalaTheme.textTertiary)
        }
    }

    // MARK: - Escape Handling

    private func handleEscape() {
        switch mode {
        case .browsePath(let origin):
            // Exit browse mode, return to the originating mode
            mode = origin.returnMode

        case .newWorktree:
            if worktreeSelectedConfig != nil {
                if !branchName.isEmpty {
                    // Clear branch text first
                    branchName = ""
                } else {
                    // Back to repo selection
                    worktreeSelectedConfig = nil
                    CommandPaletteView.isBranchInputActive = false
                    isSearchFocused = true
                }
            } else {
                closePalette()
            }

        default:
            if !query.isEmpty {
                query = ""
            } else {
                closePalette()
            }
        }
    }

    // MARK: - Backspace-on-Empty Handling

    func handleBackspaceEmpty() {
        switch mode {
        case .newAgent, .newCodexAgent, .newTerminal, .browsePath:
            mode = .switchSession
        default:
            break
        }
    }

    // MARK: - Tab Handling (Browse Mode Drill-Down)

    private func handleTab() {
        guard case .browsePath = mode else { return }

        let items = filteredItems
        guard selectedIndex >= 0 && selectedIndex < items.count else { return }

        if case .pathResult(let result) = items[selectedIndex], result.isDirectory {
            // Replace query with the selected directory path + "/"
            query = result.path + "/"
        }
    }

    // MARK: - Navigation

    func moveSelection(by delta: Int) {
        // Skip selection movement when in worktree branch input
        if case .newWorktree = mode, worktreeSelectedConfig != nil { return }

        let items = filteredItems
        guard !items.isEmpty else { return }
        let newIndex = selectedIndex + delta
        selectedIndex = max(0, min(newIndex, items.count - 1))
    }

    func executeSelected() {
        let items = filteredItems
        guard selectedIndex >= 0 && selectedIndex < items.count else { return }
        executeItem(items[selectedIndex])
    }

    private func executeItem(_ item: PaletteItem) {
        switch item {
        case .session(let session, _):
            let sessionId = session.id
            let wasAlreadySelected = store.selectedSessionId == sessionId
            store.selectedSessionId = sessionId
            store.sidebarFocused = false
            store.showCommandPalette = false
            if wasAlreadySelected {
                // View won't be recreated so viewDidMoveToWindow won't fire.
                // Focus directly after palette dismiss animation completes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard store.selectedSessionId == sessionId else { return }
                    ContentView.focusTerminal(session: store.selectedSession)
                }
            }

        case .folder(let folder):
            guard let agentType = mode.launchAgentType else { return }
            store.showCommandPalette = false
            store.launchSession(agentType: agentType, in: folder.path)

        case .repo(let config):
            // Select repo, transition to branch input
            withAnimation(.easeInOut(duration: 0.15)) {
                worktreeSelectedConfig = config
                branchName = ""
            }
            CommandPaletteView.isBranchInputActive = true
            // Focus the branch text field after a tick
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isBranchFocused = true
            }

        case .pathResult(let result):
            if case .browsePath(let origin) = mode {
                store.addRecentBrowsePath(result.path)
                store.showCommandPalette = false
                store.launchSession(agentType: origin.launchAgentType, in: result.path)
            }

        case .action(let action):
            switch action.id {
            case "new-agent":
                mode = .newAgent

            case "new-codex-agent":
                mode = .newCodexAgent

            case "new-terminal":
                mode = .newTerminal

            case "new-worktree":
                mode = .newWorktree

            case "browse-other":
                if let origin = mode.browseOrigin {
                    mode = .browsePath(origin: origin)
                }

            case "add-repository":
                store.showCommandPalette = false
                store.repoConfigs.append(RepoConfig())
                openSettings()

            default:
                break
            }
        }
    }

    // MARK: - Worktree Creation

    private func createWorktree() {
        guard let config = worktreeSelectedConfig,
              !branchName.isEmpty,
              BranchValidation.validate(branchName) == nil else { return }

        store.beginWorktreeCreation(config: config, branchName: branchName)
        store.showCommandPalette = false
    }

    // MARK: - Helpers

    private func closePalette() {
        withAnimation(.easeIn(duration: 0.1)) {
            store.showCommandPalette = false
        }
        ContentView.restoreFocusAfterPalette(store: store)
    }

    private func matchedIndices(for text: String) -> [Int] {
        guard !query.isEmpty else { return [] }
        return fuzzyMatch(query: query, target: text)?.matchedIndices ?? []
    }

    private func accessibilityStatus(_ session: Session) -> String {
        switch session.status {
        case .done:             return "completed"
        case .waitingForInput:  return "waiting for input"
        case .working:          return "working"
        case .sleeping:         return "sleeping"
        case .idle:             return "idle"
        }
    }
}
