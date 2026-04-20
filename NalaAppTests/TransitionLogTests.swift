import XCTest
@testable import Nala

final class TransitionLogTests: XCTestCase {

    private func makeTransition(
        from: AgentStatus = .idle,
        to: AgentStatus = .working
    ) -> StateTransition {
        StateTransition(
            from: from,
            to: to,
            didChange: from != to,
            source: .eventWatcher,
            timestamp: Date()
        )
    }

    func testAppendAndRecent() {
        var log = TransitionLog(capacity: 10)
        let t1 = makeTransition(from: .idle, to: .working)
        let t2 = makeTransition(from: .working, to: .done)

        log.append(t1)
        log.append(t2)

        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log.recent.count, 2)
        XCTAssertEqual(log.recent[0].from, .idle)
        XCTAssertEqual(log.recent[1].from, .working)
    }

    func testCapacityCap() {
        var log = TransitionLog(capacity: 3)

        log.append(makeTransition(from: .idle, to: .working))
        log.append(makeTransition(from: .working, to: .done))
        log.append(makeTransition(from: .done, to: .idle))
        // At capacity (3) — next append should evict oldest
        log.append(makeTransition(from: .idle, to: .working))

        XCTAssertEqual(log.count, 3, "Log should not exceed capacity")
        // Oldest entry (idle→working) should be evicted; first entry is now working→done
        XCTAssertEqual(log.recent[0].from, .working)
        XCTAssertEqual(log.recent[0].to, .done)
    }

    func testRecentOrderingIsOldestFirst() {
        var log = TransitionLog(capacity: 50)

        for i in 0..<5 {
            let from: AgentStatus = i % 2 == 0 ? .idle : .working
            let to: AgentStatus = i % 2 == 0 ? .working : .idle
            log.append(makeTransition(from: from, to: to))
        }

        XCTAssertEqual(log.count, 5)
        // First entry should be the first appended
        XCTAssertEqual(log.recent.first?.from, .idle)
        XCTAssertEqual(log.recent.first?.to, .working)
    }

    func testEmptyLog() {
        let log = TransitionLog()
        XCTAssertEqual(log.count, 0)
        XCTAssertTrue(log.recent.isEmpty)
    }
}
