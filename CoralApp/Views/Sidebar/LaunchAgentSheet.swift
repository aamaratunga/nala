import SwiftUI

struct LaunchAgentSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var workingDir = ""
    @State private var agentType = "claude"
    @State private var prompt = ""
    @State private var displayName = ""
    @State private var isLaunching = false
    @State private var errorMessage: String?
    @State private var directoryEntries: [String] = []
    @State private var currentBrowsePath = "~"

    private let agentTypes = ["claude", "gemini"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Launch Agent")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                Section("Configuration") {
                    HStack {
                        TextField("Working Directory", text: $workingDir, prompt: Text("/path/to/project"))
                            .textFieldStyle(.roundedBorder)

                        Button("Browse…") {
                            browseDirectory()
                        }
                    }

                    Picker("Agent Type", selection: $agentType) {
                        ForEach(agentTypes, id: \.self) { type in
                            Text(type.capitalized).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Display Name (optional)", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Prompt (optional)") {
                    TextEditor(text: $prompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80, maxHeight: 200)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary)
                        )
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Launch") {
                    launchAgent()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(workingDir.trimmingCharacters(in: .whitespaces).isEmpty || isLaunching)
            }
            .padding()
        }
        .frame(width: 480, height: 440)
        .onAppear {
            // Default to home directory
            workingDir = FileManager.default.homeDirectoryForCurrentUser.path
        }
    }

    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the project working directory"

        if panel.runModal() == .OK, let url = panel.url {
            workingDir = url.path
        }
    }

    private func launchAgent() {
        let dir = workingDir.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { return }

        isLaunching = true
        errorMessage = nil

        var request = LaunchRequest(workingDir: dir, agentType: agentType)
        if !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            request.displayName = displayName.trimmingCharacters(in: .whitespaces)
        }
        if !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            request.prompt = prompt.trimmingCharacters(in: .whitespaces)
        }

        Task {
            do {
                _ = try await store.apiClient.launchAgent(request)
                dismiss()
            } catch let error as APIError {
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
            isLaunching = false
        }
    }
}
