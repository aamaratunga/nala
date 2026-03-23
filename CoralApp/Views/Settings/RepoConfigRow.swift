import SwiftUI
import AppKit

struct RepoConfigRow: View {
    @Binding var config: RepoConfig
    var onDelete: () -> Void

    @State private var isExpanded = false

    private var isComplete: Bool {
        !config.repoPath.isEmpty && !config.worktreeFolderPath.isEmpty
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                pathField(
                    label: "Repo Path",
                    value: $config.repoPath,
                    prompt: "Select the git repository root",
                    isDirectory: true
                )

                pathField(
                    label: "Worktree Folder",
                    value: $config.worktreeFolderPath,
                    prompt: "Select where worktrees are created",
                    isDirectory: true
                )

                optionalPathField(
                    label: "Post-Create Script",
                    value: Binding(
                        get: { config.postCreateScript ?? "" },
                        set: { config.postCreateScript = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: "Select script to run after worktree creation",
                    isDirectory: false
                )

                optionalPathField(
                    label: "Pre-Delete Script",
                    value: Binding(
                        get: { config.preDeleteScript ?? "" },
                        set: { config.preDeleteScript = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: "Select script to run before worktree deletion",
                    isDirectory: false
                )

                HStack {
                    Spacer()
                    Button("Remove Repository", role: .destructive) {
                        onDelete()
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(isComplete ? .green : .orange)
                    .font(.caption)

                Text(config.displayName)
                    .fontWeight(.medium)
            }
        }
        .onAppear {
            // Auto-expand new/incomplete entries
            if !isComplete { isExpanded = true }
        }
    }

    @ViewBuilder
    private func pathField(
        label: String,
        value: Binding<String>,
        prompt: String,
        isDirectory: Bool
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.wrappedValue.isEmpty ? "Not set" : value.wrappedValue)
                    .font(.caption)
                    .foregroundStyle(value.wrappedValue.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Browse…") {
                choosePath(isDirectory: isDirectory, message: prompt) { path in
                    value.wrappedValue = path
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func optionalPathField(
        label: String,
        value: Binding<String>,
        prompt: String,
        isDirectory: Bool
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.wrappedValue.isEmpty ? "None" : value.wrappedValue)
                    .font(.caption)
                    .foregroundStyle(value.wrappedValue.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !value.wrappedValue.isEmpty {
                Button("Clear") {
                    value.wrappedValue = ""
                }
                .controlSize(.small)
            }

            Button("Browse…") {
                choosePath(isDirectory: isDirectory, message: prompt) { path in
                    value.wrappedValue = path
                }
            }
            .controlSize(.small)
        }
    }

    private func choosePath(isDirectory: Bool, message: String, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = isDirectory
        panel.canChooseFiles = !isDirectory
        panel.canCreateDirectories = isDirectory
        panel.allowsMultipleSelection = false
        panel.message = message

        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }
}
