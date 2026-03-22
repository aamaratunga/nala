import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(SessionStore.self) private var store

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
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 150)
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
