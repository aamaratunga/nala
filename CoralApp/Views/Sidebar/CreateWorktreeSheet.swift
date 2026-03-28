import SwiftUI
import os

struct CreateWorktreeDropdown: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    private let logger = Logger(subsystem: "com.coral.app", category: "CreateWorktree")

    @FocusState private var focusedField: Field?
    @State private var selectedConfig: RepoConfig?
    @State private var branchName = ""

    private enum Field: Hashable {
        case repoList
        case branchName
    }

    private var isValid: Bool {
        !branchName.isEmpty && validationError == nil
    }

    private var validationError: String? {
        if branchName.isEmpty { return nil }
        if branchName.contains(" ") { return "Cannot contain spaces" }
        if branchName.contains("..") { return "Cannot contain '..'" }
        if branchName.hasPrefix("/") || branchName.hasSuffix("/") { return "Cannot start or end with '/'" }
        if branchName.hasPrefix(".") || branchName.hasSuffix(".") { return "Cannot start or end with '.'" }
        if branchName.hasSuffix(".lock") { return "Cannot end with '.lock'" }
        let forbidden: [Character] = ["~", "^", ":", "?", "*", "[", "\\"]
        for char in forbidden {
            if branchName.contains(char) { return "Cannot contain '\(char)'" }
        }
        if branchName.contains("@{") { return "Cannot contain '@{'" }
        return nil
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
                        if isValid {
                            createWorktree(config: config)
                        }
                    }

                Button("Create") {
                    createWorktree(config: config)
                }
                .disabled(!isValid)
            }
            .padding(.horizontal, 12)

            if let error = validationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Actions

    private func dismiss() {
        store.showingCreateWorktreeSheet = false
    }

    private func createWorktree(config: RepoConfig) {
        logger.info("Starting async worktree creation: repo=\(config.repoPath) worktreeFolder=\(config.worktreeFolderPath) branch=\(branchName)")
        store.beginWorktreeCreation(config: config, branchName: branchName)
        dismiss()
    }
}
