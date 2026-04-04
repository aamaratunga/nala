import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage("nala.terminalAppPath") private var terminalAppPath: String = ""
    @AppStorage("nala.notifications.needsInput") private var needsInputEnabled = true
    @AppStorage("nala.notifications.done") private var doneEnabled = true

    private var terminalAppName: String? {
        guard !terminalAppPath.isEmpty else { return nil }
        return URL(fileURLWithPath: terminalAppPath).deletingPathExtension().lastPathComponent
    }

    var body: some View {
        @Bindable var store = store

        Form {
            Section {
                ForEach($store.repoConfigs) { $config in
                    RepoConfigRow(config: $config) {
                        if let index = store.repoConfigs.firstIndex(where: { $0.id == config.id }) {
                            store.repoConfigs.remove(at: index)
                        }
                    }
                }

                Button("Add Repository") {
                    store.repoConfigs.append(RepoConfig())
                }
            } header: {
                Text("Repositories")
            } footer: {
                Text("Configure git repositories for worktree creation. Subfolders of each worktree folder appear in the sidebar automatically.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(terminalAppName ?? "Not set")
                            .foregroundStyle(terminalAppName != nil ? .primary : .secondary)
                        if !terminalAppPath.isEmpty {
                            Text(terminalAppPath)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer()

                    Button("Browse…") {
                        chooseTerminalApp()
                    }

                    if !terminalAppPath.isEmpty {
                        Button("Clear") {
                            terminalAppPath = ""
                        }
                    }
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("Choose which terminal app to use for \"Attach in Terminal\" (⌘O).")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("e.g. /Users/you/src", text: $store.browseRoot)
                        .textFieldStyle(.plain)

                    if !store.browseRoot.isEmpty {
                        Button("Clear") {
                            store.browseRoot = ""
                        }
                    }
                }
            } header: {
                Text("Browse")
            } footer: {
                Text("Default starting directory when browsing for folders. Leave empty to search common paths.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Needs Input", isOn: $needsInputEnabled)
                Toggle("Done", isOn: $doneEnabled)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Play a sound and show a system notification when a session needs input or finishes.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 500)
    }

    private func chooseTerminalApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose Terminal App"
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        if panel.runModal() == .OK, let url = panel.url {
            terminalAppPath = url.path
        }
    }
}
