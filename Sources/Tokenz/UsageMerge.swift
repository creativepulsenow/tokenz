import Foundation

/// The rules for folding one status line run into the stored usage numbers.
/// Pure: no clock, no files. `StatusLineCommand` supplies both.
enum UsageMerge {
    /// One rate-limit window.
    struct Window: Equatable {
        var percent: Double
        var resetsAt: Double?
    }

    /// A limit beyond the two every plan has, such as a per-model weekly
    /// limit, under the name Claude Code gives it.
    struct NamedWindow: Equatable {
        var name: String
        var window: Window
    }

    struct Reading: Equatable {
        var fiveHour: Window?
        var sevenDay: Window?
        var model: String?
        /// Whatever other limits Claude Code reported.
        var extra: [NamedWindow] = []
    }

    /// Whether a run carries usage numbers newer than its session's last run.
    ///
    /// Every Claude Code session keeps the numbers from its own last API reply
    /// and re-runs the status line for reasons that have nothing to do with
    /// usage (cache expiry, a window resetting, a mode change). An idle session
    /// would otherwise overwrite the current number with an hours-old one.
    enum Freshness {
        /// The session has had an API reply since its last run.
        case fresh
        /// Nothing new since this session's last run.
        case stale
        /// First time we see this session, or it gave us nothing to go on.
        case unknown
    }

    /// No real window lasts longer than this past "now". A reset time further
    /// out is junk, and must not be allowed to pin the display.
    static let fiveHourHorizon: TimeInterval = 24 * 3600
    static let sevenDayHorizon: TimeInterval = 8 * 24 * 3600

    /// Most extra limits kept at once.
    static let maxExtraWindows = 8

    /// Two reset times this close describe the same window.
    static let sameWindowTolerance: TimeInterval = 60

    /// What is current after the run, and whether that needs writing.
    struct Outcome: Equatable {
        var current: Reading
        var shouldWrite: Bool
    }

    /// - Parameters:
    ///   - stored: what usage.json holds, or nil if there is no file yet.
    ///   - incoming: what this run reported.
    static func merge(stored: Reading?, incoming: Reading, freshness: Freshness, now: Double) -> Outcome {
        // Only windows that are still running count, on both sides.
        func live(_ window: Window?, horizon: TimeInterval, requireReset: Bool) -> Window? {
            guard let window = window else { return nil }
            guard let reset = window.resetsAt else { return requireReset ? nil : window }
            return reset > now && reset <= now + horizon ? window : nil
        }
        let storedFive = live(stored?.fiveHour, horizon: fiveHourHorizon, requireReset: true)
        let storedSeven = live(stored?.sevenDay, horizon: sevenDayHorizon, requireReset: true)
        let newFive = live(incoming.fiveHour, horizon: fiveHourHorizon, requireReset: false)
        let newSeven = live(incoming.sevenDay, horizon: sevenDayHorizon, requireReset: false)
        // Extra limits must carry a reset time: without one there would be
        // no telling when to stop showing them. One entry per name.
        func liveExtra(_ windows: [NamedWindow]) -> [NamedWindow] {
            var names = Set<String>()
            return windows.filter {
                live($0.window, horizon: sevenDayHorizon, requireReset: true) != nil && names.insert($0.name).inserted
            }
        }
        let storedExtra = liveExtra(stored?.extra ?? [])
        var newExtra = liveExtra(incoming.extra)
        let kept = Outcome(
            current: Reading(fiveHour: storedFive, sevenDay: storedSeven, model: stored?.model, extra: storedExtra),
            shouldWrite: false)

        if stored != nil {
            switch freshness {
            case .stale:
                return kept
            case .unknown:
                // Can't tell how old this reading is, so at least never let it
                // take usage backward inside a window.
                if isOlder(newFive, than: storedFive) || isOlder(newSeven, than: storedSeven) { return kept }
                // Same rule for each extra limit, one by one.
                newExtra.removeAll { candidate in
                    isOlder(candidate.window, than: storedExtra.first { $0.name == candidate.name }?.window)
                }
            case .fresh:
                break
            }
            // A run without limits (a session on an API key, or one that
            // hasn't had its first reply) is no reason to rewrite the file.
            if newFive == nil, newSeven == nil, newExtra.isEmpty { return kept }
        }

        // This run's extra limits replace stored ones of the same name;
        // stored ones it doesn't mention stay until they reset.
        let mentioned = Set(newExtra.map { $0.name })
        let extra = Array((newExtra + storedExtra.filter { !mentioned.contains($0.name) }).prefix(maxExtraWindows))

        // With nothing stored yet we write even without limits, so the app can
        // tell "no data yet" from "connected, but no limits reported".
        return Outcome(
            current: Reading(fiveHour: newFive ?? storedFive,
                             sevenDay: newSeven ?? storedSeven,
                             model: incoming.model ?? stored?.model,
                             extra: extra),
            shouldWrite: true)
    }

    /// True if `incoming` describes an earlier state than `stored`: the same
    /// window with less used, or a window that ended before the stored one.
    static func isOlder(_ incoming: Window?, than stored: Window?) -> Bool {
        guard let incoming = incoming, let stored = stored,
              let incomingReset = incoming.resetsAt, let storedReset = stored.resetsAt else { return false }
        if abs(incomingReset - storedReset) < sameWindowTolerance { return incoming.percent < stored.percent }
        return incomingReset < storedReset
    }
}
