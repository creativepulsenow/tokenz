import XCTest

/// Names of extra limits come from outside the app and end up in the popover.
final class LimitNameTests: XCTestCase {
    func testOrdinaryNamesPassThrough() {
        XCTAssertEqual(LimitName.clean("Fable"), "Fable")
        XCTAssertEqual(LimitName.clean("  Opus (weekly) \n"), "Opus (weekly)")
    }

    func testControlAndReorderingCharactersAreRemoved() {
        XCTAssertEqual(LimitName.clean("Fa\u{202E}ble\u{0007}"), "Fable")
        XCTAssertEqual(LimitName.clean("A\u{2028}B"), "AB")
        XCTAssertEqual(LimitName.clean("A\nB"), "AB")
    }

    func testNamesWithNothingVisibleAreRejected() {
        for blank in ["", " ", "\t", "\u{3164}", " \u{3164} ", "\u{200B}", "---", "()"] {
            XCTAssertNil(LimitName.clean(blank), "\(Array(blank.unicodeScalars))")
        }
        XCTAssertNil(LimitName.clean(nil))
    }

    func testCannotImitateTheBuiltInRows() {
        XCTAssertNil(LimitName.clean(LimitName.fiveHour))
        XCTAssertNil(LimitName.clean(" weekly (7 DAY) "))
        XCTAssertNil(LimitName.clean("Current\u{202E} Session (5hr)"))
    }

    func testLengthIsCappedInScalars() {
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(LimitName.clean(long)?.unicodeScalars.count, LimitName.maxScalars)
        // One base letter with a thousand combining marks is still capped.
        let stacked = "e" + String(repeating: "\u{0301}", count: 1_000)
        XCTAssertEqual(LimitName.clean(stacked)?.unicodeScalars.count, LimitName.maxScalars)
    }

    func testACleanedNameIsStable() {
        // What is written to usage.json must read back as the same name, or
        // the next run would not recognize it and would store a duplicate.
        for raw in ["Fable", String(repeating: "x", count: 500), "  A  B  ", "Opus\u{202E} (weekly)"] {
            let once = LimitName.clean(raw)
            XCTAssertEqual(LimitName.clean(once), once)
        }
    }
}
