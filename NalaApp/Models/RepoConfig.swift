import Foundation

struct RepoConfig: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var repoPath: String = ""
    var worktreeFolderPath: String = ""
    var postCreateScript: String?
    var preDeleteScript: String?

    var displayName: String {
        guard !repoPath.isEmpty else { return "New Repository" }
        return URL(fileURLWithPath: repoPath).lastPathComponent
    }
}
