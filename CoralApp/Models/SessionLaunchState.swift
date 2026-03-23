import Foundation

@Observable
final class SessionLaunchState: Identifiable {
    let id: String
    let workingDirectory: String
    let agentType: String
    var isFinished = false
    var realSessionId: String?
    var error: String?

    init(workingDirectory: String, agentType: String) {
        self.id = "launching-\(UUID().uuidString)"
        self.workingDirectory = workingDirectory
        self.agentType = agentType
    }
}
