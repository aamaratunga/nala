import AppKit
import SwiftUI

// MARK: - SidebarItem

private enum SidebarItem: Identifiable, Equatable {
    case sectionHeader(FolderStatus)
    case folder(SessionGroup)
    case session(Session, folderPath: String)

    var id: String {
        switch self {
        case .sectionHeader(let status): return "section:\(status.rawValue)"
        case .folder(let group): return "folder:\(group.path)"
        case .session(let session, _): return session.id
        }
    }
}

struct SessionListView: View {
    @Environment(SessionStore.self) private var store

    @State private var draggingSessionId: String?
    @State private var dragCleanupTask: Task<Void, Never>?
    @State private var pendingWorktreeDeletion: String?
    @State private var showingDeleteConfirmation = false
    @State private var glowActive = false

    private var anyFolderExpanded: Bool {
        store.folderOrder.contains { store.folderExpansion[$0] ?? true }
    }

    private var anySectionExpanded: Bool {
        FolderStatus.allCases.contains { store.sectionExpansion[$0] ?? true }
    }

    private var hasActiveAgents: Bool {
        store.sessions.contains { $0.status == .working }
    }

    private func toggleAllFolders() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            let collapse = anyFolderExpanded
            for p in store.folderOrder {
                store.folderExpansion[p] = !collapse
            }
        }
    }

    private func toggleAllSections() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            let collapse = anySectionExpanded
            for status in FolderStatus.allCases {
                store.sectionExpansion[status] = !collapse
            }
        }
    }

    private var flatItems: [SidebarItem] {
        store.orderedSections.flatMap { section in
            var items: [SidebarItem] = [.sectionHeader(section.status)]
            let sectionExpanded = store.sectionExpansion[section.status] ?? true
            if sectionExpanded {
                for group in section.groups {
                    items.append(.folder(group))
                    let folderExpanded = store.folderExpansion[group.path] ?? true
                    if folderExpanded {
                        items += group.sessions.map { .session($0, folderPath: group.path) }
                    }
                }
            }
            return items
        }
    }

    var body: some View {
        @Bindable var store = store

        ZStack {
            // Ambient sidebar glow — breathes when agents are active
            if hasActiveAgents {
                RadialGradient(
                    colors: [NalaTheme.coralPrimary.opacity(glowActive ? 0.06 : 0.02), .clear],
                    center: .init(x: 0.7, y: 0.3),
                    startRadius: 0,
                    endRadius: 200
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 4).repeatForever(autoreverses: true), value: glowActive)
                .onAppear { glowActive = true }
            }

            VStack(spacing: 0) {
                // Sidebar header with toggle and add buttons
                HStack(spacing: 12) {
                    Menu {
                        Button {
                            toggleAllSections()
                        } label: {
                            Label(
                                anySectionExpanded ? "Collapse Sections" : "Expand Sections",
                                systemImage: anySectionExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
                            )
                        }

                        Button {
                            toggleAllFolders()
                        } label: {
                            Label(
                                anyFolderExpanded ? "Collapse Folders" : "Expand Folders",
                                systemImage: anyFolderExpanded ? "folder.badge.minus" : "folder.badge.plus"
                            )
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(NalaTheme.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Expand/Collapse options")

                    Spacer()

                    Button {
                        store.pendingPaletteMode = .newAgent
                        withAnimation(.easeOut(duration: 0.15)) { store.showCommandPalette = true }
                    } label: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(NalaTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Launch new agent (⌘N)")

                    Button {
                        store.pendingPaletteMode = .newTerminal
                        withAnimation(.easeOut(duration: 0.15)) { store.showCommandPalette = true }
                    } label: {
                        Image(systemName: "terminal")
                            .foregroundStyle(NalaTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Launch new terminal (⌘T)")

                    Button {
                        store.pendingPaletteMode = .newWorktree
                        withAnimation(.easeOut(duration: 0.15)) { store.showCommandPalette = true }
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(NalaTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("New worktree (⌥⌘N)")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(NalaTheme.bgSurface.opacity(0.65))
                .background(.ultraThinMaterial)

                // Coral-tinted divider (matches detail header divider)
                Rectangle()
                    .fill(NalaTheme.coralPrimary.opacity(0.2))
                    .frame(height: 1)

                if !store.isConnected {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(NalaTheme.amber)
                        Text("Waiting for tmux sessions\u{2026}")
                            .font(.callout)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(NalaTheme.amber.opacity(0.08))
                }

                List {
                    if store.sessions.isEmpty && store.discoveredFolders.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "bolt.slash")
                                .font(.system(size: 32))
                                .foregroundStyle(.tertiary)

                            Text("No Active Sessions")
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            VStack(spacing: 8) {
                                Button {
                                    store.pendingPaletteMode = .newAgent
                                    withAnimation(.easeOut(duration: 0.15)) { store.showCommandPalette = true }
                                } label: {
                                    Label("Launch Agent", systemImage: "sparkles")
                                        .frame(maxWidth: 180)
                                }
                                .controlSize(.large)
                                .buttonStyle(.borderedProminent)
                                .tint(NalaTheme.coralPrimary)

                                Button {
                                    store.pendingPaletteMode = .newTerminal
                                    withAnimation(.easeOut(duration: 0.15)) { store.showCommandPalette = true }
                                } label: {
                                    Label("Open Terminal", systemImage: "terminal")
                                        .frame(maxWidth: 180)
                                }
                                .controlSize(.large)
                                .buttonStyle(.bordered)
                            }

                            Text("\u{2318}N agent  \u{00B7}  \u{2318}T terminal  \u{00B7}  \u{2325}\u{2318}N worktree")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(flatItems) { item in
                            switch item {
                            case .sectionHeader(let status):
                                sectionHeaderRow(for: status)
                            case .folder(let group):
                                folderRow(for: group)
                            case .session(let session, let folderPath):
                                sessionRow(for: session, in: folderPath)
                            }
                        }
                        .background(SidebarTableViewConfigurator())
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: flatItems.map(\.id))
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .background(NalaTheme.bgSurface.opacity(0.75))
            .background(.ultraThinMaterial)
        }
        .onChange(of: hasActiveAgents) { _, active in
            if active {
                glowActive = true
            } else {
                glowActive = false
            }
        }
        .onChange(of: store.selectedSessionId) { _, newId in
            // Cancel rename if selection moves to a different session
            if let renaming = store.renamingSessionId, renaming != newId {
                store.renamingSessionId = nil
            }

            if let id = newId,
               let session = store.sessions.first(where: { $0.id == id }),
               session.status == .done {
                store.acknowledgeSession(id)
            }
        }
        .alert("Delete Worktree?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingWorktreeDeletion = nil
            }
            Button("Delete", role: .destructive) {
                if let path = pendingWorktreeDeletion {
                    pendingWorktreeDeletion = nil
                    store.beginWorktreeDeletion(folderPath: path)
                }
            }
        } message: {
            if let path = pendingWorktreeDeletion {
                Text("This will kill all sessions, run the pre-delete script, and remove the worktree at:\n\(URL(fileURLWithPath: path).lastPathComponent)")
            }
        }
        .navigationTitle("Nala")
        .toolbar {
            ToolbarItem(placement: .status) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(store.isConnected ? NalaTheme.green : NalaTheme.red)
                        .frame(width: 6, height: 6)
                    Text(store.isConnected ? "Connected" : "Disconnected")
                        .font(.caption2)
                        .foregroundStyle(NalaTheme.textSecondary)
                }
                .help(store.isConnected ? "tmux polling active" : "Waiting for tmux sessions")
            }
        }
    }

    // MARK: - Row Builders

    @ViewBuilder
    private func sectionHeaderRow(for status: FolderStatus) -> some View {
        let isExpanded = store.sectionExpansion[status] ?? true
        let folderCount = store.orderedSections
            .first { $0.status == status }?.groups.count ?? 0
        let isFirst = FolderStatus.displayOrder.first == status

        VStack(spacing: 0) {
            if !isFirst {
                Divider()
                    .padding(.horizontal, -8)
                    .padding(.bottom, 6)
            }

            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(NalaTheme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    .frame(width: 14)

                Text(status.icon)
                    .font(.title3)

                Text(status.displayName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(NalaTheme.textSecondary)

                Spacer()

                if !isExpanded {
                    Text("\(folderCount)")
                        .font(.caption2)
                        .foregroundStyle(NalaTheme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(NalaTheme.textTertiary.opacity(0.3), in: Capsule())
                }
            }
        }
        .padding(.top, isFirst ? 4 : 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                store.sectionExpansion[status] = !isExpanded
            }
        }
        .accessibilityLabel("\(status.displayName) section, \(folderCount) folders")
        .accessibilityHint(isExpanded ? "Activate to collapse" : "Activate to expand")
        .accessibilityAddTraits(.isButton)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 8))
    }

    @ViewBuilder
    private func folderRow(for group: SessionGroup) -> some View {
        let isExpanded = store.folderExpansion[group.path] ?? true

        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(NalaTheme.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                .frame(width: 12)

            Text("📁")

            Text(group.label)
                .lineLimit(1)

            Spacer()

            let totalChanged = group.sessions.reduce(0) { $0 + $1.changedFileCount }

            if totalChanged > 0 {
                Label("\(totalChanged)", systemImage: "doc.badge.plus")
                    .font(.caption2)
                    .foregroundStyle(NalaTheme.textSecondary)
            }

            if group.sessions.count > 0 {
                Text("\(group.sessions.count)")
                    .font(.caption2)
                    .foregroundStyle(NalaTheme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(NalaTheme.textTertiary.opacity(0.3), in: Capsule())
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                store.folderExpansion[group.path] = !isExpanded
            }
        }
        .help(group.path.isEmpty ? "Ungrouped sessions" : group.path)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
        .contextMenu {
            folderContextMenu(for: group.path)
        }
    }

    @ViewBuilder
    private func sessionRow(for session: Session, in folderPath: String) -> some View {
        if store.isDeleting(folderPath: folderPath) {
            deletingRow(for: session)
        } else if session.isPlaceholder {
            placeholderRow(for: session)
        } else if store.isRestarting(sessionId: session.id) {
            restartingRow(for: session)
        } else {
            realSessionRow(for: session, in: folderPath)
        }
    }

    @ViewBuilder
    private func placeholderRow(for session: Session) -> some View {
        let isSelected = store.selectedSessionId == session.id

        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)

            Text("Setting up…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .padding(.leading, 36)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(NalaTheme.coralPrimary.opacity(0.5), lineWidth: 1.5)
            }
        }
        .opacity(0.75)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: -1, leading: 0, bottom: -1, trailing: 8))
        .listRowSeparator(.hidden)
        .onTapGesture {
            store.selectedSessionId = session.id
            store.sidebarFocused = true
        }
    }

    @ViewBuilder
    private func deletingRow(for session: Session) -> some View {
        let isSelected = store.selectedSessionId == session.id

        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)

            Text("Removing…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .padding(.leading, 36)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(NalaTheme.coralPrimary.opacity(0.5), lineWidth: 1.5)
            }
        }
        .opacity(0.75)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: -1, leading: 0, bottom: -1, trailing: 8))
        .listRowSeparator(.hidden)
        .onTapGesture {
            store.selectedSessionId = session.id
            store.sidebarFocused = true
        }
    }

    @ViewBuilder
    private func restartingRow(for session: Session) -> some View {
        let isSelected = store.selectedSessionId == session.id

        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)

            Text("Restarting\u{2026}")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .padding(.leading, 36)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(NalaTheme.coralPrimary.opacity(0.5), lineWidth: 1.5)
            }
        }
        .opacity(0.75)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: -1, leading: 0, bottom: -1, trailing: 8))
        .listRowSeparator(.hidden)
        .onTapGesture {
            store.selectedSessionId = session.id
            store.sidebarFocused = true
        }
    }

    /// Returns a highlight color only for actionable states that need user attention.
    /// Working is intentionally excluded — the pulsing status dot is sufficient signal.
    private func sessionHighlightColor(_ session: Session) -> Color? {
        switch session.status {
        case .waitingForInput: return NalaTheme.amber
        case .done:            return NalaTheme.green
        default:               return nil
        }
    }

    @ViewBuilder
    private func realSessionRow(for session: Session, in folderPath: String) -> some View {
        let isSelected = store.selectedSessionId == session.id
        let isEditing = store.renamingSessionId == session.id
        SessionRowView(
            session: session,
            isSelected: isSelected,
            isEditing: isEditing,
            onRename: { newName in
                store.renamingSessionId = nil
                store.renameSession(session, to: newName)
            },
            onCancelRename: {
                store.renamingSessionId = nil
            }
        )
            .padding(.leading, 36)
            // Background: status only (actionable states get colored fill)
            .background(
                Group {
                    if let color = sessionHighlightColor(session) {
                        LinearGradient(
                            colors: [color.opacity(0.18), color.opacity(0.04)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Color.clear
                    }
                }
            )
            // Left accent bar: actionable states only
            .overlay(alignment: .leading) {
                if let color = sessionHighlightColor(session) {
                    LinearGradient(
                        colors: [color, color.opacity(0.5)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: 3)
                    .shadow(color: color.opacity(0.4), radius: 4)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 8,
                        bottomLeadingRadius: 8,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    ))
                }
            }
            // Selection: outline border, independent of status
            // Inset vertically by 1pt to clear the -1 row inset overlap
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(NalaTheme.coralPrimary.opacity(0.5), lineWidth: 1.5)
                        .padding(.vertical, 1)
                }
            }
            .opacity(draggingSessionId == session.id ? 0.35 : 1)
            .contentShape(Rectangle())
            .listRowInsets(EdgeInsets(top: -1, leading: 0, bottom: -1, trailing: 8))
            .listRowSeparator(.hidden)
            .onTapGesture(count: 2) {
                store.renamingSessionId = session.id
            }
            .onTapGesture {
                store.selectedSessionId = session.id
                store.sidebarFocused = false
            }
            .contextMenu {
                sessionContextMenu(for: session)
            }
            .draggable(session.id) {
                sessionDragPreview(for: session)
            }
            .dropDestination(for: String.self) { _, _ in
                finishSessionDrag()
                return true
            } isTargeted: { targeted in
                handleSessionHover(
                    targeted: targeted,
                    targetSession: session,
                    folderPath: folderPath
                )
            }
    }

    // MARK: - Drag Hover Handlers

    private func handleSessionHover(targeted: Bool, targetSession: Session, folderPath: String) {
        if targeted,
           let dragId = draggingSessionId,
           dragId != targetSession.id {
            cancelDragCleanup()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                store.moveSessionToPosition(dragId, targetId: targetSession.id, in: folderPath)
            }
        } else if !targeted {
            scheduleDragCleanup()
        }
    }

    // MARK: - Drag End

    private func finishSessionDrag() {
        cancelDragCleanup()
        draggingSessionId = nil
    }

    /// When no drop target is active for a short period, the drag has ended
    /// (either by a drop outside all targets or by cancellation).
    private func scheduleDragCleanup() {
        dragCleanupTask?.cancel()
        dragCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            if draggingSessionId != nil { finishSessionDrag() }
        }
    }

    private func cancelDragCleanup() {
        dragCleanupTask?.cancel()
        dragCleanupTask = nil
    }

    // MARK: - Drag Previews

    @ViewBuilder
    private func sessionDragPreview(for session: Session) -> some View {
        HStack(spacing: 8) {
            StatusDot(session: session)
            Text(session.displayLabel)
                .font(.headline)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: NalaTheme.coralPrimary.opacity(0.15), radius: 6, y: 2)
        .onAppear { draggingSessionId = session.id }
    }

    // MARK: - Context Menus

    @ViewBuilder
    private func folderContextMenu(for path: String) -> some View {
        let index = store.folderOrder.firstIndex(of: path)

        if let index, index > 0 {
            Button("Move Up") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    store.moveFolders(
                        from: IndexSet(integer: index),
                        to: index - 1
                    )
                }
            }
        }

        if let index, index < store.folderOrder.count - 1 {
            Button("Move Down") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    store.moveFolders(
                        from: IndexSet(integer: index),
                        to: index + 2
                    )
                }
            }
        }

        Divider()

        let currentStatus = store.folderStatus[path] ?? .inProgress
        Menu("Set Status") {
            ForEach(FolderStatus.displayOrder, id: \.self) { status in
                Toggle(status.displayName, isOn: Binding(
                    get: { currentStatus == status },
                    set: { isOn in
                        if isOn {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                store.setFolderStatus(path, to: status)
                            }
                        }
                    }
                ))
            }
        }

        if store.repoConfigs.contains(where: { !$0.worktreeFolderPath.isEmpty && path.hasPrefix($0.worktreeFolderPath + "/") })
            && GitService.isWorktree(path: path)
            && !store.isDeleting(folderPath: path) {
            Divider()

            Button("Delete Worktree…", role: .destructive) {
                pendingWorktreeDeletion = path
                showingDeleteConfirmation = true
            }
        }
    }

    // MARK: - NSTableView Focus Override

    /// Prevents the `NSTableView` backing SwiftUI's `List` from claiming
    /// first responder on click, which would steal focus from the terminal.
    private struct SidebarTableViewConfigurator: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            DispatchQueue.main.async {
                var current: NSView? = view
                while let parent = current?.superview {
                    if let tableView = parent as? NSTableView {
                        tableView.refusesFirstResponder = true
                        return
                    }
                    current = parent
                }
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    @ViewBuilder
    private func sessionContextMenu(for session: Session) -> some View {
        Button("Rename") {
            store.renamingSessionId = session.id
        }

        if session.hasTmuxTarget {
            Button("Attach in Terminal") {
                TerminalLauncher.attachOrPrompt(sessionName: session.tmuxSession)
            }
        }

        Divider()

        Button("Restart") {
            store.restartSession(session)
        }

        Button("Kill", role: .destructive) {
            store.killSession(session)
        }
    }
}
