import Foundation

@Observable
final class WorktreeDeletionState: Identifiable {
    let id: String
    let folderPath: String
    let folderLabel: String
    let sessionCount: Int
    let repoPath: String

    var shortFolderPath: String { Self.tildeShorten(folderPath) }
    var shortRepoPath: String { Self.tildeShorten(repoPath) }

    private static func tildeShorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    enum Step: String, CaseIterable, ProgressStep {
        case killingSessions = "Killing sessions"
        case runningPreDeleteScript = "Running pre-delete script"
        case removingWorktree = "Removing worktree"
        case deletingBranch = "Deleting branch"
    }

    var stepStatuses: [Step: StepStatus]
    var currentStep: Step?
    var error: String?
    var isFinished = false

    init(folderPath: String, sessionCount: Int, repoPath: String = "") {
        self.id = folderPath
        self.folderPath = folderPath
        self.folderLabel = URL(fileURLWithPath: folderPath).lastPathComponent
        self.sessionCount = sessionCount
        self.repoPath = repoPath
        self.stepStatuses = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, StepStatus.pending) })
    }

    func advance(to step: Step) {
        if let current = currentStep {
            stepStatuses[current] = .completed
        }
        currentStep = step
        stepStatuses[step] = .inProgress
    }

    func skipStep(_ step: Step) {
        stepStatuses[step] = .skipped
    }

    func completeCurrentStep() {
        if let current = currentStep {
            stepStatuses[current] = .completed
        }
    }

    func fail(at step: Step, message: String) {
        stepStatuses[step] = .failed(message)
        currentStep = nil
        error = message
    }
}
