import XCTest
@testable import Coral

final class BranchValidationTests: XCTestCase {

    func testEmptyStringReturnsNil() {
        XCTAssertNil(BranchValidation.validate(""))
    }

    func testValidBranchNameReturnsNil() {
        XCTAssertNil(BranchValidation.validate("feature/my-branch"))
        XCTAssertNil(BranchValidation.validate("fix-123"))
        XCTAssertNil(BranchValidation.validate("main"))
    }

    func testSpacesReturnError() {
        let result = BranchValidation.validate("my branch")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("space"))
    }

    func testDoubleDotsReturnError() {
        let result = BranchValidation.validate("my..branch")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains(".."))
    }

    func testLeadingTrailingSlashReturnError() {
        XCTAssertNotNil(BranchValidation.validate("/leading"))
        XCTAssertNotNil(BranchValidation.validate("trailing/"))
    }

    func testLeadingTrailingDotReturnError() {
        XCTAssertNotNil(BranchValidation.validate(".leading"))
        XCTAssertNotNil(BranchValidation.validate("trailing."))
    }

    func testDotLockSuffixReturnError() {
        let result = BranchValidation.validate("branch.lock")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains(".lock"))
    }

    func testForbiddenCharsReturnError() {
        let forbidden: [Character] = ["~", "^", ":", "?", "*", "[", "\\"]
        for char in forbidden {
            let name = "branch\(char)name"
            let result = BranchValidation.validate(name)
            XCTAssertNotNil(result, "Expected error for forbidden char '\(char)'")
        }
    }

    func testAtBraceReturnError() {
        let result = BranchValidation.validate("branch@{name}")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("@{"))
    }

    func testValidNamesWithSlashesPass() {
        // Slashes in the middle are fine in git branch names
        XCTAssertNil(BranchValidation.validate("feature/add-tests"))
        XCTAssertNil(BranchValidation.validate("user/feature/sub"))
    }
}
