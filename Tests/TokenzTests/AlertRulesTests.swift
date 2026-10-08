import XCTest

final class AlertRulesTests: XCTestCase {
    private let now: Double = 1_000_000
    private var reset: Double { now + 2 * 3600 }

    private func evaluate(_ state: AlertRules.State?, _ percent: Double, reset: Double? = nil, at time: Double? = nil)
        -> (state: AlertRules.State?, fire: Int?) {
        AlertRules.evaluate(state: state, percent: percent, resetsAt: reset ?? self.reset, now: time ?? now)
    }

    func testBelowTheFirstThresholdNothingFires() {
        XCTAssertNil(evaluate(nil, 69.9).fire)
    }

    func testEachThresholdFiresOnce() {
        var (state, fire) = evaluate(nil, 71)
        XCTAssertEqual(fire, 70)
        (state, fire) = evaluate(state, 72)
        XCTAssertNil(fire)
        (state, fire) = evaluate(state, 86)
        XCTAssertEqual(fire, 85)
        (state, fire) = evaluate(state, 99)
        XCTAssertEqual(fire, 95)
        XCTAssertNil(evaluate(state, 100).fire)
    }

    func testFirstLaunchAtHighUsageFiresOnlyTheHighest() {
        let (state, fire) = evaluate(nil, 96)
        XCTAssertEqual(fire, 95)
        XCTAssertEqual(state?.firedThresholds, [70, 85, 95])
    }

    func testANewWindowFiresAgain() {
        let (state, _) = evaluate(nil, 96)
        let later = now + 5 * 3600
        XCTAssertEqual(evaluate(state, 75, reset: later + 5 * 3600, at: later).fire, 70)
    }

    func testAWindowThatAlreadyEndedIsIgnored() {
        // Launching against yesterday's file must not alert.
        let result = evaluate(nil, 96, reset: now - 3600)
        XCTAssertNil(result.fire)
        XCTAssertNil(result.state)
    }

    func testAnImplausibleResetTimeIsIgnored() {
        XCTAssertNil(evaluate(nil, 96, reset: now + 30 * 86_400).fire)
    }

    func testMovingTheResetTimeCannotReplayAlerts() {
        var (state, fire) = evaluate(nil, 96)
        XCTAssertEqual(fire, 95)
        var fired = 0
        for step in 1...50 {
            (state, fire) = evaluate(state, 96, reset: reset + Double(step) * 301, at: now + Double(step))
            if fire != nil { fired += 1 }
        }
        XCTAssertEqual(fired, 0)
    }

    func testJunkSavedByAnOlderVersionIsDiscardedOnce() {
        let junk = AlertRules.State(resetsAt: now + 200 * 86_400, firedThresholds: [70, 85, 95], windowSeenAt: nil)
        let (state, fire) = evaluate(junk, 96)
        XCTAssertEqual(fire, 95)
        XCTAssertNil(evaluate(state, 96).fire)
    }
}
