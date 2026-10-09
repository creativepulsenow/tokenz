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
    /// Limits beyond the two fixed rows, if Claude Code reports any.
    @Published private(set) var extraLimits: [ExtraLimit] = []
    @Published var lastUpdated: Date? = nil
    @Published var isStale: Bool = true       // true after staleAfter seconds: show ~94%
    /// Bumped every 30s by `clockTickTimer` to force the menu bar countdown
    /// to re-render. The countdown depends on `Date()`, which isn't a
    /// publisher — ticking this property forces SwiftUI to re-evaluate.
    @Published private var clockTick: Int = 0

    /// Past this point the menu-bar percent is no longer trustworthy as a
    /// precise number, so we display it with a `~` prefix. We keep showing it
    /// for as long as its window lasts: usage only moves when Claude is used,
    /// so the last-known value stays right while this machine is idle. (Usage
    /// from the web, mobile or another machine is the exception, hence the `~`.)
    private static let staleAfter: TimeInterval = 90

    /// How often the countdown in the menu bar is refreshed.
    private static let clockTickInterval: TimeInterval = 30

    /// How far ahead of our clock a writer's timestamp may be before we
    /// distrust it.
    private static let futureTolerance: TimeInterval = 60

    private var staleTimer: Timer?
    private var clockTickTimer: Timer?

    func update(from data: UsageFileData) {
        // Sanitize at the boundary: the source file can be written by any process
        // with user-level access. Refuse to trust the contents.
        fiveHourPercent = Self.sanitizePercent(data.fiveHour?.usedPercentage)
        fiveHourResetsAt = Self.sanitizeTimestamp(data.fiveHour?.resetsAt)
        sevenDayPercent = Self.sanitizePercent(data.sevenDay?.usedPercentage)
        sevenDayResetsAt = Self.sanitizeTimestamp(data.sevenDay?.resetsAt)
        modelName = Self.sanitizeModel(data.model)
        var seen = Set<String>()
        extraLimits = (data.extra ?? []).prefix(Self.maxExtraLimits).compactMap { entry in
            guard let name = LimitName.clean(entry.name), seen.insert(name).inserted,
                  let percent = Self.sanitizePercent(entry.usedPercentage) else { return nil }
            return ExtraLimit(name: name, percent: percent, resetsAt: Self.sanitizeTimestamp(entry.resetsAt))
        }
        // Prefer the writer's timestamp over our read time. The two are usually
        // close, but if the writer's timestamp is in the future or absurdly
        // stale, fall back to now so the relative-date string stays sane.
        let now = Date()
        var updated = Self.sanitizeTimestamp(data.updatedAt) ?? now
        // A timestamp from the future (a spoofed file, or the clock moved back)
        // would keep the number looking fresh forever.
        if updated.timeIntervalSince(now) > Self.futureTolerance { updated = now }
        lastUpdated = updated
        // Age from the writer's timestamp, not from when we read the file, so a
        // relaunch hours later doesn't present an old number as fresh.
        let age = max(0, now.timeIntervalSince(updated))
        isStale = age >= Self.staleAfter
        resetStaleTimers(staleIn: Self.staleAfter - age)
    }

    // MARK: - Extra limits

    struct ExtraLimit: Identifiable, Equatable {
        let name: String
        let percent: Double
        let resetsAt: Date?
        var id: String { name }
    }

    private static let maxExtraLimits = 8

    /// Extra limits whose window is still running. Unlike the two fixed rows
    /// there is no "0% after reset" for these: we don't know they still apply.
    /// One without a plausible reset time is never shown, since nothing would
    /// ever take it down again.
    var visibleExtraLimits: [ExtraLimit] {
        let now = Date()
        let horizon = now.addingTimeInterval(UsageMerge.sevenDayHorizon)
        return extraLimits.filter { limit in
            guard let reset = limit.resetsAt else { return false }
            return reset > now && reset <= horizon
        }
    }

    /// True once the file has been read at least once.
    var hasReceivedData: Bool { lastUpdated != nil }

    /// True if the file has been read and it contains usable rate-limit data.
    /// Data received without any limits is what triggers the "Pro or Max
    /// plan" hint in the popover.
    var hasRateLimitData: Bool { fiveHourPercent != nil || sevenDayPercent != nil }

    // MARK: - Sanitizers

    private static func sanitizePercent(_ v: Double?) -> Double? {
        guard let v = v, v.isFinite else { return nil }
        return min(max(v, 0), 100)
    }

    /// Reject timestamps further than one year from now in either direction.
    /// Anything outside that range is almost certainly garbage from a misbehaving
    /// writer and would render as nonsensical relative-date strings.
    private static func sanitizeTimestamp(_ v: Double?) -> Date? {
        guard let v = v, v.isFinite else { return nil }
        let now = Date().timeIntervalSince1970
        let oneYear: TimeInterval = 86_400 * 365
        guard abs(v - now) <= oneYear else { return nil }
        return Date(timeIntervalSince1970: v)
    }

    /// Cap length and strip control / bidi-override characters so a malicious
    /// writer can't corrupt the popover layout or visually spoof the model name.
    private static func sanitizeModel(_ s: String?) -> String? {
        guard let s = s else { return nil }
        // Bidi overrides and line / paragraph separators.
        let blocked: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                    0x2066, 0x2067, 0x2068, 0x2069, 0x2028, 0x2029]
        // Cap scalars, not characters: one "character" can carry thousands of
        // stacked combining marks.
        let scrubbed = s.unicodeScalars.prefix(64).filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) &&
            !blocked.contains(scalar.value)
        }
        let result = String(String.UnicodeScalarView(scrubbed))
        return result.isEmpty ? nil : result
    }

    private func resetStaleTimers(staleIn: TimeInterval) {
        staleTimer?.invalidate()
        staleTimer = nil
        if staleIn > 0 {
            // Timers scheduled here fire on the main run loop.
            staleTimer = Timer.scheduledTimer(withTimeInterval: staleIn, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.isStale = true }
            }
        }
        // Start the clock-tick timer once. It runs forever so the countdown
        // keeps refreshing even when no new usage data arrives.
        if clockTickTimer == nil {
            clockTickTimer = Timer.scheduledTimer(withTimeInterval: Self.clockTickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.clockTick &+= 1 }
            }
        }
    }

    /// True when we know the cached 5-hour window has rolled over since our last
    /// update. Nothing has been used in the new window as far as this machine
    /// knows, so the cached percent no longer applies and we show 0 instead.
    private var fiveHourWindowHasReset: Bool {
        guard let reset = fiveHourResetsAt else { return false }
        return reset < Date()
    }

    private var sevenDayWindowHasReset: Bool {
        guard let reset = sevenDayResetsAt else { return false }
        return reset < Date()
    }

    /// The 5-hour percent to display: the last-known value, or 0 once its
    /// window has rolled over. Alerts keep using the raw `fiveHourPercent`.
    var fiveHourDisplayPercent: Double? {
        guard let pct = fiveHourPercent else { return nil }
        return fiveHourWindowHasReset ? 0 : pct
    }

    /// Reset time to display. Nil once it has passed: the next window doesn't
    /// start until Claude is used again, so there is nothing to count down to.
    var fiveHourDisplayResetsAt: Date? {
        fiveHourWindowHasReset ? nil : fiveHourResetsAt
    }

    var sevenDayDisplayPercent: Double? {
        guard let pct = sevenDayPercent else { return nil }
        return sevenDayWindowHasReset ? 0 : pct
    }

    var sevenDayDisplayResetsAt: Date? {
        sevenDayWindowHasReset ? nil : sevenDayResetsAt
    }

    /// Compact text for the menu bar label.
    /// - Fresh data: `94%`
    /// - Stale (90s+), window still running: `~94%`
    /// - Stale and the window has rolled over: `~0%`
    /// - No rate-limit data at all: `—%`
    var menuBarText: String {
        guard let pct = fiveHourDisplayPercent else { return "—%" }
        return (isStale ? "~" : "") + UsageFormat.percent(pct)
    }

    /// Single-string composition of percent + countdown for the menu bar label.
    /// We render this as one `Text` because MenuBarExtra's label is unreliable
    /// about rendering multiple sibling `Text` views — only the first reliably
    /// makes it to the bar. Combining into one string fixes that.
    ///
    /// Wrapped in square brackets so the percent + countdown read as one
    /// grouped unit next to the asterisk in a crowded menu bar. Brackets render cleanly
    /// because they're plain text — unlike Capsule overlays, which the menu
    /// bar's NSStatusItem layer silently drops.
    var menuBarFullText: String {
        let inner: String
        if let countdown = menuBarCountdown {
            inner = "\(menuBarText) · \(countdown)"
        } else {
            inner = menuBarText
        }
        return "[\(inner)]"
    }

    /// Optional countdown to the 5-hour window reset, shown next to the percent
    /// in the menu bar. The reset timestamp is a wall-clock time set when the
    /// window started, so it stays valid even when usage data is stale. Gone
    /// once the window has rolled over. Format: `1h 23m`, `23m`, `<1m`.
    var menuBarCountdown: String? {
        guard let reset = fiveHourDisplayResetsAt else { return nil }
        // Don't show a countdown next to —%.
        if fiveHourPercent == nil { return nil }

        let secs = reset.timeIntervalSinceNow
        if secs <= 0 { return nil }
        let mins = Int(secs / 60)
        if mins < 1 { return "<1m" }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        let m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// Color indicator for the current usage level. We keep the meaningful color
    /// while stale (the last-known value is still directionally right) and drop
    /// to gray only when we have no rate-limit data at all.
    var usageLevel: UsageLevel {
        fiveHourDisplayPercent.map(UsageLevel.init(percent:)) ?? .unknown
    }

    enum UsageLevel {
        case normal, warning, critical, unknown

        /// Green below 60%, orange from 60%, red from 85%.
        init(percent: Double) {
            if percent >= 85 { self = .critical }
            else if percent >= 60 { self = .warning }
            else { self = .normal }
        }
    }
}
