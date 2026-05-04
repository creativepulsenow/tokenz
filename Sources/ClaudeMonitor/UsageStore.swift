import Foundation
import Combine

/// Central data model. Holds current usage state, publishes changes to SwiftUI views.
@MainActor
final class UsageStore: ObservableObject {
    @Published var fiveHourPercent: Double? = nil
    @Published var fiveHourResetsAt: Date? = nil
    @Published var sevenDayPercent: Double? = nil
    @Published var sevenDayResetsAt: Date? = nil
    @Published var modelName: String? = nil
    @Published var lastUpdated: Date? = nil
    @Published var isStale: Bool = true  // true when no update in 5+ minutes

    private var staleTimer: Timer?

    func update(from data: UsageFileData) {
        if let fh = data.fiveHour {
            fiveHourPercent = fh.usedPercentage
            fiveHourResetsAt = fh.resetsAt.map { Date(timeIntervalSince1970: $0) }
        }
        if let sd = data.sevenDay {
            sevenDayPercent = sd.usedPercentage
            sevenDayResetsAt = sd.resetsAt.map { Date(timeIntervalSince1970: $0) }
        }
        modelName = data.model
        lastUpdated = Date()
        isStale = false
        resetStaleTimer()
    }

    private func resetStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isStale = true }
        }
    }

    /// Compact text for the menu bar label
    var menuBarText: String {
        guard let pct = fiveHourPercent else { return "-- %" }
        return "\(Int(pct))%"
    }

    /// SF Symbol name for the menu bar icon color
    var menuBarIcon: String {
        guard let pct = fiveHourPercent else { return "circle" }
        if pct >= 85 { return "circle.fill" }      // will be colored red
        if pct >= 60 { return "circle.fill" }      // will be colored yellow/orange
        return "circle.fill"                        // will be colored green
    }

    /// Color indicator for the current usage level
    var usageLevel: UsageLevel {
        guard let pct = fiveHourPercent else { return .unknown }
        if pct >= 85 { return .critical }
        if pct >= 60 { return .warning }
        return .normal
    }

    enum UsageLevel {
        case normal, warning, critical, unknown
    }
}
