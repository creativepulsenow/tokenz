import XCTest

final class UsageMergeTests: XCTestCase {
    private typealias Window = UsageMerge.Window
    private typealias Reading = UsageMerge.Reading

    private let now: Double = 1_000_000
    private var thisWindow: Double { now + 2 * 3600 }
    private var nextWindow: Double { now + 7 * 3600 }
    private var week: Double { now + 5 * 86_400 }

    private func reading(_ five: Double?, reset: Double? = nil, week sevenDay: Double? = 5) -> Reading {
        Reading(fiveHour: five.map { Window(percent: $0, resetsAt: reset ?? thisWindow) },
                sevenDay: sevenDay.map { Window(percent: $0, resetsAt: week) },
                model: "Opus")
    }

    private func merge(_ stored: Reading?, _ incoming: Reading, _ freshness: UsageMerge.Freshness) -> UsageMerge.Outcome {
        UsageMerge.merge(stored: stored, incoming: incoming, freshness: freshness, now: now)
    }

    func testFirstReadingIsWritten() {
        let outcome = merge(nil, reading(27), .unknown)
        XCTAssertTrue(outcome.shouldWrite)
        XCTAssertEqual(outcome.current.fiveHour?.percent, 27)
    }

    func testNothingStoredAndNoLimitsStillWrites() {
        // So the app can show "connected, but no limits reported".
        let outcome = merge(nil, Reading(fiveHour: nil, sevenDay: nil, model: "Opus"), .unknown)
        XCTAssertTrue(outcome.shouldWrite)
        XCTAssertNil(outcome.current.fiveHour)
    }

    func testStaleRunNeverWrites() {
        for incoming in [reading(20), reading(99), reading(nil, week: nil)] {
            let outcome = merge(reading(56), incoming, .stale)
            XCTAssertFalse(outcome.shouldWrite)
            XCTAssertEqual(outcome.current.fiveHour?.percent, 56)
        }
    }

    func testUnknownRunCannotTakeUsageBackward() {
        XCTAssertFalse(merge(reading(56), reading(20), .unknown).shouldWrite)
        // An earlier window than the one stored.
        XCTAssertFalse(merge(reading(3, reset: nextWindow), reading(99), .unknown).shouldWrite)
        // Lower weekly alone is enough to reject it.
        XCTAssertFalse(merge(reading(56, week: 8), reading(60, week: 4), .unknown).shouldWrite)
    }

    func testUnknownRunMayMoveUsageForward() {
        let outcome = merge(reading(56), reading(61), .unknown)
        XCTAssertTrue(outcome.shouldWrite)
        XCTAssertEqual(outcome.current.fiveHour?.percent, 61)
    }

    func testFreshRunIsTrustedEvenWhenLower() {
        let outcome = merge(reading(56), reading(40), .fresh)
        XCTAssertTrue(outcome.shouldWrite)
        XCTAssertEqual(outcome.current.fiveHour?.percent, 40)
    }

    func testFreshRunStartsANewWindow() {
        let outcome = merge(reading(96), reading(3, reset: nextWindow), .fresh)
        XCTAssertEqual(outcome.current.fiveHour, Window(percent: 3, resetsAt: nextWindow))
    }

    func testRunWithoutLimitsNeverRewritesAnExistingFile() {
        let none = Reading(fiveHour: nil, sevenDay: nil, model: "Sonnet")
        XCTAssertFalse(merge(reading(40), none, .fresh).shouldWrite)
        // Also when everything stored has expired: no flash of "no limits".
        let expired = reading(96, reset: now - 600, week: nil)
        XCTAssertFalse(merge(expired, none, .fresh).shouldWrite)
        XCTAssertFalse(merge(expired, none, .unknown).shouldWrite)
    }

    func testExpiredIncomingWindowIsIgnored() {
        // A first-seen idle session reporting a window that has already ended.
        let expiredStored = reading(96, reset: now - 600, week: nil)
        let expiredIncoming = reading(96, reset: now - 600, week: nil)
        XCTAssertFalse(merge(expiredStored, expiredIncoming, .unknown).shouldWrite)
    }

    func testMissingWindowKeepsTheStoredOne() {
        let outcome = merge(reading(40), reading(nil, week: 9), .fresh)
        XCTAssertTrue(outcome.shouldWrite)
        XCTAssertEqual(outcome.current.fiveHour?.percent, 40)
        XCTAssertEqual(outcome.current.sevenDay?.percent, 9)
    }

