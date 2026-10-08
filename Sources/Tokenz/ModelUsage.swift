import Foundation

/// How this week's Claude Code usage on this Mac splits across models.
///
/// Claude Code only reports account-wide totals, but every status line run
/// names the session's model and its running cost and API time. Attributing
/// each session's increase to the model it was using gives a breakdown. It is
/// an estimate: it can't see the web, mobile or other machines, and a session
/// that switches models is counted under whichever one it is on at the time.
struct ModelUsage: Codable, Equatable {
    struct Amount: Codable, Equatable {
        /// Claude Code's own cost estimate for the usage, in dollars.
        var cost: Double = 0
        /// Time spent waiting for API replies, in milliseconds.
        var time: Double = 0
    }

    /// The weekly window these totals belong to.
    var weekResetsAt: Double
    var models: [String: Amount] = [:]

    /// More models than this in one week means junk input, not real usage.
    static let maxModels = 16

    /// Adds one session's increase. Starts over when the weekly window has
    /// moved on (`weekResetsAt` is that window's reset time).
    mutating func add(model: String, cost: Double, time: Double, weekResetsAt week: Double) {
        if abs(week - weekResetsAt) >= UsageMerge.sameWindowTolerance {
            self = ModelUsage(weekResetsAt: week)
        }
        guard cost.isFinite, time.isFinite, cost >= 0, time >= 0, cost > 0 || time > 0 else { return }
        guard models[model] != nil || models.count < Self.maxModels else { return }
        models[model, default: Amount()].cost += cost
        models[model, default: Amount()].time += time
    }

    /// Each model's share of the week, largest first, as fractions that sum
    /// to 1. Uses cost when Claude Code reports one, API time otherwise.
    /// Empty when nothing has been recorded.
    func shares() -> [(model: String, share: Double)] {
        let totalCost = models.values.reduce(0) { $0 + $1.cost }
        let measure: (Amount) -> Double = totalCost > 0 ? { $0.cost } : { $0.time }
        let total = models.values.reduce(0) { $0 + measure($1) }
        guard total > 0 else { return [] }
        return models
            .map { (model: $0.key, share: measure($0.value) / total) }
            .filter { $0.share > 0 }
            .sorted { $0.share != $1.share ? $0.share > $1.share : $0.model < $1.model }
    }
}
