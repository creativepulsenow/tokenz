import Foundation

/// The two limits the app alerts on.
enum UsageMetric: String, CaseIterable {
    // Raw values are the UserDefaults keys alert state is stored under.
    // Changing them would silently reset everyone's alert state.
    case fiveHour = "5-hour session"
    case sevenDay = "7-day weekly"

    /// How the limit is named in a notification.
    var title: String {
        switch self {
        case .fiveHour: return "5-hour session"
        case .sevenDay: return "Weekly"
        }
    }
}

/// When to alert. Pure: no clock, no storage, no notifications.
enum AlertRules {
    static let thresholds: [Int] = [70, 85, 95]

    /// No real window ends later than this from now (the longest is 7 days).
    static let horizon: TimeInterval = 8 * 24 * 3600
    /// A new window's reset time is hours past the old one. Anything closer
    /// than this is the same window reported with jitter.
    static let newWindowGap: TimeInterval = 300
    /// Real windows start at most every 5 hours. Refusing to start another
    /// one sooner keeps a writer that keeps moving `resets_at` from replaying
    /// the alerts.
    static let minimumWindowSpacing: TimeInterval = 3600

    /// What we remember per metric between updates.
    struct State: Codable, Equatable {
        var resetsAt: Double
        var firedThresholds: Set<Int>
        /// When this window was first seen. Absent in state saved by 1.4.2 and earlier.
        var windowSeenAt: Double?
    }

    /// Returns the state to save and, if one is due, the threshold to alert on.
    /// A reading for a window that has already ended, or whose reset time is
    /// implausibly far out, changes nothing.
    static func evaluate(state: State?, percent: Double, resetsAt: Double, now: Double)
        -> (state: State?, fire: Int?) {
        guard percent.isFinite, resetsAt > now, resetsAt <= now + horizon else { return (state, nil) }
        let pct = Int(min(max(percent, 0), 100))

        var current = state ?? State(resetsAt: resetsAt, firedThresholds: [], windowSeenAt: now)
        let storedIsJunk = current.resetsAt > now + horizon
        let isNewWindow = resetsAt > current.resetsAt + newWindowGap
        let spacedOut = now - (current.windowSeenAt ?? 0) >= minimumWindowSpacing
        if storedIsJunk || (isNewWindow && spacedOut) {
            current = State(resetsAt: resetsAt, firedThresholds: [], windowSeenAt: now)
        }

        // One notification for the highest threshold crossed in this update,
        // with every crossed threshold marked as fired, so a first launch at
        // 95% gets one alert and not three.
        let crossed = thresholds.filter { pct >= $0 && !current.firedThresholds.contains($0) }
        current.firedThresholds.formUnion(crossed)
        return (current, crossed.max())
    }
}
