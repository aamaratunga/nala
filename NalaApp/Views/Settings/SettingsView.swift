import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage("nala.terminalAppPath") private var terminalAppPath: String = ""
    @AppStorage("nala.notifications.needsInput") private var needsInputEnabled = true
    @AppStorage("nala.notifications.done") private var doneEnabled = true
    @State private var codexHookStatus: CodexHookBridge.InstallationStatus = .missing
    @State private var codexHookFeatureState: CodexHookBridge.FeatureState?
    @State private var isInstallingCodexHooks = false
    @State private var codexHookActionMessage: String?

    private let codexHookBridge = CodexHookBridge()

    private var terminalAppName: String? {
        guard !terminalAppPath.isEmpty else { return nil }
        return URL(fileURLWithPath: terminalAppPath).deletingPathExtension().lastPathComponent
    }

    private var codexHookStatusText: String {
        switch codexHookStatus {
        case .missing:
            return "Missing"
        case .repairNeeded:
            return "Repair needed"
        case .installed:
            return "Installed"
        case .failed:
            return "Failed"
        }
    }

    private var codexHookStatusDetail: String {
        switch codexHookStatus {
        case .missing:
            return "Lifecycle events will be unavailable until installed."
        case .repairNeeded:
            return "Nala hook entries are incomplete."
        case .installed:
            return "Nala hook entries are present."
        case .failed(let message):
            return message
        }
    }

    private var codexHookButtonTitle: String {
        switch codexHookStatus {
        case .missing:
            return "Install"
        case .repairNeeded:
            return "Repair"
        case .installed:
            return "Repair"
        case .failed:
            return "Retry"
        }
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

            Section {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(codexHookStatusText)
                            .foregroundStyle(codexHookStatus == .installed ? .primary : .secondary)
                        Text(codexHookStatusDetail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let codexHookActionMessage {
                            Text(codexHookActionMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let codexHookFeatureState {
                            Text(codexHookFeatureState.summary)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer()

                    Button(codexHookButtonTitle) {
                        installCodexHookBridge()
                    }
                    .disabled(isInstallingCodexHooks)
                }
            } header: {
                Text("Codex Hooks")
            } footer: {
                Text("Codex launches still work without this bridge; installing it enables Nala state updates for Nala-launched Codex sessions.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 590)
        .task {
            refreshCodexHookStatus()
            codexHookFeatureState = await codexHookBridge.detectFeatureState()
        }
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

    private func refreshCodexHookStatus() {
        codexHookStatus = codexHookBridge.installationStatus()
    }

    private func installCodexHookBridge() {
        isInstallingCodexHooks = true
        codexHookActionMessage = nil

        Task {
            let result = await Task.detached {
                Result { try codexHookBridge.installOrRepair() }
            }.value

            await MainActor.run {
                switch result {
                case .success(.installed):
                    codexHookActionMessage = "Installed hook bridge."
                    codexHookStatus = .installed
                case .success(.repaired):
                    codexHookActionMessage = "Repaired hook bridge."
                    codexHookStatus = .installed
                case .success(.alreadyInstalled):
                    codexHookActionMessage = "Hook bridge is already installed."
                    codexHookStatus = .installed
                case .failure(let error):
                    codexHookActionMessage = nil
                    codexHookStatus = .failed(error.localizedDescription)
                }

                isInstallingCodexHooks = false
            }
        }
    }
}
