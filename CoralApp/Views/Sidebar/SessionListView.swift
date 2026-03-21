import SwiftUI

// MARK: - SidebarItem

private enum SidebarItem: Identifiable, Equatable {
    case folder(SessionGroup)
    case session(Session, folderPath: String)

    var id: String {
        switch self {
        case .folder(let group): return "folder:\(group.path)"
        case .session(let session, _): return session.id
        }
    }

    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool {
        lhs.id == rhs.id
    }
}

struct SessionListView: View {
    @Environment(SessionStore.self) private var store

    @State private var draggingSessionId: String?
    @State private var dragCleanupTask: Task<Void, Never>?

    private var flatItems: [SidebarItem] {
        store.orderedGroups.flatMap { group in
            var items: [SidebarItem] = [.folder(group)]
            let isExpanded = store.folderExpansion[group.path] ?? true
            if isExpanded {
                items += group.sessions.map { .session($0, folderPath: group.path) }
            }
            return items
        }
    }

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selectedSessionId) {
            if store.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Active Sessions", systemImage: "bolt.slash")
                } description: {
                    Text("Launch an agent to get started.")
                }
                .listRowSeparator(.hidden)
            } else {
                ForEach(flatItems) { item in
                    switch item {
                    case .folder(let group):
                        folderRow(for: group)
                    case .session(let session, let folderPath):
                        sessionRow(for: session, in: folderPath)
                    }
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: flatItems.map(\.id))
        .navigationTitle("Coral")
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.showingLaunchSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Launch new agent")
            }

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

            Text("\(group.sessions.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                store.folderExpansion[group.path] = !isExpanded
            }
        }
        .help(group.path.isEmpty ? "Ungrouped sessions" : group.path)
        .contextMenu {
            folderContextMenu(for: group.path)
        }
    }

    @ViewBuilder
    private func sessionRow(for session: Session, in folderPath: String) -> some View {
        SessionRowView(session: session)
            .tag(session.id)
            .padding(.leading, 18)
            .opacity(draggingSessionId == session.id ? 0.35 : 1)
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

        Button("Collapse All Folders") {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                for p in store.folderOrder {
                    store.folderExpansion[p] = false
                }
            }
        }

        Button("Expand All Folders") {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                for p in store.folderOrder {
                    store.folderExpansion[p] = true
                }
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
