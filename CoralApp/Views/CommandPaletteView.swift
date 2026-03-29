import SwiftUI
import AppKit

// MARK: - Palette Mode

enum PaletteMode: Equatable {
    case switchSession
    case newAgent
    case newTerminal

    var label: String {
        switch self {
        case .switchSession: return "Switch"
        case .newAgent: return "New Agent"
        case .newTerminal: return "New Terminal"
        }
    }

    var chipColor: Color {
        switch self {
        case .switchSession: return CoralTheme.coralPrimary
        case .newAgent: return CoralTheme.coralPrimary
        case .newTerminal: return CoralTheme.teal
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .switchSession: return "Search sessions..."
        case .newAgent: return "Select folder..."
        case .newTerminal: return "Select folder..."
        }
    }
}

// MARK: - Palette Item

private enum PaletteItem: Identifiable, Equatable {
    case session(Session, isCurrent: Bool)
    case folder(path: String, label: String)
    case action(ActionItem)

    var id: String {
        switch self {
        case .session(let s, _): return "session:\(s.id)"
        case .folder(let path, _): return "folder:\(path)"
        case .action(let a): return "action:\(a.id)"
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

    var body: some View {
        let chars = Array(text)
        Text(chars.enumerated().reduce(AttributedString()) { result, pair in
            var str = AttributedString(String(pair.element))
            if matchedIndices.contains(pair.offset) {
                str.foregroundColor = Color(CoralTheme.textPrimary)
                str.font = .callout.weight(.semibold)
            } else {
                str.foregroundColor = Color(CoralTheme.textSecondary)
                str.font = .callout
            }
            return result + str
        })
    }
}

// MARK: - CommandPaletteView

struct CommandPaletteView: View {
    @Environment(SessionStore.self) private var store
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var mode: PaletteMode = .switchSession
    @FocusState private var isSearchFocused: Bool

    /// External binding for the initial mode to open with.
    var initialMode: PaletteMode = .switchSession

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
                .background(CoralTheme.textTertiary.opacity(0.3))
            resultsList
            footerHints
        }
        .frame(width: 720)
        .frame(maxHeight: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background(CoralTheme.bgSurfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(CoralTheme.coralPrimary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 40, y: 10)
        .shadow(color: CoralTheme.coralPrimary.opacity(0.08), radius: 20)
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
            isSearchFocused = true
        }
        .onChange(of: mode) { _, _ in
            query = ""
            selectedIndex = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteMoveUp)) { _ in
            moveSelection(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteMoveDown)) { _ in
            moveSelection(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteExecuteSelected)) { _ in
            executeSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteSwitchMode)) { notif in
            if let newMode = notif.object as? PaletteMode {
                mode = newMode
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Command palette")
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(CoralTheme.textTertiary)
                .font(.title3)

            if mode != .switchSession {
                modeChip
            }

            TextField(mode == .switchSession && store.sessions.isEmpty
                      ? "Launch a session..."
                      : mode.searchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .foregroundStyle(CoralTheme.textPrimary)
                .focused($isSearchFocused)
                .accessibilityAddTraits(.isSearchField)
                .accessibilityLabel("Search")
                .onChange(of: query) { _, _ in
                    selectedIndex = 0
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

    // MARK: - Results

    private var allItems: [PaletteItem] {
        switch mode {
        case .switchSession:
            return switchModeItems
        case .newAgent, .newTerminal:
            return folderModeItems
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
        items.append(.action(ActionItem(id: "new-agent", label: "New Agent...", icon: "sparkles", shortcut: "⌘N")))
        items.append(.action(ActionItem(id: "new-terminal", label: "New Terminal...", icon: "terminal", shortcut: "⌘T")))
        items.append(.action(ActionItem(id: "new-worktree", label: "New Worktree...", icon: "arrow.triangle.branch", shortcut: "⌥⌘N")))

        return items
    }

    private var folderModeItems: [PaletteItem] {
        // Active folder first, then rest by folder order
        let activePath = store.focusedFolderPath
        var paths = store.folderOrder
        if let active = activePath, let idx = paths.firstIndex(of: active) {
            paths.remove(at: idx)
            paths.insert(active, at: 0)
        }

        var items: [PaletteItem] = paths.map { path in
            let label = URL(fileURLWithPath: path).lastPathComponent
            return .folder(path: path, label: label)
        }

        items.append(.action(ActionItem(id: "browse-other", label: "Browse Other...", icon: "folder.badge.plus", shortcut: "")))
        return items
    }

    private var filteredItems: [PaletteItem] {
        let items = allItems
        guard !query.isEmpty else { return items }

        // Fuzzy filter sessions/folders, always keep actions
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

            case .folder(_, let label):
                if let m = fuzzyMatch(query: query, target: label) {
                    scored.append((item, m.score, m.matchedIndices))
                }

            case .action:
                actions.append(item)
            }
        }

        scored.sort { $0.score > $1.score }
        return scored.map(\.item) + actions
    }

    private var resultsList: some View {
        let items = filteredItems
        let sessionItems = items.filter { if case .session = $0 { return true }; if case .folder = $0 { return true }; return false }
        let actionItems = items.filter { if case .action = $0 { return true }; return false }
        let hasNoResults = sessionItems.isEmpty && mode == .switchSession && !query.isEmpty

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.sessions.isEmpty && mode == .switchSession && query.isEmpty {
                        // Zero sessions state
                        Text("No sessions running")
                            .font(.callout)
                            .foregroundStyle(CoralTheme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else if hasNoResults {
                        Text("No matching sessions")
                            .font(.callout)
                            .foregroundStyle(CoralTheme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else if mode == .newAgent || mode == .newTerminal {
                        if sessionItems.isEmpty && !query.isEmpty {
                            Text("No matching folders")
                                .font(.callout)
                                .foregroundStyle(CoralTheme.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        } else {
                            ForEach(Array(sessionItems.enumerated()), id: \.element.id) { index, item in
                                folderRow(item: item, index: index)
                                    .id(item.id)
                            }
                        }
                    } else {
                        ForEach(Array(sessionItems.enumerated()), id: \.element.id) { index, item in
                            sessionRow(item: item, index: index)
                                .id(item.id)
                        }
                    }

                    if !actionItems.isEmpty {
                        Divider()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)

                        ForEach(Array(actionItems.enumerated()), id: \.element.id) { offset, item in
                            let index = sessionItems.count + offset
                            actionRow(item: item, index: index)
                                .id(item.id)
                        }
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
                                .foregroundStyle(CoralTheme.textPrimary)
                                .lineLimit(1)
                        } else {
                            HighlightedText(text: session.displayLabel, matchedIndices: Set(matchIndices))
                                .lineLimit(1)
                        }

                        if isCurrent {
                            Image(systemName: "checkmark")
                                .font(.subheadline)
                                .foregroundStyle(CoralTheme.textSecondary)
                        }
                    }

                    HStack(spacing: 5) {
                        Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
                            .font(.subheadline)
                            .foregroundStyle(CoralTheme.textTertiary)
                        if let branch = session.branch, !branch.isEmpty {
                            Text("·")
                                .font(.subheadline)
                                .foregroundStyle(CoralTheme.textTertiary)
                            Text(branch)
                                .font(.subheadline)
                                .foregroundStyle(CoralTheme.textTertiary)
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
                            .strokeBorder(CoralTheme.coralPrimary.opacity(0.5), lineWidth: 1.5)
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
        guard case .folder(_, let label) = item else { return AnyView(EmptyView()) }
        let isSelected = index == selectedIndex
        let matchIndices = matchedIndices(for: label)

        return AnyView(
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .foregroundStyle(CoralTheme.textSecondary)
                    .font(.callout)

                if matchIndices.isEmpty {
                    Text(label)
                        .font(.callout)
                        .foregroundStyle(CoralTheme.textPrimary)
                        .lineLimit(1)
                } else {
                    HighlightedText(text: label, matchedIndices: Set(matchIndices))
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
                            .strokeBorder(CoralTheme.coralPrimary.opacity(0.5), lineWidth: 1.5)
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

    private func actionRow(item: PaletteItem, index: Int) -> some View {
        guard case .action(let action) = item else { return AnyView(EmptyView()) }
        let isSelected = index == selectedIndex

        return AnyView(
            HStack(spacing: 12) {
                Image(systemName: action.icon)
                    .foregroundStyle(CoralTheme.textSecondary)
                    .font(.callout)
                    .frame(width: 20)

                Text(action.label)
                    .font(.callout)
                    .foregroundStyle(CoralTheme.textSecondary)

                Spacer()

                if !action.shortcut.isEmpty {
                    Text(action.shortcut)
                        .font(.subheadline)
                        .foregroundStyle(CoralTheme.textTertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(CoralTheme.coralPrimary.opacity(0.5), lineWidth: 1.5)
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
            hintLabel("↑↓", "navigate")
            hintLabel("↵", "select")
            hintLabel("esc", "close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(CoralTheme.bgSurface.opacity(0.5))
    }

    private func hintLabel(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(CoralTheme.textTertiary)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(CoralTheme.textTertiary)
        }
    }

    // MARK: - Keyboard Handling

    /// Called from ContentView's event monitor to handle palette-specific keys.
    /// Returns true if the event was consumed.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // This is a design-time placeholder — actual key handling is in ContentView's monitor
        return false
    }

    // MARK: - Navigation

    func moveSelection(by delta: Int) {
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
            store.selectedSessionId = sessionId
            store.sidebarFocused = false
            store.showCommandPalette = false
            // Focus terminal after palette closes; verify session is still selected
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard store.selectedSessionId == sessionId else { return }
                ContentView.focusTerminal(session: store.selectedSession)
            }

        case .folder(let path, _):
            let agentType = mode == .newAgent ? "claude" : "terminal"
            store.showCommandPalette = false
            store.launchSession(agentType: agentType, in: path)

        case .action(let action):
            switch action.id {
            case "new-agent":
                mode = .newAgent

            case "new-terminal":
                mode = .newTerminal

            case "new-worktree":
                store.showCommandPalette = false
                store.showingCreateWorktreeSheet = true

            case "browse-other":
                let agentType = mode == .newAgent ? "claude" : "terminal"
                store.showCommandPalette = false
                DispatchQueue.main.async {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.message = "Select the project working directory"
                    if panel.runModal() == .OK, let url = panel.url {
                        store.launchSession(agentType: agentType, in: url.path)
                    }
                }

            default:
                break
            }
        }
    }

    // MARK: - Helpers

    private func matchedIndices(for text: String) -> [Int] {
        guard !query.isEmpty else { return [] }
        return fuzzyMatch(query: query, target: text)?.matchedIndices ?? []
    }

    private func accessibilityStatus(_ session: Session) -> String {
        if session.done { return "completed" }
        if session.stuck { return "stuck" }
        if session.waitingForInput { return "waiting for input" }
        if session.working { return "working" }
        return "idle"
    }
}
