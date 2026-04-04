import XCTest
@testable import Coral

final class PulseParserTests: XCTestCase {

    // MARK: - ANSI Stripping

    func testStripSimpleCSI() {
        let input = "Hello \u{1B}[32mWorld\u{1B}[0m!"
        let result = PulseParser.stripANSI(input)
        XCTAssertEqual(result, "Hello  World !")
    }

    func testStripOSCSequence() {
        let input = "Start\u{1B}]0;title\u{07}End"
        let result = PulseParser.stripANSI(input)
        XCTAssertEqual(result, "Start End")
    }

    func testStripFeSequence() {
        let input = "Before\u{1B}MAfter"
        let result = PulseParser.stripANSI(input)
        XCTAssertEqual(result, "Before After")
    }

    func testStripControlCharacters() {
        let input = "Hello\u{00}\u{07}\u{0E}World"
        let result = PulseParser.stripANSI(input)
        XCTAssertEqual(result, "HelloWorld")
    }

    func testStripComplexMixedSequences() {
        let input = "\u{1B}[1;34m||PULSE:STATUS Working on tests||\u{1B}[0m"
        let result = PulseParser.stripANSI(input)
        XCTAssertTrue(result.contains("||PULSE:STATUS Working on tests||"))
    }

    func testStripPreservesPlainText() {
        let input = "No escape sequences here"
        let result = PulseParser.stripANSI(input)
        XCTAssertEqual(result, "No escape sequences here")
    }

    func testStripEmptyString() {
        XCTAssertEqual(PulseParser.stripANSI(""), "")
    }

    // MARK: - PULSE Parsing

    func testParseStatusEvent() {
        let text = "some output ||PULSE:STATUS Implementing feature X|| more output"
        let result = PulseParser.parsePulseEvents(from: text)

        XCTAssertEqual(result.status, "Implementing feature X")
        XCTAssertNil(result.summary)
        XCTAssertNil(result.confidence)
    }

    func testParseSummaryEvent() {
        let text = "||PULSE:SUMMARY Adding unit test coverage||"
        let result = PulseParser.parsePulseEvents(from: text)

        XCTAssertEqual(result.summary, "Adding unit test coverage")
    }

    func testParseConfidenceEvent() {
        let text = "||PULSE:CONFIDENCE High clear understanding of codebase||"
        let result = PulseParser.parsePulseEvents(from: text)

        XCTAssertEqual(result.confidence, "High clear understanding of codebase")
    }

    func testParseMultipleEvents() {
        let text = """
        ||PULSE:STATUS First||
        ||PULSE:SUMMARY Goal description||
        ||PULSE:STATUS Second||
        """
        let result = PulseParser.parsePulseEvents(from: text)

        XCTAssertEqual(result.status, "Second", "Should return the last status")
        XCTAssertEqual(result.summary, "Goal description")
    }

    func testParseNoEvents() {
        let text = "Just regular terminal output with no pulse events"
        let result = PulseParser.parsePulseEvents(from: text)

        XCTAssertNil(result.status)
        XCTAssertNil(result.summary)
        XCTAssertNil(result.confidence)
    }

    func testParseWithANSIWrappedPulse() {
        // Simulate real terminal output with ANSI codes around PULSE events
        let text = PulseParser.stripANSI("\u{1B}[1m||PULSE:STATUS Reading files||\u{1B}[0m")
        let result = PulseParser.parsePulseEvents(from: text)

        XCTAssertEqual(result.status, "Reading files")
    }

    // MARK: - Clean Match

    func testCleanMatchCollapsesWhitespace() {
        let result = PulseParser.cleanMatch("  Hello   World  ")
        XCTAssertEqual(result, "Hello World")
    }

    func testCleanMatchSkipsTemplatePlaceholders() {
        let result = PulseParser.cleanMatch("<your current goal>")
        XCTAssertEqual(result, "", "Template text with angle brackets should be skipped")
    }

    func testCleanMatchAllowsNormalText() {
        let result = PulseParser.cleanMatch("Implementing feature")
        XCTAssertEqual(result, "Implementing feature")
    }
}
