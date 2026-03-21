import Foundation

struct LaunchRequest: Encodable {
    let workingDir: String
    var agentType: String = "claude"
    var displayName: String?
    var flags: [String] = []
    var prompt: String?

    enum CodingKeys: String, CodingKey {
        case workingDir = "working_dir"
        case agentType = "agent_type"
        case displayName = "display_name"
        case flags
        case prompt
    }
}

struct LaunchResponse: Decodable {
    let sessionId: String
    let sessionName: String
    let workingDir: String
    let agentType: String
    var logFile: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sessionName = "session_name"
        case workingDir = "working_dir"
        case agentType = "agent_type"
        case logFile = "log_file"
    }
}
