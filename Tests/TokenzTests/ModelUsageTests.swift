import XCTest

final class ModelUsageTests: XCTestCase {
    private let week: Double = 2_000_000

    func testSharesFollowCost() {
        var usage = ModelUsage(weekResetsAt: week)
        usage.add(model: "Fable 5.1", cost: 6, time: 1_000, weekResetsAt: week)
        usage.add(model: "Opus 5.5", cost: 3, time: 9_000, weekResetsAt: week)
        usage.add(model: "Fable 5.1", cost: 1, time: 0, weekResetsAt: week)

        let shares = usage.shares()
        XCTAssertEqual(shares.map(\.model), ["Fable 5.1", "Opus 5.5"])
        XCTAssertEqual(shares[0].share, 0.7, accuracy: 1e-9)
        XCTAssertEqual(shares[1].share, 0.3, accuracy: 1e-9)
    }

    func testFallsBackToAPITimeWhenNoCostIsReported() {
        var usage = ModelUsage(weekResetsAt: week)
        usage.add(model: "Fable 5.1", cost: 0, time: 1_000, weekResetsAt: week)
        usage.add(model: "Opus 5.5", cost: 0, time: 3_000, weekResetsAt: week)

        let shares = usage.shares()
        XCTAssertEqual(shares.map(\.model), ["Opus 5.5", "Fable 5.1"])
        XCTAssertEqual(shares[0].share, 0.75, accuracy: 1e-9)
    }

    func testANewWeekStartsOver() {
        var usage = ModelUsage(weekResetsAt: week)
        usage.add(model: "Fable 5.1", cost: 5, time: 5, weekResetsAt: week)
        usage.add(model: "Opus 5.5", cost: 1, time: 1, weekResetsAt: week + 7 * 86_400)

        XCTAssertEqual(usage.weekResetsAt, week + 7 * 86_400)
        XCTAssertEqual(usage.shares().map(\.model), ["Opus 5.5"])
    }

    func testSameWeekWithJitterIsNotANewWeek() {
        var usage = ModelUsage(weekResetsAt: week)
        usage.add(model: "Fable 5.1", cost: 5, time: 5, weekResetsAt: week)
        usage.add(model: "Fable 5.1", cost: 5, time: 5, weekResetsAt: week + 1)
        XCTAssertEqual(usage.models["Fable 5.1"]?.cost, 10)
    }

    func testJunkIsIgnored() {
        var usage = ModelUsage(weekResetsAt: week)
        usage.add(model: "A", cost: -1, time: 5, weekResetsAt: week)
        usage.add(model: "A", cost: .nan, time: 5, weekResetsAt: week)
        usage.add(model: "A", cost: .infinity, time: 5, weekResetsAt: week)
        usage.add(model: "A", cost: 0, time: 0, weekResetsAt: week)
        XCTAssertTrue(usage.models.isEmpty)
        XCTAssertTrue(usage.shares().isEmpty)
    }

    func testTheNumberOfModelsIsBounded() {
        var usage = ModelUsage(weekResetsAt: week)
        for i in 0..<100 { usage.add(model: "model-\(i)", cost: 1, time: 1, weekResetsAt: week) }
        XCTAssertEqual(usage.models.count, ModelUsage.maxModels)
        // A model already being tracked still accumulates.
        usage.add(model: "model-0", cost: 1, time: 1, weekResetsAt: week)
        XCTAssertEqual(usage.models["model-0"]?.cost, 2)
    }

    func testSurvivesARoundTripThroughJSON() throws {
        var usage = ModelUsage(weekResetsAt: week)
        usage.add(model: "Fable 5.1", cost: 1.5, time: 200, weekResetsAt: week)
        let decoded = try JSONDecoder().decode(ModelUsage.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(decoded, usage)
    }
}
