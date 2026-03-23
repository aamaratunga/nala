import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage("coral.notifications.needsInput") private var needsInputEnabled = true
    @AppStorage("coral.notifications.done") private var doneEnabled = true

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
        .frame(width: 450, height: 420)
    }
}
