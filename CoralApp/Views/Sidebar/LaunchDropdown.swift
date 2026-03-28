import SwiftUI

struct LaunchDropdown: View {
    enum LaunchMode {
        case agent
        case terminal
    }

    let mode: LaunchMode

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

    private var items: [LaunchItem] {
        var result: [LaunchItem] = store.folderOrder.enumerated().map { index, path in
            let label = URL(fileURLWithPath: path).lastPathComponent
            return LaunchItem(number: index + 1, label: label, path: path)
        }
        result.append(LaunchItem(number: result.count + 1))
        return result
    }

    private var agentType: String {
        switch mode {
        case .agent: return "claude"
        case .terminal: return "terminal"
        }
    }

    private var sectionTitle: String {
        switch mode {
        case .agent: return "Claude Agent"
        case .terminal: return "Terminal"
        }
    }

    private var sectionIcon: String {
        switch mode {
        case .agent: return "bubble.left.fill"
        case .terminal: return "terminal.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionView(title: sectionTitle, icon: sectionIcon, items: items, agentType: agentType)
        }
        .padding(.vertical, 8)
        .frame(width: 300)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let digit = Int(press.characters) else { return .ignored }
            let number = digit == 0 ? 10 : digit
            guard let item = items.first(where: { $0.id == number }) else { return .ignored }
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
            .foregroundStyle(CoralTheme.textSecondary)
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
                        .foregroundStyle(CoralTheme.textTertiary)
                        .frame(width: 18, alignment: .trailing)

                    if item.isOther {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(CoralTheme.textSecondary)
                    } else {
                        Image(systemName: "folder")
                            .foregroundStyle(CoralTheme.textSecondary)
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

    private func dismiss() {
        switch mode {
        case .agent:
            store.showingLaunchSheet = false
        case .terminal:
            store.showingTerminalLaunchSheet = false
        }
    }

    private func launch(agentType: String, in workingDir: String) {
        dismiss()
        store.launchSession(agentType: agentType, in: workingDir)
    }

    private func browseAndLaunch(agentType: String) {
        dismiss()
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
