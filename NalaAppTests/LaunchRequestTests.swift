import XCTest
@testable import Nala

final class LaunchRequestTests: XCTestCase {

    // MARK: - LaunchRequest Encoding

    func testEncodesWithSnakeCaseKeys() throws {
        let request = LaunchRequest(workingDir: "/tmp/project")
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["working_dir"] as? String, "/tmp/project")
        XCTAssertEqual(dict["agent_type"] as? String, "claude")
        XCTAssertNotNil(dict["flags"])
        // Default optional fields should still be present as null
        XCTAssertNil(dict["working_dir_typo"])
    }

    func testEncodesAllFields() throws {
        var request = LaunchRequest(workingDir: "/tmp/proj")
        request.agentType = "gemini"
        request.displayName = "My Agent"
        request.flags = ["--verbose"]
        request.prompt = "Do the thing"

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["working_dir"] as? String, "/tmp/proj")
        XCTAssertEqual(dict["agent_type"] as? String, "gemini")
        XCTAssertEqual(dict["display_name"] as? String, "My Agent")
        XCTAssertEqual(dict["flags"] as? [String], ["--verbose"])
        XCTAssertEqual(dict["prompt"] as? String, "Do the thing")
    }

    func testDefaultValues() {
        let request = LaunchRequest(workingDir: "/tmp")
        XCTAssertEqual(request.agentType, "claude")
        XCTAssertNil(request.displayName)
        XCTAssertEqual(request.flags, [])
        XCTAssertNil(request.prompt)
    }

    // MARK: - LaunchResponse Decoding

    func testDecodesFullResponse() throws {
        let json = """
        {
            "session_id": "s-123",
            "session_name": "claude-agent-1",
            "working_dir": "/tmp/project",
            "agent_type": "claude",
            "log_file": "/tmp/log.txt"
        }
        """
        let response = try JSONDecoder().decode(LaunchResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.sessionId, "s-123")
        XCTAssertEqual(response.sessionName, "claude-agent-1")
        XCTAssertEqual(response.workingDir, "/tmp/project")
        XCTAssertEqual(response.agentType, "claude")
        XCTAssertEqual(response.logFile, "/tmp/log.txt")
    }

    func testDecodesResponseWithoutLogFile() throws {
        let json = """
        {
            "session_id": "s-456",
            "session_name": "gemini-agent-2",
            "working_dir": "/tmp/other",
            "agent_type": "gemini"
        }
        """
        let response = try JSONDecoder().decode(LaunchResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.sessionId, "s-456")
        XCTAssertNil(response.logFile)
    }
}
