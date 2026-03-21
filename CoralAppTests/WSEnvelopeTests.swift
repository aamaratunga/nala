import XCTest
@testable import Coral

final class WSEnvelopeTests: XCTestCase {

    // MARK: - coral_update

    func testDecodeCoralUpdate() throws {
        let json = """
        {
            "type": "coral_update",
            "sessions": [
                {"name": "agent-1", "session_id": "s1", "working_directory": "/tmp"},
                {"name": "agent-2", "session_id": "s2", "working_directory": "/tmp"}
            ]
        }
        """
        let envelope = try coralJSONDecoder.decode(WSEnvelope.self, from: Data(json.utf8))

        XCTAssertEqual(envelope.type, "coral_update")
        XCTAssertEqual(envelope.sessions?.count, 2)
        XCTAssertEqual(envelope.sessions?[0].sessionId, "s1")
        XCTAssertEqual(envelope.sessions?[1].sessionId, "s2")
        XCTAssertNil(envelope.changed)
        XCTAssertNil(envelope.removed)
    }

    // MARK: - coral_diff

    func testDecodeCoralDiff() throws {
        let json = """
        {
            "type": "coral_diff",
            "changed": [
                {"name": "agent-1", "session_id": "s1", "status": "Working", "working_directory": "/tmp"}
            ],
            "removed": ["s2", "old-term"]
        }
        """
        let envelope = try coralJSONDecoder.decode(WSEnvelope.self, from: Data(json.utf8))

        XCTAssertEqual(envelope.type, "coral_diff")
        XCTAssertEqual(envelope.changed?.count, 1)
        XCTAssertEqual(envelope.changed?[0].status, "Working")
        XCTAssertEqual(envelope.removed, ["s2", "old-term"])
        XCTAssertNil(envelope.sessions)
    }

    // MARK: - Non-conforming floats

    func testDecoderHandlesInfinity() throws {
        let json = """
        {
            "type": "coral_update",
            "sessions": [
                {"name": "agent-1", "staleness_seconds": "Infinity"}
            ]
        }
        """
        let envelope = try coralJSONDecoder.decode(WSEnvelope.self, from: Data(json.utf8))
        let staleness = envelope.sessions?[0].stalenessSeconds

        XCTAssertNotNil(staleness)
        XCTAssertTrue(staleness!.isInfinite)
    }

    func testDecoderHandlesNaN() throws {
        let json = """
        {
            "type": "coral_update",
            "sessions": [
                {"name": "agent-1", "staleness_seconds": "NaN"}
            ]
        }
        """
        let envelope = try coralJSONDecoder.decode(WSEnvelope.self, from: Data(json.utf8))
        let staleness = envelope.sessions?[0].stalenessSeconds

        XCTAssertNotNil(staleness)
        XCTAssertTrue(staleness!.isNaN)
    }

    func testDecoderHandlesNegativeInfinity() throws {
        let json = """
        {
            "type": "coral_update",
            "sessions": [
                {"name": "agent-1", "staleness_seconds": "-Infinity"}
            ]
        }
        """
        let envelope = try coralJSONDecoder.decode(WSEnvelope.self, from: Data(json.utf8))
        let staleness = envelope.sessions?[0].stalenessSeconds

        XCTAssertNotNil(staleness)
        XCTAssertTrue(staleness!.isInfinite)
        XCTAssertTrue(staleness! < 0)
    }

    // MARK: - Empty diff

    func testDecodeEmptyDiff() throws {
        let json = """
        {"type": "coral_diff", "changed": [], "removed": []}
        """
        let envelope = try coralJSONDecoder.decode(WSEnvelope.self, from: Data(json.utf8))

        XCTAssertEqual(envelope.type, "coral_diff")
        XCTAssertEqual(envelope.changed?.count, 0)
        XCTAssertEqual(envelope.removed?.count, 0)
    }
}
