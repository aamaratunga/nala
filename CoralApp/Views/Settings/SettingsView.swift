import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage("coral.notifications.needsInput") private var needsInputEnabled = true
    @AppStorage("coral.notifications.done") private var doneEnabled = true

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Parent Folder")
                            .fontWeight(.medium)
                        Text(store.parentFolderPath ?? "None selected")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if store.parentFolderPath != nil {
                        Button("Clear") {
                            store.parentFolderPath = nil
                        }
                    }

                    Button("Choose…") {
                        chooseFolder()
                    }
                }
            } footer: {
                Text("All top-level subfolders of the selected directory will appear in the sidebar, even without active sessions.")
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
        .frame(width: 450, height: 260)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a parent directory whose subfolders should appear in the sidebar."

        if panel.runModal() == .OK, let url = panel.url {
            store.parentFolderPath = url.path
        }
    }
}
