import SwiftUI

struct KeyboardShortcutsPanel: View {
    private struct Shortcut: Identifiable {
        let id = UUID()
        let description: String
        let keys: [String]
    }

    private struct ShortcutGroup: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let shortcuts: [Shortcut]
    }

    private let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "General", icon: "keyboard", shortcuts: [
            Shortcut(description: "Show Shortcuts", keys: ["⌘", "/"]),
            Shortcut(description: "New Agent", keys: ["⌘", "N"]),
            Shortcut(description: "New Terminal", keys: ["⌘", "T"]),
            Shortcut(description: "New Worktree", keys: ["⌘", "⌥", "N"]),
            Shortcut(description: "Kill Session", keys: ["⌘", "W"]),
            Shortcut(description: "Attach in Terminal", keys: ["⌘", "O"]),
        ]),
        ShortcutGroup(title: "Navigation", icon: "arrow.up.arrow.down", shortcuts: [
            Shortcut(description: "Toggle Sidebar", keys: ["⌘", "S"]),
            Shortcut(description: "Focus Sidebar", keys: ["⌘", "0"]),
            Shortcut(description: "Focus Terminal", keys: ["Tab"]),
            Shortcut(description: "Navigate Sessions", keys: ["↑", "–", "↓"]),
            Shortcut(description: "Collapse/Expand Folder", keys: ["←", "–", "→"]),
            Shortcut(description: "Jump to Folder", keys: ["⌘", "1-9"]),
            Shortcut(description: "Rename Session", keys: ["Enter"]),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(group.title, systemImage: group.icon)
                            .font(.headline)
                            .foregroundStyle(CoralTheme.textPrimary)

                        VStack(spacing: 2) {
                            ForEach(group.shortcuts) { shortcut in
                                HStack {
                                    Text(shortcut.description)
                                        .font(.callout)
                                        .foregroundStyle(CoralTheme.textSecondary)

                                    Spacer()

                                    HStack(spacing: 2) {
                                        ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { _, key in
                                            if key == "–" {
                                                Text("–")
                                                    .font(.callout)
                                                    .foregroundStyle(CoralTheme.textTertiary)
                                            } else {
                                                Text(key)
                                                    .font(.system(.callout, design: .monospaced))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(CoralTheme.bgSurface, in: RoundedRectangle(cornerRadius: 4))
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .inspectorColumnWidth(min: 220, ideal: 260, max: 320)
    }
}
