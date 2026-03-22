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

    private var anyFolderExpanded: Bool {
        store.folderOrder.contains { store.folderExpansion[$0] ?? true }
    }

    private var anySectionExpanded: Bool {
        FolderStatus.allCases.contains { store.sectionExpansion[$0] ?? true }
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

        VStack(spacing: 0) {
            // Sidebar header with toggle and add buttons
            HStack(spacing: 12) {
                Spacer()

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
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Expand/Collapse options")

                Button {
                    store.showingLaunchSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Launch new agent (⌘N)")
                .popover(isPresented: $store.showingLaunchSheet, arrowEdge: .bottom) {
                    LaunchDropdown(mode: .agent)
                }

                Button {
                    store.showingTerminalLaunchSheet = true
                } label: {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Launch new terminal (⌘T)")
                .popover(isPresented: $store.showingTerminalLaunchSheet, arrowEdge: .bottom) {
                    LaunchDropdown(mode: .terminal)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List {
                if store.sessions.isEmpty && store.discoveredFolders.isEmpty {
                    ContentUnavailableView {
                        Label("No Active Sessions", systemImage: "bolt.slash")
                    } description: {
                        Text("Launch an agent to get started.")
                    }
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
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: flatItems.map(\.id))
            .listStyle(.sidebar)
        }
        .onChange(of: store.selectedSessionId) { _, newId in
            if let id = newId,
               let session = store.sessions.first(where: { $0.id == id }),
               session.done {
                Task {
                    try? await store.apiClient.acknowledgeSession(
                        sessionName: session.name,
                        sessionId: session.sessionId
                    )
                }
            }
        }
        .navigationTitle("Coral")
        .toolbar {
            ToolbarItem(placement: .status) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(store.isConnected ? .green : .red)
                        .frame(width: 6, height: 6)
                    Text(store.isConnected ? "Connected" : "Disconnected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    .frame(width: 14)

                Image(systemName: status.icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(status.displayName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                if !isExpanded {
                    Text("\(folderCount)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: Capsule())
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
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 8))
    }

    @ViewBuilder
    private func folderRow(for group: SessionGroup) -> some View {
        let isExpanded = store.folderExpansion[group.path] ?? true

        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                .frame(width: 12)

            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            Text(group.label)
                .lineLimit(1)

            Spacer()

            let totalChanged = group.sessions.reduce(0) { $0 + $1.changedFileCount }

            if totalChanged > 0 {
                Label("\(totalChanged)", systemImage: "doc.badge.plus")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if group.sessions.count > 0 {
                Text("\(group.sessions.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.5), in: Capsule())
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
        let isSelected = store.selectedSessionId == session.id
        SessionRowView(session: session)
            .padding(.leading, 36)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
            )
            .opacity(draggingSessionId == session.id ? 0.35 : 1)
            .contentShape(Rectangle())
            .listRowInsets(EdgeInsets(top: -1, leading: 0, bottom: -1, trailing: 8))
            .listRowSeparator(.hidden)
            .onTapGesture {
                store.selectedSessionId = session.id
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
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
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
    }

    @ViewBuilder
    private func sessionContextMenu(for session: Session) -> some View {
        Button("Restart") {
            Task {
                try? await store.apiClient.restartSession(
                    sessionName: session.name,
                    agentType: session.agentType,
                    sessionId: session.sessionId
                )
            }
        }

        Button("Kill", role: .destructive) {
            Task {
                try? await store.apiClient.killSession(
                    sessionName: session.name,
                    agentType: session.agentType,
                    sessionId: session.sessionId
                )
            }
        }
    }
}