    func testFarFutureResetCannotPinTheDisplay() {
        let junk = Reading(fiveHour: Window(percent: 100, resetsAt: now + 10 * 365 * 86_400), sevenDay: nil, model: nil)
        // Stored junk doesn't block a real reading...
        let outcome = merge(junk, reading(12), .unknown)
        XCTAssertTrue(outcome.shouldWrite)
        XCTAssertEqual(outcome.current.fiveHour?.percent, 12)
        // ...and incoming junk is not stored.
        XCTAssertNil(merge(nil, junk, .fresh).current.fiveHour)
    }

    func testExtraLimitsAreStoredAndReplacedByName() {
        var first = reading(40)
        first.extra = [.init(name: "Fable (weekly)", window: Window(percent: 8, resetsAt: week)),
                       .init(name: "Opus (weekly)", window: Window(percent: 30, resetsAt: week))]
        let stored = merge(nil, first, .unknown).current
        XCTAssertEqual(stored.extra.map(\.name), ["Fable (weekly)", "Opus (weekly)"])

        // A later run that only mentions one keeps the other.
        var second = reading(41)
        second.extra = [.init(name: "Fable (weekly)", window: Window(percent: 9, resetsAt: week))]
        let merged = merge(stored, second, .fresh).current
        XCTAssertEqual(merged.extra.first { $0.name == "Fable (weekly)" }?.window.percent, 9)
        XCTAssertEqual(merged.extra.first { $0.name == "Opus (weekly)" }?.window.percent, 30)
    }

    func testExpiredExtraLimitsAreDropped() {
        var incoming = reading(40)
        incoming.extra = [.init(name: "Old", window: Window(percent: 50, resetsAt: now - 60)),
                          .init(name: "Junk", window: Window(percent: 50, resetsAt: now + 400 * 86_400))]
        XCTAssertTrue(merge(nil, incoming, .fresh).current.extra.isEmpty)

        var stored = reading(40)
        stored.extra = [.init(name: "Old", window: Window(percent: 50, resetsAt: now - 60))]
        XCTAssertTrue(merge(stored, reading(41), .fresh).current.extra.isEmpty)
    }

    func testStaleRunCannotChangeExtraLimits() {
        var stored = reading(40)
        stored.extra = [.init(name: "Fable (weekly)", window: Window(percent: 9, resetsAt: week))]
        var incoming = reading(40)
        incoming.extra = [.init(name: "Fable (weekly)", window: Window(percent: 2, resetsAt: week))]
        let outcome = merge(stored, incoming, .stale)
        XCTAssertFalse(outcome.shouldWrite)
        XCTAssertEqual(outcome.current.extra.first?.window.percent, 9)
    }

    func testUnknownRunCannotTakeAnExtraLimitBackward() {
        var stored = reading(40)
        stored.extra = [.init(name: "Fable", window: Window(percent: 80, resetsAt: week))]
        var incoming = reading(41)
        incoming.extra = [.init(name: "Fable", window: Window(percent: 3, resetsAt: week)),
                          .init(name: "Opus (weekly)", window: Window(percent: 10, resetsAt: week))]
        let extra = merge(stored, incoming, .unknown).current.extra
        XCTAssertEqual(extra.first { $0.name == "Fable" }?.window.percent, 80)
        // A limit it has no history for is still accepted.
        XCTAssertEqual(extra.first { $0.name == "Opus (weekly)" }?.window.percent, 10)
    }

    func testExtraLimitWithoutAResetTimeIsNeverStored() {
        var incoming = reading(40)
        incoming.extra = [.init(name: "Ghost", window: Window(percent: 99, resetsAt: nil))]
        XCTAssertTrue(merge(nil, incoming, .fresh).current.extra.isEmpty)
    }

    func testExtraLimitsAreCappedAndOnePerName() {
        var incoming = reading(40)
        incoming.extra = (0..<20).map { .init(name: "Limit \($0)", window: Window(percent: 1, resetsAt: week)) }
            + [.init(name: "Limit 0", window: Window(percent: 77, resetsAt: week))]
        var stored = reading(40)
        stored.extra = (20..<30).map { .init(name: "Limit \($0)", window: Window(percent: 1, resetsAt: week)) }
        let extra = merge(stored, incoming, .fresh).current.extra
        XCTAssertEqual(extra.count, UsageMerge.maxExtraWindows)
        XCTAssertEqual(Set(extra.map(\.name)).count, extra.count)
        XCTAssertEqual(extra.first?.window.percent, 1)   // the first "Limit 0" wins
    }

    func testModelFallsBackToStored() {
        var incoming = reading(60)
        incoming.model = nil
        XCTAssertEqual(merge(reading(56), incoming, .fresh).current.model, "Opus")
    }
}
