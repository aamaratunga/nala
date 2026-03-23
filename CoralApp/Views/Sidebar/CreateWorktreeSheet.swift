import SwiftUI
import os

struct CreateWorktreeDropdown: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    private let logger = Logger(subsystem: "com.coral.app", category: "CreateWorktree")

    @FocusState private var focusedField: Field?
    @State private var selectedConfig: RepoConfig?
    @State private var branchName = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private enum Field: Hashable {
        case repoList
        case branchName
    }

    private var isValid: Bool {
        !branchName.isEmpty && !branchName.contains(" ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let config = selectedConfig {
                branchInputView(config: config)
            } else {
                repoListView()
            }
        }
        .padding(.vertical, 8)
        .frame(width: 300)
        .focusable()
        .focusEffectDisabled()
        .focused($focusedField, equals: .repoList)
        .onAppear { focusedField = .repoList }
        .onKeyPress(characters: .decimalDigits) { press in
            // Only handle number keys on the repo list screen
            guard selectedConfig == nil else { return .ignored }
            guard let digit = Int(press.characters) else { return .ignored }
            let number = digit == 0 ? 10 : digit
            let configs = store.validRepoConfigs
            if number == configs.count + 1 {
                // "Add Repository…" item
                dismiss()
                store.repoConfigs.append(RepoConfig())
                openSettings()
                return .handled
            }
            guard number >= 1, number <= configs.count else { return .ignored }
            selectedConfig = configs[number - 1]
            focusedField = .branchName
            return .handled
        }
    }

    // MARK: - Repo List

    @ViewBuilder
    private func repoListView() -> some View {
        Label("New Worktree", systemImage: "arrow.triangle.branch")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

        let configs = store.validRepoConfigs
        ForEach(Array(configs.enumerated()), id: \.element.id) { index, config in
            Button {
                selectedConfig = config
                focusedField = .branchName
            } label: {
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, alignment: .trailing)

                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)

                    Text(config.displayName)
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

        Divider()
            .padding(.vertical, 4)

        Button {
            dismiss()
            store.repoConfigs.append(RepoConfig())
            openSettings()
        } label: {
            HStack(spacing: 8) {
                Text("\(configs.count + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .trailing)

                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)

                Text("Add Repository…")
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Branch Input

    @ViewBuilder
    private func branchInputView(config: RepoConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedConfig = nil
                        branchName = ""
                        errorMessage = nil
                        focusedField = .repoList
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Label(config.displayName, systemImage: "folder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            HStack(spacing: 8) {
                TextField("Branch name", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .branchName)
                    .onSubmit {
                        if isValid && !isCreating {
                            Task { await createWorktree(config: config) }
                        }
                    }

                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Create") {
                        Task { await createWorktree(config: config) }
                    }
                    .disabled(!isValid)
                }
            }
            .padding(.horizontal, 12)

            if !branchName.isEmpty && branchName.contains(" ") {
                Text("Branch name cannot contain spaces")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Actions

    private func dismiss() {
        store.showingCreateWorktreeSheet = false
    }

    private func createWorktree(config: RepoConfig) async {
        logger.info("Starting worktree creation: repo=\(config.repoPath) worktreeFolder=\(config.worktreeFolderPath) branch=\(branchName)")
        isCreating = true
        errorMessage = nil

        let result = await GitService.createWorktree(
            repoPath: config.repoPath,
            worktreeFolder: config.worktreeFolderPath,
            branchName: branchName
        )

        guard result.succeeded else {
            logger.error("Worktree creation failed: \(result.errorMessage)")
            errorMessage = result.errorMessage
            isCreating = false
            return
        }

        let worktreePath = (config.worktreeFolderPath as NSString).appendingPathComponent(branchName)
        logger.info("Worktree created at \(worktreePath)")

        if let script = config.postCreateScript, !script.isEmpty {
            logger.info("Running post-create script: \(script)")
            let scriptResult = await GitService.runScript(
                scriptPath: script,
                worktreePath: worktreePath,
                branchName: branchName,
                repoPath: config.repoPath
            )
            if !scriptResult.succeeded {
                logger.error("Post-create script failed: \(scriptResult.errorMessage)")
                errorMessage = "Worktree created but post-create script failed: \(scriptResult.errorMessage)"
            }
        }

        logger.info("Triggering folder rescan and launching Claude agent in \(worktreePath)")
        store.scanWorktreeFolders()
        store.launchSession(agentType: "claude", in: worktreePath)

        isCreating = false
        dismiss()
    }
}
