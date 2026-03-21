import Foundation
import os

/// REST API client for Coral server endpoints.
struct APIClient {
    let baseURL: URL
    private let logger = Logger(subsystem: "com.coral.app", category: "APIClient")

    init(port: Int = 8420) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    // MARK: - Sessions

    func fetchLiveSessions() async throws -> [Session] {
        let url = baseURL.appendingPathComponent("/api/sessions/live")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([Session].self, from: data)
    }

    func sendCommand(sessionName: String, command: String, agentType: String? = nil, sessionId: String? = nil) async throws {
        let encodedName = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        let url = baseURL.appendingPathComponent("/api/sessions/live/\(encodedName)/send")

        var body: [String: Any] = ["command": command]
        if let agentType { body["agent_type"] = agentType }
        if let sessionId { body["session_id"] = sessionId }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.requestFailed
        }
    }

    func launchAgent(_ req: LaunchRequest) async throws -> LaunchResponse {
        let url = baseURL.appendingPathComponent("/api/sessions/launch")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(req)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw APIError.serverError(errorBody.error)
            }
            throw APIError.requestFailed
        }
        return try JSONDecoder().decode(LaunchResponse.self, from: data)
    }

    func killSession(sessionName: String, agentType: String? = nil, sessionId: String? = nil) async throws {
        let encodedName = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        let url = baseURL.appendingPathComponent("/api/sessions/live/\(encodedName)/kill")

        var body: [String: Any] = [:]
        if let agentType { body["agent_type"] = agentType }
        if let sessionId { body["session_id"] = sessionId }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.requestFailed
        }
    }

    func restartSession(sessionName: String, agentType: String? = nil, sessionId: String? = nil) async throws {
        let encodedName = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        let url = baseURL.appendingPathComponent("/api/sessions/live/\(encodedName)/restart")

        var body: [String: Any] = [:]
        if let agentType { body["agent_type"] = agentType }
        if let sessionId { body["session_id"] = sessionId }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.requestFailed
        }
    }

    func acknowledgeSession(sessionName: String, sessionId: String? = nil) async throws {
        let encodedName = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/sessions/live/\(encodedName)/acknowledge"), resolvingAgainstBaseURL: false)!
        if let sessionId {
            components.queryItems = [URLQueryItem(name: "session_id", value: sessionId)]
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.requestFailed
        }
    }

    func sendKeys(sessionName: String, keys: [String], agentType: String? = nil, sessionId: String? = nil) async throws {
        let encodedName = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        let url = baseURL.appendingPathComponent("/api/sessions/live/\(encodedName)/keys")

        var body: [String: Any] = ["keys": keys]
        if let agentType { body["agent_type"] = agentType }
        if let sessionId { body["session_id"] = sessionId }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.requestFailed
        }
    }

    // MARK: - Filesystem

    func listDirectory(path: String = "~") async throws -> DirectoryListing {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/filesystem/list"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]

        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(DirectoryListing.self, from: data)
    }
}

// MARK: - Response Types

struct DirectoryListing: Decodable {
    let path: String
    let entries: [String]
}

struct ErrorResponse: Decodable {
    let error: String
}

enum APIError: LocalizedError {
    case requestFailed
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed: "Request failed"
        case .serverError(let msg): msg
        }
    }
}
