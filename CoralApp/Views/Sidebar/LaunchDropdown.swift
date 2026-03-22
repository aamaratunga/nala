import SwiftUI

struct LaunchDropdown: View {
    @Environment(SessionStore.self) private var store
    @FocusState private var isFocused: Bool

    private struct LaunchItem: Identifiable {
        let id: Int
        let label: String
        let path: String
        let isOther: Bool

        init(number: Int, label: String, path: String) {
            self.id = number
            self.label = label
            self.path = path
            self.isOther = false
        }

        init(number: Int) {
            self.id = number
            self.label = "Other…"
            self.path = ""
            self.isOther = true
        }
    }

    private var claudeItems: [LaunchItem] {
        var items: [LaunchItem] = store.folderOrder.enumerated().map { index, path in
            let label = URL(fileURLWithPath: path).lastPathComponent
            return LaunchItem(number: index + 1, label: label, path: path)
        }
        items.append(LaunchItem(number: items.count + 1))
        return items
    }

    private var terminalItems: [LaunchItem] {
        let offset = store.folderOrder.count + 1
        var items: [LaunchItem] = store.folderOrder.enumerated().map { index, path in
            let label = URL(fileURLWithPath: path).lastPathComponent
            return LaunchItem(number: offset + index + 1, label: label, path: path)
        }
        items.append(LaunchItem(number: offset + items.count + 1))
        return items
    }

    private var allItems: [LaunchItem] {
        claudeItems + terminalItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionView(title: "Claude Agent", icon: "bubble.left.fill", items: claudeItems, agentType: "claude")

            Divider()
                .padding(.vertical, 4)

            sectionView(title: "Terminal", icon: "terminal.fill", items: terminalItems, agentType: "terminal")
        }
        .padding(.vertical, 8)
        .frame(width: 240)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let digit = Int(press.characters) else { return .ignored }
            let number = digit == 0 ? 10 : digit
            guard let item = allItems.first(where: { $0.id == number }) else { return .ignored }
            let agentType = claudeItems.contains(where: { $0.id == number }) ? "claude" : "terminal"
            if item.isOther {
                browseAndLaunch(agentType: agentType)
            } else {
                launch(agentType: agentType, in: item.path)
            }
            return .handled
        }
    }

    @ViewBuilder
    private func sectionView(title: String, icon: String, items: [LaunchItem], agentType: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

        ForEach(items) { item in
            Button {
                if item.isOther {
                    browseAndLaunch(agentType: agentType)
                } else {
                    launch(agentType: agentType, in: item.path)
                }
            } label: {
                HStack(spacing: 8) {
                    Text("\(item.id)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, alignment: .trailing)

                    if item.isOther {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                    }

                    Text(item.label)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func launch(agentType: String, in workingDir: String) {
        store.showingLaunchSheet = false
        store.launchSession(agentType: agentType, in: workingDir)
    }

    private func browseAndLaunch(agentType: String) {
        store.showingLaunchSheet = false
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
    }
}
