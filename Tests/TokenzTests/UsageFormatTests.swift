import XCTest

final class UsageFormatTests: XCTestCase {
    func testRoundsDownAndClamps() {
        XCTAssertEqual(UsageFormat.percent(0), "0%")
        XCTAssertEqual(UsageFormat.percent(94.6), "94%")
        XCTAssertEqual(UsageFormat.percent(99.99), "99%")
        XCTAssertEqual(UsageFormat.percent(100), "100%")
        XCTAssertEqual(UsageFormat.percent(1e19), "100%")
        XCTAssertEqual(UsageFormat.percent(-5), "0%")
        XCTAssertEqual(UsageFormat.percent(.nan), "—%")
    }
}
